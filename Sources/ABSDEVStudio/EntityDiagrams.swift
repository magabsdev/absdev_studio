import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

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
        let view = NSHostingView(rootView: EntityDiagramPrintView(projectName: project.name, diagramName: selectedDiagramName, tables: tables, relationships: relationships, positions: positions, canvasSize: size))
        view.frame = CGRect(origin: .zero, size: documentSize)
        view.layoutSubtreeIfNeeded()
        let data = view.dataWithPDF(inside: view.bounds)
        do {
            try data.write(to: url, options: .atomic)
            status = "Exported PDF to \(url.lastPathComponent)."
        } catch {
            status = "PDF export failed: \(error.localizedDescription)"
        }
    }

    func printDiagram(project: LaravelProject) {
        guard !tables.isEmpty else { status = "There is no diagram to print."; return }
        let size = canvasSize
        let documentSize = CGSize(width: size.width + 96, height: size.height + 230)
        let view = NSHostingView(rootView: EntityDiagramPrintView(projectName: project.name, diagramName: selectedDiagramName, tables: tables, relationships: relationships, positions: positions, canvasSize: size))
        view.frame = CGRect(origin: .zero, size: documentSize)
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.orientation = documentSize.width > documentSize.height ? .landscape : .portrait
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        NSPrintOperation(view: view, printInfo: info).run()
        status = "Print dialog opened for \(project.name)."
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
            relationships.append(contentsOf: parsed.relationships)
        }
        return .success((tables, Array(Set(relationships))))
    }

    nonisolated private static func resolvePHP(preferred: String?, cwd: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [preferred].compactMap { $0 }
        candidates += [
            "\(home)/Library/Application Support/Herd/bin/php", "\(home)/.config/herd-lite/bin/php",
            "/Applications/ServBay/package/php/current/bin/php", "/opt/homebrew/opt/php@8.4/bin/php",
            "/opt/homebrew/opt/php@8.3/bin/php", "/opt/homebrew/opt/php@8.2/bin/php",
            "/opt/homebrew/bin/php", "/usr/local/bin/php", "/usr/bin/php"
        ]
        candidates += shell("which -a php 2>/dev/null || true", cwd: cwd).output.split(separator: "\n").map(String.init)
        var seen = Set<String>()
        return candidates.first { candidate in
            guard seen.insert(candidate).inserted, FileManager.default.isExecutableFile(atPath: candidate) else { return false }
            return shell("\(quote(candidate)) -r 'echo PHP_VERSION;'", cwd: cwd).status == 0
        }
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
        let foreignRows = (payload["foreign_keys"] as? [[String: Any]]) ?? (payload["foreignKeys"] as? [[String: Any]]) ?? []
        let relationships = foreignRows.compactMap { row -> EntityDiagramRelationship? in
            let source = (row["column"] ?? row["columns"] ?? row["local_column"]) as? String
            let targetTable = (row["foreign_table"] ?? row["foreignTable"] ?? row["referenced_table"] ?? row["table"]) as? String
            let targetColumn = (row["foreign_column"] ?? row["foreignColumn"] ?? row["referenced_column"]) as? String
            guard let source, let targetTable else { return nil }
            return EntityDiagramRelationship(sourceTable: name, sourceColumn: source, targetTable: targetTable, targetColumn: targetColumn ?? "id")
        }
        return (EntityDiagramTable(name: name, columns: columns), relationships)
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
            if !printMode {
                DiagramGridBackground()
            }
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

    private func drawRelationship(_ relationship: EntityDiagramRelationship, in context: inout GraphicsContext) {
        guard let sourceTable = tables.first(where: { $0.name == relationship.sourceTable }),
              let targetTable = tables.first(where: { $0.name == relationship.targetTable }),
              let sourceOrigin = positions[relationship.sourceTable]?.cgPoint,
              let targetOrigin = positions[relationship.targetTable]?.cgPoint else { return }

        let sourceOnLeft = sourceOrigin.x <= targetOrigin.x
        let sourceAnchor = columnAnchor(table: sourceTable, column: relationship.sourceColumn, origin: sourceOrigin, trailing: sourceOnLeft)
        let targetAnchor = columnAnchor(table: targetTable, column: relationship.targetColumn, origin: targetOrigin, trailing: !sourceOnLeft)
        let direction: CGFloat = sourceOnLeft ? 1 : -1
        let elbowOffset: CGFloat = 28
        let middleX = (sourceAnchor.x + targetAnchor.x) / 2

        var path = Path()
        path.move(to: sourceAnchor)
        path.addLine(to: CGPoint(x: sourceAnchor.x + direction * elbowOffset, y: sourceAnchor.y))
        path.addLine(to: CGPoint(x: middleX, y: sourceAnchor.y))
        path.addLine(to: CGPoint(x: middleX, y: targetAnchor.y))
        path.addLine(to: CGPoint(x: targetAnchor.x - direction * elbowOffset, y: targetAnchor.y))
        path.addLine(to: targetAnchor)
        context.stroke(path, with: .color(printMode ? Color.black.opacity(0.72) : Color.accentColor.opacity(0.72)), lineWidth: printMode ? 1.25 : 1.6)

        let nullable = sourceTable.columns.first(where: { $0.name == relationship.sourceColumn })?.nullable ?? false
        drawCrowFoot(at: sourceAnchor, direction: direction, optional: nullable, context: &context)
        drawOneMarker(at: targetAnchor, direction: -direction, context: &context)
    }

    private func columnAnchor(table: EntityDiagramTable, column: String, origin: CGPoint, trailing: Bool) -> CGPoint {
        let visibleColumns = Array(table.columns.prefix(14))
        let index = visibleColumns.firstIndex(where: { $0.name == column }) ?? 0
        return CGPoint(
            x: origin.x + (trailing ? cardWidth : 0),
            y: origin.y + headerHeight + rowHeight * (CGFloat(index) + 0.5)
        )
    }

    private func drawCrowFoot(at point: CGPoint, direction: CGFloat, optional: Bool, context: inout GraphicsContext) {
        let markerColor = printMode ? Color.black.opacity(0.8) : Color.accentColor
        let base = CGPoint(x: point.x + direction * 10, y: point.y)
        var foot = Path()
        foot.move(to: point)
        foot.addLine(to: CGPoint(x: base.x, y: base.y - 7))
        foot.move(to: point)
        foot.addLine(to: base)
        foot.move(to: point)
        foot.addLine(to: CGPoint(x: base.x, y: base.y + 7))
        context.stroke(foot, with: .color(markerColor), lineWidth: 1.4)

        if optional {
            let circleRect = CGRect(x: point.x + direction * 14 - 4, y: point.y - 4, width: 8, height: 8)
            context.stroke(Path(ellipseIn: circleRect), with: .color(markerColor), lineWidth: 1.2)
        } else {
            var bar = Path()
            let x = point.x + direction * 15
            bar.move(to: CGPoint(x: x, y: point.y - 6))
            bar.addLine(to: CGPoint(x: x, y: point.y + 6))
            context.stroke(bar, with: .color(markerColor), lineWidth: 1.4)
        }
    }

    private func drawOneMarker(at point: CGPoint, direction: CGFloat, context: inout GraphicsContext) {
        let markerColor = printMode ? Color.black.opacity(0.8) : Color.accentColor
        for offset in [CGFloat(7), CGFloat(13)] {
            let x = point.x + direction * offset
            var bar = Path()
            bar.move(to: CGPoint(x: x, y: point.y - 6))
            bar.addLine(to: CGPoint(x: x, y: point.y + 6))
            context.stroke(bar, with: .color(markerColor), lineWidth: 1.4)
        }
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
            Divider().padding(.horizontal, 36)
            EntityDiagramCanvasView(
                tables: tables,
                relationships: relationships,
                positions: .constant(positions),
                selectedTableName: .constant(nil),
                printMode: true
            )
            .frame(width: canvasSize.width, height: canvasSize.height)
            .padding(.horizontal, 48).padding(.vertical, 24)
            documentFooter
        }
        .frame(width: canvasSize.width + 96, height: canvasSize.height + 230, alignment: .top)
        .background(Color.white)
        .overlay(Rectangle().stroke(Color.black.opacity(0.18), lineWidth: 1).padding(14))
        .environment(\.colorScheme, .light)
    }

    private var documentHeader: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                Text("ABSDEV STUDIO").font(.caption.bold()).tracking(1.8).foregroundStyle(.secondary)
                Text("Database Entity Relationship Diagram").font(.system(size: 26, weight: .bold))
                Text(projectName).font(.title3.weight(.semibold))
                Text(diagramName).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                Label("\(tables.count) entities", systemImage: "tablecells")
                Label("\(relationships.count) relationships", systemImage: "arrow.triangle.branch")
                Text(Date().formatted(date: .long, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }.font(.callout.monospacedDigit())
        }
        .padding(.top, 34).padding(.horizontal, 48).padding(.bottom, 20)
    }

    private var documentFooter: some View {
        HStack(spacing: 22) {
            ERDLegendSymbol(kind: .requiredMany); Text("Required many")
            ERDLegendSymbol(kind: .optionalMany); Text("Optional many")
            ERDLegendSymbol(kind: .exactlyOne); Text("Exactly one")
            Spacer()
            Text("Generated by ABSDEV Studio").foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 48).padding(.bottom, 28)
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
