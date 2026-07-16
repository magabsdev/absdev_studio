import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct KnowledgeBaseView: View {
    @Environment(AppStore.self) private var store
    @StateObject private var knowledge = KnowledgeBaseController()
    @State private var documents: [KnowledgeDocument] = []
    @State private var selectedID: NSManagedObjectID?
    @State private var search = ""
    @State private var errorMessage: String?
    @State private var documentToDelete: KnowledgeDocument?
    @State private var copiedDocument: KnowledgeDocument?

    private var selected: KnowledgeDocument? { documents.first { $0.objectID == selectedID } }

    var body: some View {
        HSplitView {
            navigator.frame(minWidth: 250, idealWidth: 300, maxWidth: 380)
            editor.frame(minWidth: 560)
        }
        .navigationTitle("Knowledge Base")
        .task(id: store.selectedProjectID) { reload() }
        .onChange(of: search) { _, _ in reload() }
        .alert("Knowledge Base Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "Unknown error") }
        .confirmationDialog("Delete this document and all its attachments?", isPresented: Binding(get: { documentToDelete != nil }, set: { if !$0 { documentToDelete = nil } }), titleVisibility: .visible) {
            Button("Delete Document", role: .destructive) { if let item = documentToDelete { perform { try knowledge.delete(item); reload() } }; documentToDelete = nil }
        }
    }

    private var navigator: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search documents", text: $search).textFieldStyle(.roundedBorder)
                Button { createDocument() } label: { Image(systemName: "plus") }.help("New Document")
            }.padding(12)
            Divider()
            if documents.isEmpty {
                ContentUnavailableView("No Documents", systemImage: "books.vertical", description: Text("Create project notes, guides and reference documents."))
            } else {
                List(selection: $selectedID) {
                    ForEach(documents, id: \.objectID) { document in
                        DocumentRow(document: document)
                            .tag(document.objectID)
                            .contextMenu {
                                Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(document) }
                                Button("Copy", systemImage: "doc.on.doc") { copiedDocument = document }
                                Button("Paste Copy", systemImage: "doc.on.clipboard") { pasteCopiedDocument() }.disabled(copiedDocument == nil)
                                Divider()
                                Button("Delete", systemImage: "trash", role: .destructive) { documentToDelete = document }
                            }
                    }
                    .onMove { indices, offset in move(indices, offset) }
                }.listStyle(.sidebar)
            }
            Divider()
            HStack {
                Button("Import…", systemImage: "square.and.arrow.down") { importPackage() }
                Spacer()
                Button("Export…", systemImage: "square.and.arrow.up") { exportPackage() }.disabled(documents.isEmpty)
            }.padding(10)
        }
        .background(.background)
    }

    @ViewBuilder private var editor: some View {
        if let document = selected { DocumentEditor(document: document, knowledge: knowledge, onChanged: reload, onDelete: { documentToDelete = document }, error: { errorMessage = $0.localizedDescription }) }
        else { ContentUnavailableView("Select a Document", systemImage: "doc.text", description: Text("Choose a document or create a new one.")) }
    }

    private func reload() {
        guard let id = store.selectedProjectID else { documents = []; selectedID = nil; return }
        perform { documents = try knowledge.documents(projectID: id, search: search); if selectedID == nil || !documents.contains(where: { $0.objectID == selectedID }) { selectedID = documents.first?.objectID } }
    }
    private func createDocument() { guard let id = store.selectedProjectID else { return }; perform { let item = try knowledge.createDocument(projectID: id); reload(); selectedID = item.objectID } }
    private func duplicate(_ document: KnowledgeDocument) { perform { let item = try knowledge.duplicate(document); reload(); selectedID = item.objectID } }
    private func pasteCopiedDocument() { guard let copiedDocument else { return }; duplicate(copiedDocument) }
    private func move(_ indices: IndexSet, _ offset: Int) { var copy = documents; copy.move(fromOffsets: indices, toOffset: offset); perform { for (index, item) in copy.enumerated() { item.sortOrder = Int32(index) }; try knowledge.save(); reload() } }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { errorMessage = error.localizedDescription } }

    private func exportPackage() {
        guard let project = store.selectedProject else { return }
        let panel = NSOpenPanel(); panel.title = "Export Knowledge Base"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { let exported = try knowledge.exportProject(projectID: project.id, projectName: project.name, to: url); NSWorkspace.shared.activateFileViewerSelecting([exported]) }
    }
    private func importPackage() {
        guard let id = store.selectedProjectID else { return }
        let panel = NSOpenPanel(); panel.title = "Import Knowledge Base"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.allowedContentTypes = [UTType(filenameExtension: "absdevknowledge") ?? .folder]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try knowledge.importProject(from: url, into: id, strategy: .merge); reload() }
    }
}

private struct DocumentRow: View {
    @ObservedObject var document: KnowledgeDocument
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Image(systemName: document.priority.symbol).foregroundStyle(document.priority == .critical ? .red : .secondary); Text(document.title.isEmpty ? "Untitled Document" : document.title).fontWeight(.semibold).lineLimit(1); Spacer() }
            HStack { Text(document.updatedAt, style: .relative); Spacer(); if !document.attachments.isEmpty { Label("\(document.attachments.count)", systemImage: "paperclip") } }.font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 5)
    }
}

private struct DocumentEditor: View {
    @ObservedObject var document: KnowledgeDocument
    let knowledge: KnowledgeBaseController
    let onChanged: () -> Void
    let onDelete: () -> Void
    let error: (Error) -> Void
    @State private var saveTask: Task<Void, Never>?
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Document title", text: Binding(get: { document.title }, set: { document.title = $0; scheduleSave() })).font(.title2.bold()).textFieldStyle(.plain)
                Picker("Priority", selection: Binding(get: { document.priority }, set: { document.priority = $0; saveNow() })) { ForEach(KnowledgePriority.allCases) { priority in Label(priority.title, systemImage: priority.symbol).tag(priority) } }.frame(width: 155)
                Menu { Button("Duplicate", systemImage: "plus.square.on.square") { do { _ = try knowledge.duplicate(document); onChanged() } catch { self.error(error) } }; Divider(); Button("Delete", systemImage: "trash", role: .destructive, action: onDelete) } label: { Image(systemName: "ellipsis.circle") }
            }.padding(16)
            Divider()
            TextEditor(text: Binding(get: { document.content }, set: { document.content = $0; scheduleSave() })).font(.body).scrollContentBackground(.hidden).padding(16).background(Color(nsColor: .textBackgroundColor))
            Divider()
            attachments
            Divider()
            HStack { Text("Created \(document.createdAt.formatted(date: .abbreviated, time: .shortened))"); Spacer(); Text("Updated \(document.updatedAt.formatted(date: .abbreviated, time: .shortened))") }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Label("Attachments", systemImage: "paperclip").font(.headline); Spacer(); Button("Add Files…", systemImage: "plus") { chooseAttachments() } }
            if document.attachments.isEmpty { Text("Drop files here or use Add Files.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 52) }
            else { ScrollView(.horizontal) { HStack { ForEach(document.attachments.sorted(by: { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }), id: \.objectID) { item in AttachmentChip(item: item, knowledge: knowledge, changed: onChanged, error: error) } } } }
        }.padding(14).background(isDropTarget ? Color.accentColor.opacity(0.12) : Color.clear).dropDestination(for: URL.self) { urls, _ in add(urls); return true } isTargeted: { isDropTarget = $0 }
    }

    private func chooseAttachments() { let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true; guard panel.runModal() == .OK else { return }; add(panel.urls) }
    private func add(_ urls: [URL]) { do { for url in urls { _ = try knowledge.addAttachment(url, to: document) }; onChanged() } catch { self.error(error) } }
    private func scheduleSave() { saveTask?.cancel(); saveTask = Task { try? await Task.sleep(for: .milliseconds(500)); guard !Task.isCancelled else { return }; await MainActor.run { saveNow() } } }
    private func saveNow() { do { try knowledge.touch(document); onChanged() } catch { self.error(error) } }
}

private struct AttachmentChip: View {
    @ObservedObject var item: KnowledgeAttachment
    let knowledge: KnowledgeBaseController
    let changed: () -> Void
    let error: (Error) -> Void
    var body: some View {
        HStack(spacing: 8) { Image(systemName: "doc.fill"); VStack(alignment: .leading) { Text(item.filename).lineLimit(1); Text(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }; Button { NSWorkspace.shared.open(knowledge.attachmentURL(item)) } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(.plain); Button { do { try knowledge.removeAttachment(item); changed() } catch { self.error(error) } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
            .padding(9).background(.quaternary, in: RoundedRectangle(cornerRadius: 9)).frame(maxWidth: 260)
    }
}
