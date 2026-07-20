import AppKit
import SwiftUI

struct HelpDocument: Identifiable, Hashable {
    let id: String
    let title: String
    let category: String
    let markdown: String
    let sourceURL: URL?
}

@MainActor
@Observable
final class HelpLibrary {
    static let shared = HelpLibrary()

    private(set) var documents: [HelpDocument] = []
    var query = ""
    var selectedID: String?

    private init() { reload() }

    var filteredDocuments: [HelpDocument] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return documents }
        return documents.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.category.localizedCaseInsensitiveContains(query) ||
            $0.markdown.localizedCaseInsensitiveContains(query)
        }
    }

    var selectedDocument: HelpDocument? {
        documents.first { $0.id == selectedID } ?? documents.first
    }

    func reload() {
        let roots = documentationRoots()
        var loaded: [HelpDocument] = []
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            while loaded.count < 500, let url = enumerator.nextObject() as? URL {
                guard url.pathExtension.lowercased() == "md", let markdown = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
                let category = relative.split(separator: "/").dropLast().first.map(String.init) ?? "General"
                let title = markdown.split(separator: "\n").first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)) }
                    ?? url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ")
                loaded.append(.init(id: relative, title: title, category: category, markdown: markdown, sourceURL: url))
            }
            if !loaded.isEmpty { break }
        }
        documents = loaded.sorted { ($0.category, $0.title) < ($1.category, $1.title) }
        if selectedID == nil { selectedID = documents.first?.id }
    }

    func open(_ id: String) {
        selectedID = id
        StudioEventBus.shared.publish(.documentationOpened(id))
        StudioLogCentre.shared.write("Opened help document: \(id)", channel: .documentation)
    }

    private func documentationRoots() -> [URL] {
        var roots: [URL] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Documentation", isDirectory: true) { roots.append(bundled) }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        roots.append(cwd.appendingPathComponent("Documentation", isDirectory: true))
        roots.append(cwd.deletingLastPathComponent().appendingPathComponent("Documentation", isDirectory: true))
        return roots
    }
}

struct HelpCentreView: View {
    @State private var library = HelpLibrary.shared

    var body: some View {
        @Bindable var library = library
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search documentation", text: $library.query).textFieldStyle(.plain)
                }
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                .padding(10)

                List(selection: $library.selectedID) {
                    ForEach(Dictionary(grouping: library.filteredDocuments, by: \.category).keys.sorted(), id: \.self) { category in
                        Section(category) {
                            ForEach(library.filteredDocuments.filter { $0.category == category }) { document in
                                Label(document.title, systemImage: "doc.text")
                                    .tag(document.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 250, idealWidth: 290)

            if let document = library.selectedDocument {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(document.title).font(.largeTitle.bold())
                                Text(document.category).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let sourceURL = document.sourceURL {
                                Button("Reveal", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([sourceURL]) }
                            }
                        }
                        Divider()
                        MarkdownHelpText(markdown: document.markdown)
                            .textSelection(.enabled)
                    }
                    .padding(28)
                    .frame(maxWidth: 960, alignment: .leading)
                }
            } else {
                ContentUnavailableView("Documentation unavailable", systemImage: "questionmark.book.closed", description: Text("The Documentation folder could not be found."))
            }
        }
        .navigationTitle("Help Centre")
        .toolbar {
            Button("Reload", systemImage: "arrow.clockwise") { library.reload() }
        }
    }
}

private struct MarkdownHelpText: View {
    let markdown: String

    var body: some View {
        if let attributed = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full)) {
            Text(attributed)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(markdown).font(.body.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
