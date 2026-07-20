import AppKit
import Foundation
import Observation
import ObjectiveC
import SwiftUI
import UniformTypeIdentifiers


private enum EntityDiagramPDFWindowAssociation {
    static var key: UInt8 = 0
}

struct EntityDiagramColumn: Codable, Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let type: String
    let nullable: Bool
    let primary: Bool
}

struct EntityDiagramRelationship: Codable, Identifiable, Hashable, Sendable {
    var id: String { "\(sourceTable).\(sourceColumn)->\(targetTable).\(targetColumn)" }
    let sourceTable: String
    let sourceColumn: String
    let targetTable: String
    let targetColumn: String
}

struct EntityDiagramTable: Codable, Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    var columns: [EntityDiagramColumn]
}

struct DiagramPoint: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

struct SavedEntityDiagram: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var updatedAt = Date()
    var tables: [EntityDiagramTable]
    var relationships: [EntityDiagramRelationship]
    var positions: [String: DiagramPoint]
}

@MainActor @Observable
final class EntityDiagramModel {
    var tables: [EntityDiagramTable] = []
    var relationships: [EntityDiagramRelationship] = []
    var positions: [String: DiagramPoint] = [:]
    var savedDiagrams: [SavedEntityDiagram] = []
    var selectedDiagramID: UUID?
    var selectedTableName: String?
    var status = "Load the live database schema or open a saved diagram."
    var isLoading = false
    var generationTitle = "Generating Entity Diagram"
    var generationDetail = "Preparing database inspection…"
    var generationProgress = 0.0
    var scale: CGFloat = 1
    var search = ""

    private let fm = FileManager.default

    var filteredTables: [EntityDiagramTable] {
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return tables }
        return tables.filter { table in
            table.name.localizedCaseInsensitiveContains(search) ||
            table.columns.contains { $0.name.localizedCaseInsensitiveContains(search) }
        }
    }

    func load(project: LaravelProject?) {
        guard let project else { return }
        savedDiagrams = loadJSON([SavedEntityDiagram].self, from: storageURL(project.id)) ?? []
        if tables.isEmpty, let latest = savedDiagrams.sorted(by: { $0.updatedAt > $1.updatedAt }).first {
            open(latest)
            status = "Opened saved diagram \(latest.name)."
        }
    }

    func refresh(project: LaravelProject) async {
        isLoading = true
        generationTitle = "Generating Entity Diagram"
        generationDetail = "Resolving the PHP runtime for \(project.name)…"
        generationProgress = 0.08
        status = "Inspecting the live database schema…"

        await Task.yield()
        generationDetail = "Reading tables, columns, keys, and foreign-key constraints…"
        generationProgress = 0.24
        let php = project.phpExecutablePath
        let result = await Task.detached { Self.inspect(project: project, preferredPHP: php) }.value

        switch result {
        case .success(let schema):
            generationDetail = "Building entities and ERD relationships…"
            generationProgress = 0.78
            tables = schema.tables.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            relationships = schema.relationships
            await Task.yield()
            generationDetail = "Applying the automatic diagram layout…"
            generationProgress = 0.92
            applyAutomaticLayout(onlyMissing: true)
            generationProgress = 1
            status = "Loaded \(tables.count) tables and \(relationships.count) relationships."
        case .failure(let error):
            status = error.localizedDescription
        }

        try? await Task.sleep(for: .milliseconds(180))
        isLoading = false
    }

    func applyAutomaticLayout(onlyMissing: Bool = false) {
        let width = 280.0
        let horizontalGap = 70.0
        let verticalGap = 70.0
        let columns = max(1, Int(ceil(sqrt(Double(max(tables.count, 1))))))
        for (index, table) in tables.enumerated() {
            if onlyMissing, positions[table.name] != nil { continue }
            let column = index % columns
            let row = index / columns
            positions[table.name] = DiagramPoint(
                x: 50 + Double(column) * (width + horizontalGap),
                y: 50 + Double(row) * (260 + verticalGap)
            )
        }
    }

    func save(project: LaravelProject, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Database \(Date().formatted(date: .abbreviated, time: .shortened))" : trimmed
        if let selectedDiagramID, let index = savedDiagrams.firstIndex(where: { $0.id == selectedDiagramID }) {
            savedDiagrams[index].name = finalName
            savedDiagrams[index].updatedAt = Date()
            savedDiagrams[index].tables = tables
            savedDiagrams[index].relationships = relationships
            savedDiagrams[index].positions = positions
        } else {
            let diagram = SavedEntityDiagram(name: finalName, tables: tables, relationships: relationships, positions: positions)
            savedDiagrams.insert(diagram, at: 0)
            selectedDiagramID = diagram.id
        }
        persist(projectID: project.id)
        status = "Saved \(finalName)."
    }

    func open(_ diagram: SavedEntityDiagram) {
        selectedDiagramID = diagram.id
        tables = diagram.tables
        relationships = diagram.relationships
        positions = diagram.positions
        selectedTableName = nil
    }

    func delete(project: LaravelProject, id: UUID) {
        savedDiagrams.removeAll { $0.id == id }
        if selectedDiagramID == id { selectedDiagramID = nil }
        persist(projectID: project.id)
    }

    func exportPDF(project: LaravelProject) {
        guard !tables.isEmpty else { status = "There is no diagram to export."; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(project.name)-database-diagram.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let size = canvasSize
        let documentSize = CGSize(width: size.width + 96, height: size.height + 230)
        let printView = EntityDiagramPrintView(
            projectName: project.name,
            diagramName: selectedDiagramName,
            tables: tables,
            relationships: relationships,
            positions: positions,
            canvasSize: size
        )
        guard let data = renderPDF(rootView: printView, size: documentSize) else {
            status = "PDF export failed because the diagram could not be rendered."
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            status = "Exported styled ERD PDF to \(url.lastPathComponent)."
        } catch {
            status = "PDF export failed: \(error.localizedDescription)"
        }
    }

    func printDiagram(project: LaravelProject) {
        guard !tables.isEmpty else { status = "There is no diagram to print."; return }
        let size = canvasSize
        let documentSize = CGSize(width: size.width + 96, height: size.height + 230)
        let printView = EntityDiagramPrintView(
            projectName: project.name,
            diagramName: selectedDiagramName,
            tables: tables,
            relationships: relationships,
            positions: positions,
            canvasSize: size
        )
        let view = preparedHostingView(rootView: printView, size: documentSize)
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.orientation = documentSize.width > documentSize.height ? .landscape : .portrait
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        NSPrintOperation(view: view, printInfo: info).run()
        status = "Print dialog opened for \(project.name)."
    }

    private func preparedHostingView<Content: View>(rootView: Content, size: CGSize) -> NSHostingView<Content> {
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = CGRect(origin: .zero, size: size)
        hostingView.autoresizingMask = []
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.white.cgColor

        // SwiftUI hosting views may produce an empty PDF when they have never been
        // attached to a window. Mount the view in a hidden off-screen window and
        // force a complete layout/display pass before printing or exporting.
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -100_000, y: -100_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.backgroundColor = .white
        window.contentView = hostingView
        window.orderOut(nil)

        hostingView.needsLayout = true
        hostingView.layoutSubtreeIfNeeded()
        hostingView.needsDisplay = true
        hostingView.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        // Keep the temporary window alive for the lifetime of the hosting view.
        objc_setAssociatedObject(hostingView, &EntityDiagramPDFWindowAssociation.key, window, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return hostingView
    }

    private func renderPDF<Content: View>(rootView: Content, size: CGSize) -> Data? {
        guard size.width > 0, size.height > 0 else { return nil }

        // ImageRenderer is SwiftUI's supported off-screen renderer. Rendering
        // directly into a PDF CGContext avoids the blank NSHostingView PDFs
        // produced by AppKit when a large Canvas has never appeared on screen.
        let renderer = ImageRenderer(content: rootView)
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = 1

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        var rendered = false
        renderer.render { renderedSize, draw in
            guard renderedSize.width > 0, renderedSize.height > 0 else { return }
            pdfContext.beginPDFPage(nil)
            draw(pdfContext)
            pdfContext.endPDFPage()
            rendered = true
        }
        pdfContext.closePDF()

        guard rendered, data.length > 512 else { return nil }
        return data as Data
    }

    var selectedDiagramName: String {
        guard let selectedDiagramID,
              let diagram = savedDiagrams.first(where: { $0.id == selectedDiagramID }) else {
            return "Live Database Schema"
        }
        return diagram.name
    }

    var canvasSize: CGSize {
        let maxX = positions.values.map(\.x).max() ?? 800
        let maxY = positions.values.map(\.y).max() ?? 600
        return CGSize(width: max(1000, maxX + 360), height: max(700, maxY + 500))
    }

    private func persist(projectID: UUID) {
        let url = storageURL(projectID)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(savedDiagrams) { try? data.write(to: url, options: .atomic) }
    }

    private func storageURL(_ projectID: UUID) -> URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ABSDEVStudio/EntityDiagrams", isDirectory: true)
            .appendingPathComponent("\(projectID.uuidString).json")
    }

    private func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    nonisolated private static func inspect(project: LaravelProject, preferredPHP: String?) -> Result<(tables: [EntityDiagramTable], relationships: [EntityDiagramRelationship]), EntityDiagramError> {
        guard FileManager.default.fileExists(atPath: URL(fileURLWithPath: project.path).appendingPathComponent("artisan").path) else {
            return .failure(.notLaravel)
        }
        guard let php = resolvePHP(preferred: preferredPHP, cwd: project.path) else { return .failure(.phpUnavailable) }
        let tableResult = shell("\(quote(php)) artisan db:show --json --no-interaction", cwd: project.path)
        guard tableResult.status == 0 else { return .failure(.commandFailed(String(tableResult.output.prefix(1000)))) }
        let names = parseTableNames(tableResult.output)
        guard !names.isEmpty else { return .failure(.emptySchema) }
        var tables: [EntityDiagramTable] = []
        var relationships: [EntityDiagramRelationship] = []
        for name in names {
            let detail = shell("\(quote(php)) artisan db:table \(quote(name)) --json --no-interaction", cwd: project.path)
            guard detail.status == 0 else { continue }
            let parsed = parseTable(name: name, output: detail.output)
            tables.append(parsed.table)
            if parsed.relationships.isEmpty {
                relationships.append(contentsOf: inspectForeignKeys(table: name, php: php, cwd: project.path))
            } else {
                relationships.append(contentsOf: parsed.relationships)
            }
        }
        return .success((tables, Array(Set(relationships))))
    }


    /// Laravel's `db:table --json` format differs between framework/database versions.
    /// This fallback asks Laravel's schema builder directly, ensuring ERD relationships
    /// are available even when the CLI table payload omits or renames foreign-key fields.
    nonisolated private static func inspectForeignKeys(table: String, php: String, cwd: String) -> [EntityDiagramRelationship] {
        let script = """
        <?php
        require __DIR__ . '/vendor/autoload.php';
        $app = require __DIR__ . '/bootstrap/app.php';
        $app->make(Illuminate\\Contracts\\Console\\Kernel::class)->bootstrap();
        $table = <?= ABSDEV_TABLE ?>;
        try {
            $keys = Illuminate\\Support\\Facades\\Schema::getForeignKeys($table);
            echo json_encode($keys, JSON_UNESCAPED_SLASHES);
        } catch (Throwable $error) {
            fwrite(STDERR, $error->getMessage());
            exit(1);
        }
        """
        // Swift interpolation is used instead of PHP templating in the generated file.
        let resolvedScript = script.replacingOccurrences(
            of: "<?= ABSDEV_TABLE ?>",
            with: "'" + table.replacingOccurrences(of: "'", with: "\\'") + "'"
        )
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("absdev-foreign-keys-\(UUID().uuidString).php")
        do {
            try resolvedScript.write(to: temporaryURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            let result = shell("\(quote(php)) \(quote(temporaryURL.path))", cwd: cwd)
            guard result.status == 0,
                  let data = result.output.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
            let rows: [[String: Any]]
            if let values = object as? [[String: Any]] { rows = values }
            else if let dictionary = object as? [String: [String: Any]] { rows = Array(dictionary.values) }
            else { rows = [] }
            return rows.flatMap { row -> [EntityDiagramRelationship] in
                let sourceColumns = stringValues(row["columns"] ?? row["column"])
                let targetTable = stringValue(row["foreign_table"] ?? row["foreignTable"] ?? row["referenced_table"])
                let targetColumns = stringValues(row["foreign_columns"] ?? row["foreign_column"] ?? row["referenced_columns"])
                guard let targetTable else { return [] }
                return sourceColumns.enumerated().map { index, sourceColumn in
                    EntityDiagramRelationship(
                        sourceTable: table,
                        sourceColumn: sourceColumn,
                        targetTable: targetTable,
                        targetColumn: targetColumns.indices.contains(index) ? targetColumns[index] : (targetColumns.first ?? "id")
                    )
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            return []
        }
    }

    nonisolated private static func resolvePHP(preferred: String?, cwd: String) -> String? {
        guard let candidate = preferred?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty,
              FileManager.default.isExecutableFile(atPath: candidate) else { return nil }
        return shell("\(quote(candidate)) -r 'echo PHP_VERSION;'", cwd: cwd).status == 0 ? candidate : nil
    }

    nonisolated private static func parseTableNames(_ output: String) -> [String] {
        guard let data = output.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let rows: [[String: Any]]
        if let dictionary = object as? [String: Any] {
            rows = (dictionary["tables"] as? [[String: Any]]) ?? (dictionary["data"] as? [[String: Any]]) ?? []
        } else { rows = object as? [[String: Any]] ?? [] }
        return rows.compactMap { value in
            ["name", "table", "table_name"].compactMap { value[$0] as? String }.first
        }
    }

    nonisolated private static func parseTable(name: String, output: String) -> (table: EntityDiagramTable, relationships: [EntityDiagramRelationship]) {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return (EntityDiagramTable(name: name, columns: []), []) }
        let payload = (root["data"] as? [String: Any]) ?? root
        let columnRows = payload["columns"] as? [[String: Any]] ?? []
        let indexRows = payload["indexes"] as? [[String: Any]] ?? []
        let primaryNames = Set(indexRows.filter { bool($0["primary"]) || (($0["name"] as? String)?.lowercased() == "primary") }.flatMap { row -> [String] in
            (row["columns"] as? [String]) ?? [row["column"] as? String].compactMap { $0 }
        })
        let columns = columnRows.compactMap { row -> EntityDiagramColumn? in
            guard let columnName = (row["name"] ?? row["column"]) as? String else { return nil }
            let type = String(describing: row["type"] ?? row["data_type"] ?? "unknown")
            return EntityDiagramColumn(name: columnName, type: type, nullable: bool(row["nullable"] ?? row["null"]), primary: primaryNames.contains(columnName) || bool(row["primary"]))
        }
        let foreignRows = foreignKeyRows(from: payload)
        let relationships = foreignRows.flatMap { row -> [EntityDiagramRelationship] in
            let sourceColumns = stringValues(row["columns"] ?? row["column"] ?? row["local_columns"] ?? row["local_column"])
            let targetTable = stringValue(row["foreign_table"] ?? row["foreignTable"] ?? row["referenced_table"] ?? row["referencedTable"] ?? row["table"])
            let targetColumns = stringValues(row["foreign_columns"] ?? row["foreign_column"] ?? row["foreignColumn"] ?? row["referenced_columns"] ?? row["referenced_column"])
            guard let targetTable, !sourceColumns.isEmpty else { return [] }
            return sourceColumns.enumerated().map { index, sourceColumn in
                let targetColumn = targetColumns.indices.contains(index) ? targetColumns[index] : (targetColumns.first ?? "id")
                return EntityDiagramRelationship(sourceTable: name, sourceColumn: sourceColumn, targetTable: targetTable, targetColumn: targetColumn)
            }
        }
        return (EntityDiagramTable(name: name, columns: columns), relationships)
    }


    nonisolated private static func foreignKeyRows(from payload: [String: Any]) -> [[String: Any]] {
        for key in ["foreign_keys", "foreignKeys", "foreign keys", "foreign-keys"] {
            if let rows = payload[key] as? [[String: Any]] { return rows }
            if let dictionary = payload[key] as? [String: [String: Any]] { return Array(dictionary.values) }
            if let dictionary = payload[key] as? [String: Any] {
                let rows = dictionary.values.compactMap { $0 as? [String: Any] }
                if !rows.isEmpty { return rows }
            }
        }
        return []
    }

    nonisolated private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let values = value as? [String] { return values.first }
        if let value { return String(describing: value) }
        return nil
    }

    nonisolated private static func stringValues(_ value: Any?) -> [String] {
        if let values = value as? [String] { return values.filter { !$0.isEmpty } }
        if let values = value as? [Any] { return values.compactMap { stringValue($0) } }
        if let value = stringValue(value) { return [value] }
        return []
    }

    nonisolated private static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? Int { return value != 0 }
        if let value = value as? String { return ["1", "true", "yes"].contains(value.lowercased()) }
        return false
    }

    nonisolated private static func quote(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'" }

    nonisolated private static func shell(_ command: String, cwd: String) -> (status: Int32, output: String) {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = pipe; process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch { return (-1, error.localizedDescription) }
    }
}

enum EntityDiagramError: LocalizedError, Sendable {
    case notLaravel, phpUnavailable, emptySchema, commandFailed(String)
    var errorDescription: String? {
        switch self {
        case .notLaravel: "Entity diagrams currently require a Laravel project with an Artisan executable."
        case .phpUnavailable: "No working PHP runtime could be resolved for this project. Configure its PHP runtime in Settings."
        case .emptySchema: "Laravel returned no database tables. Verify the project database connection."
        case .commandFailed(let output): "Database inspection failed. \(output)"
        }
    }
}

struct EntityDiagramWorkspaceView: View {
    let project: LaravelProject?
    @State private var model = EntityDiagramModel()
    @State private var saveName = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                sidebar.frame(minWidth: 220, idealWidth: 250, maxWidth: 310)
                diagram
            }
            Divider()
            Text(model.status).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 7)
        }
        .task(id: project?.id) { model.load(project: project) }
        .sheet(isPresented: $model.isLoading) {
            EntityDiagramProgressView(
                title: model.generationTitle,
                detail: model.generationDetail,
                progress: model.generationProgress
            )
            .interactiveDismissDisabled()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button("Load Live Schema", systemImage: "arrow.clockwise") { if let project { Task { await model.refresh(project: project) } } }
                .buttonStyle(.borderedProminent).disabled(project == nil || model.isLoading)
            Button("Auto Layout", systemImage: "rectangle.3.group") { model.applyAutomaticLayout() }.disabled(model.tables.isEmpty)
            Divider().frame(height: 22)
            TextField("Diagram name", text: $saveName).textFieldStyle(.roundedBorder).frame(width: 190)
            Button("Save", systemImage: "square.and.arrow.down") { if let project { model.save(project: project, name: saveName) } }.disabled(model.tables.isEmpty)
            Spacer()
            Slider(value: $model.scale, in: 0.45...1.5).frame(width: 130)
            Button("Export PDF", systemImage: "doc.richtext") { if let project { model.exportPDF(project: project) } }.disabled(model.tables.isEmpty)
            Button("Print", systemImage: "printer") { if let project { model.printDiagram(project: project) } }.disabled(model.tables.isEmpty)
            if model.isLoading { ProgressView().controlSize(.small) }
        }.padding(12)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Filter tables or columns", text: $model.search).textFieldStyle(.roundedBorder).padding([.top, .horizontal], 10)
            List(selection: $model.selectedTableName) {
                Section("Tables") {
                    ForEach(model.filteredTables) { table in
                        Label(table.name, systemImage: "tablecells").tag(table.name)
                    }
                }
                if !model.savedDiagrams.isEmpty {
                    Section("Saved Diagrams") {
                        ForEach(model.savedDiagrams) { saved in
                            HStack {
                                Button(saved.name) { model.open(saved); saveName = saved.name }.buttonStyle(.plain)
                                Spacer()
                                Button(role: .destructive) { if let project { model.delete(project: project, id: saved.id) } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
        }
    }

    private var diagram: some View {
        ScrollView([.horizontal, .vertical]) {
            EntityDiagramCanvasView(tables: model.filteredTables, relationships: model.relationships, positions: $model.positions, selectedTableName: $model.selectedTableName)
                .frame(width: model.canvasSize.width, height: model.canvasSize.height)
                .scaleEffect(model.scale, anchor: .topLeading)
                .frame(width: model.canvasSize.width * model.scale, height: model.canvasSize.height * model.scale, alignment: .topLeading)
                .background(Color(nsColor: .textBackgroundColor))
        }
        .overlay {
            if model.tables.isEmpty && !model.isLoading {
                ContentUnavailableView("No entity diagram", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Load the live Laravel database schema or open a saved diagram."))
            }
        }
    }
}

struct EntityDiagramCanvasView: View {
    let tables: [EntityDiagramTable]
    let relationships: [EntityDiagramRelationship]
    @Binding var positions: [String: DiagramPoint]
    @Binding var selectedTableName: String?
    var printMode = false

    private let cardWidth: CGFloat = 280
    private let headerHeight: CGFloat = 42
    private let rowHeight: CGFloat = 24

    var body: some View {
        ZStack(alignment: .topLeading) {
            DiagramGridBackground()
                .opacity(printMode ? 0.55 : 1)
            Canvas { context, _ in
                for relationship in relationships {
                    drawRelationship(relationship, in: &context)
                }
            }
            ForEach(tables) { table in
                EntityTableCard(table: table, selected: selectedTableName == table.name, printMode: printMode)
                    .frame(width: cardWidth)
                    .position(cardPosition(table))
                    .onTapGesture { if !printMode { selectedTableName = table.name } }
                    .gesture(DragGesture().onChanged { value in
                        guard !printMode else { return }
                        positions[table.name] = DiagramPoint(
                            x: max(0, value.location.x - cardWidth / 2),
                            y: max(0, value.location.y - cardHeight(table) / 2)
                        )
                    })
            }
        }
    }

    private enum DiagramEdge {
        case leading, trailing, top, bottom
    }

    private func drawRelationship(_ relationship: EntityDiagramRelationship, in context: inout GraphicsContext) {
        guard let sourceTable = tables.first(where: { $0.name == relationship.sourceTable }),
              let targetTable = tables.first(where: { $0.name == relationship.targetTable }),
              let sourceOrigin = positions[relationship.sourceTable]?.cgPoint,
              let targetOrigin = positions[relationship.targetTable]?.cgPoint else { return }

        let sourceCenter = CGPoint(
            x: sourceOrigin.x + cardWidth / 2,
            y: sourceOrigin.y + cardHeight(sourceTable) / 2
        )
        let targetCenter = CGPoint(
            x: targetOrigin.x + cardWidth / 2,
            y: targetOrigin.y + cardHeight(targetTable) / 2
        )
        let horizontal = abs(targetCenter.x - sourceCenter.x) >= abs(targetCenter.y - sourceCenter.y)

        let sourceEdge: DiagramEdge
        let targetEdge: DiagramEdge
        if horizontal {
            sourceEdge = targetCenter.x >= sourceCenter.x ? .trailing : .leading
            targetEdge = targetCenter.x >= sourceCenter.x ? .leading : .trailing
        } else {
            sourceEdge = targetCenter.y >= sourceCenter.y ? .bottom : .top
            targetEdge = targetCenter.y >= sourceCenter.y ? .top : .bottom
        }

        let sourceAnchor = relationshipAnchor(
            table: sourceTable,
            column: relationship.sourceColumn,
            origin: sourceOrigin,
            edge: sourceEdge
        )
        let targetAnchor = relationshipAnchor(
            table: targetTable,
            column: relationship.targetColumn,
            origin: targetOrigin,
            edge: targetEdge
        )

        var path = Path()
        path.move(to: sourceAnchor)
        if horizontal {
            let middleX = (sourceAnchor.x + targetAnchor.x) / 2
            path.addLine(to: CGPoint(x: middleX, y: sourceAnchor.y))
            path.addLine(to: CGPoint(x: middleX, y: targetAnchor.y))
        } else {
            let middleY = (sourceAnchor.y + targetAnchor.y) / 2
            path.addLine(to: CGPoint(x: sourceAnchor.x, y: middleY))
            path.addLine(to: CGPoint(x: targetAnchor.x, y: middleY))
        }
        path.addLine(to: targetAnchor)

        let relationshipColor = printMode ? Color.black.opacity(0.82) : Color.primary.opacity(0.76)
        context.stroke(
            path,
            with: .color(relationshipColor),
            style: StrokeStyle(lineWidth: printMode ? 1.1 : 1.25, lineCap: .butt, lineJoin: .miter, dash: [9, 6])
        )

        let nullable = sourceTable.columns.first(where: { $0.name == relationship.sourceColumn })?.nullable ?? false
        drawManyMarker(at: sourceAnchor, edge: sourceEdge, optional: nullable, color: relationshipColor, context: &context)
        drawOneMarker(at: targetAnchor, edge: targetEdge, color: relationshipColor, context: &context)
        drawCardinalityLabels(
            sourceAnchor: sourceAnchor,
            sourceEdge: sourceEdge,
            targetAnchor: targetAnchor,
            targetEdge: targetEdge,
            optional: nullable,
            context: &context
        )
    }

    private func relationshipAnchor(
        table: EntityDiagramTable,
        column: String,
        origin: CGPoint,
        edge: DiagramEdge
    ) -> CGPoint {
        switch edge {
        case .leading, .trailing:
            let visibleColumns = Array(table.columns.prefix(14))
            let index = visibleColumns.firstIndex(where: { $0.name == column }) ?? 0
            return CGPoint(
                x: origin.x + (edge == .trailing ? cardWidth : 0),
                y: origin.y + headerHeight + rowHeight * (CGFloat(index) + 0.5)
            )
        case .top:
            return CGPoint(x: origin.x + cardWidth / 2, y: origin.y)
        case .bottom:
            return CGPoint(x: origin.x + cardWidth / 2, y: origin.y + cardHeight(table))
        }
    }

    private func outwardVector(for edge: DiagramEdge) -> CGVector {
        switch edge {
        case .leading: return CGVector(dx: -1, dy: 0)
        case .trailing: return CGVector(dx: 1, dy: 0)
        case .top: return CGVector(dx: 0, dy: -1)
        case .bottom: return CGVector(dx: 0, dy: 1)
        }
    }

    private func perpendicularVector(for edge: DiagramEdge) -> CGVector {
        switch edge {
        case .leading, .trailing: return CGVector(dx: 0, dy: 1)
        case .top, .bottom: return CGVector(dx: 1, dy: 0)
        }
    }

    private func offset(_ point: CGPoint, along vector: CGVector, by amount: CGFloat) -> CGPoint {
        CGPoint(x: point.x + vector.dx * amount, y: point.y + vector.dy * amount)
    }

    private func drawManyMarker(
        at point: CGPoint,
        edge: DiagramEdge,
        optional: Bool,
        color: Color,
        context: inout GraphicsContext
    ) {
        let outward = outwardVector(for: edge)
        let perpendicular = perpendicularVector(for: edge)
        let tip = offset(point, along: outward, by: 2)
        let base = offset(point, along: outward, by: 13)

        var foot = Path()
        foot.move(to: tip)
        foot.addLine(to: CGPoint(x: base.x + perpendicular.dx * 7, y: base.y + perpendicular.dy * 7))
        foot.move(to: tip)
        foot.addLine(to: base)
        foot.move(to: tip)
        foot.addLine(to: CGPoint(x: base.x - perpendicular.dx * 7, y: base.y - perpendicular.dy * 7))
        context.stroke(foot, with: .color(color), lineWidth: 1.25)

        let qualifierCenter = offset(point, along: outward, by: 21)
        if optional {
            context.stroke(
                Path(ellipseIn: CGRect(x: qualifierCenter.x - 4, y: qualifierCenter.y - 4, width: 8, height: 8)),
                with: .color(color),
                lineWidth: 1.15
            )
        } else {
            var bar = Path()
            bar.move(to: CGPoint(x: qualifierCenter.x + perpendicular.dx * 6, y: qualifierCenter.y + perpendicular.dy * 6))
            bar.addLine(to: CGPoint(x: qualifierCenter.x - perpendicular.dx * 6, y: qualifierCenter.y - perpendicular.dy * 6))
            context.stroke(bar, with: .color(color), lineWidth: 1.25)
        }
    }

    private func drawOneMarker(
        at point: CGPoint,
        edge: DiagramEdge,
        color: Color,
        context: inout GraphicsContext
    ) {
        let outward = outwardVector(for: edge)
        let perpendicular = perpendicularVector(for: edge)
        for distance in [CGFloat(7), CGFloat(13)] {
            let center = offset(point, along: outward, by: distance)
            var bar = Path()
            bar.move(to: CGPoint(x: center.x + perpendicular.dx * 6, y: center.y + perpendicular.dy * 6))
            bar.addLine(to: CGPoint(x: center.x - perpendicular.dx * 6, y: center.y - perpendicular.dy * 6))
            context.stroke(bar, with: .color(color), lineWidth: 1.25)
        }
    }

    private func drawCardinalityLabels(
        sourceAnchor: CGPoint,
        sourceEdge: DiagramEdge,
        targetAnchor: CGPoint,
        targetEdge: DiagramEdge,
        optional: Bool,
        context: inout GraphicsContext
    ) {
        let sourceVector = outwardVector(for: sourceEdge)
        let targetVector = outwardVector(for: targetEdge)
        let sourceLabelPoint = offset(sourceAnchor, along: sourceVector, by: 34)
        let targetLabelPoint = offset(targetAnchor, along: targetVector, by: 27)
        let labelColor = printMode ? Color.black.opacity(0.85) : Color.primary.opacity(0.82)

        context.draw(
            Text(optional ? "0..*" : "1..*")
                .font(.system(size: printMode ? 8 : 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(labelColor),
            at: sourceLabelPoint,
            anchor: .center
        )
        context.draw(
            Text("1")
                .font(.system(size: printMode ? 8 : 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(labelColor),
            at: targetLabelPoint,
            anchor: .center
        )
    }

    private func cardPosition(_ table: EntityDiagramTable) -> CGPoint {
        let point = positions[table.name]?.cgPoint ?? .zero
        return CGPoint(x: point.x + cardWidth / 2, y: point.y + cardHeight(table) / 2)
    }

    private func cardHeight(_ table: EntityDiagramTable) -> CGFloat {
        headerHeight + CGFloat(min(table.columns.count, 14)) * rowHeight + (table.columns.count > 14 ? 28 : 0)
    }
}

private struct DiagramGridBackground: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 24
            var path = Path()
            stride(from: CGFloat.zero, through: size.width, by: spacing).forEach { x in
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
            }
            stride(from: CGFloat.zero, through: size.height, by: spacing).forEach { y in
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(Color.secondary.opacity(0.08)), lineWidth: 0.5)
        }
    }
}

private struct EntityTableCard: View {
    let table: EntityDiagramTable
    let selected: Bool
    var printMode = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "tablecells.fill")
                Text(table.name).font(.headline).lineLimit(1)
                Spacer()
                Text("\(table.columns.count)").font(.caption.monospacedDigit()).padding(.horizontal, 6).padding(.vertical, 2)
                    .background((printMode ? Color.black : Color.accentColor).opacity(0.10), in: Capsule())
            }
            .padding(.horizontal, 10).frame(height: 42)
            .background(printMode ? Color(nsColor: .windowBackgroundColor) : Color.accentColor.opacity(0.15))

            ForEach(Array(table.columns.prefix(14).enumerated()), id: \.element.id) { index, column in
                HStack(spacing: 7) {
                    Image(systemName: column.primary ? "key.fill" : (column.nullable ? "circle.dashed" : "circle.fill"))
                        .font(.system(size: column.primary ? 10 : 5))
                        .frame(width: 12)
                    Text(column.name).font(.caption.monospaced()).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(column.type).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    if column.nullable { Text("NULL").font(.system(size: 7, weight: .semibold)).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 9).frame(height: 24)
                .background(index.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(printMode ? 0.035 : 0.05))
                if index < min(table.columns.count, 14) - 1 { Divider() }
            }
            if table.columns.count > 14 {
                Text("+ \(table.columns.count - 14) more columns").font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(7)
            }
        }
        .background(printMode ? Color.white : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.secondary.opacity(printMode ? 0.55 : 0.35), lineWidth: selected ? 2.5 : 1))
        .shadow(color: .black.opacity(printMode ? 0.08 : 0.14), radius: printMode ? 4 : 3, y: 2)
    }
}

private struct EntityDiagramProgressView: View {
    let title: String
    let detail: String
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 30)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title3.bold())
                    Text("Database schema discovery and ERD layout").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(detail).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            ProgressView(value: progress, total: 1)
            Text("\(Int(progress * 100))% complete").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(26).frame(width: 470)
    }
}

private struct EntityDiagramPrintView: View {
    let projectName: String
    let diagramName: String
    let tables: [EntityDiagramTable]
    let relationships: [EntityDiagramRelationship]
    let positions: [String: DiagramPoint]
    let canvasSize: CGSize

    var body: some View {
        VStack(spacing: 0) {
            documentHeader

            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(red: 0.975, green: 0.98, blue: 0.99))
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.black.opacity(0.14), lineWidth: 1)

                EntityDiagramCanvasView(
                    tables: tables,
                    relationships: relationships,
                    positions: .constant(positions),
                    selectedTableName: .constant(nil),
                    printMode: true
                )
                .frame(width: canvasSize.width, height: canvasSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .padding(.horizontal, 48)
            .padding(.vertical, 24)

            documentFooter
        }
        .frame(width: canvasSize.width + 96, height: canvasSize.height + 230, alignment: .top)
        .background(Color.white)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.black.opacity(0.20), lineWidth: 1)
                .padding(14)
        )
        .environment(\.colorScheme, .light)
    }

    private var documentHeader: some View {
        HStack(alignment: .center, spacing: 24) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(red: 0.12, green: 0.35, blue: 0.68))
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 5) {
                Text("ABSDEV STUDIO")
                    .font(.caption.bold())
                    .tracking(1.8)
                    .foregroundStyle(Color(red: 0.12, green: 0.35, blue: 0.68))
                Text("Database Entity Relationship Diagram")
                    .font(.system(size: 26, weight: .bold))
                HStack(spacing: 8) {
                    Text(projectName).font(.title3.weight(.semibold))
                    Text("•").foregroundStyle(.tertiary)
                    Text(diagramName).font(.callout).foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    summaryBadge(value: tables.count, label: "Entities", symbol: "tablecells")
                    summaryBadge(value: relationships.count, label: "Relations", symbol: "arrow.triangle.branch")
                }
                Text("Generated \(Date().formatted(date: .long, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 34)
        .padding(.horizontal, 48)
        .padding(.bottom, 18)
    }

    private func summaryBadge(value: Int, label: String, symbol: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
            Text("\(value)").fontWeight(.semibold)
            Text(label)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    }

    private var documentFooter: some View {
        HStack(spacing: 18) {
            Text("RELATIONSHIP LEGEND").font(.caption2.bold()).tracking(1.1).foregroundStyle(.secondary)
            ERDLegendSymbol(kind: .requiredMany); Text("Required many")
            ERDLegendSymbol(kind: .optionalMany); Text("Optional many")
            ERDLegendSymbol(kind: .exactlyOne); Text("Exactly one")
            Spacer()
            Text("Generated by ABSDEV Studio")
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 48)
        .padding(.bottom, 28)
    }
}

private struct ERDLegendSymbol: View {
    enum Kind { case requiredMany, optionalMany, exactlyOne }
    let kind: Kind
    var body: some View {
        Text(kind == .requiredMany ? "|<" : kind == .optionalMany ? "o<" : "||")
            .font(.caption.monospaced().bold()).frame(width: 22)
    }
}
