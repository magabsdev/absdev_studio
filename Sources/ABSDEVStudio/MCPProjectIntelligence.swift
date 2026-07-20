import Foundation

struct MCPIndexedSymbol: Codable, Hashable, Sendable {
    let name: String
    let kind: String
    let path: String
    let line: Int
    let signature: String
}

struct MCPIndexedDocument: Codable, Hashable, Sendable {
    let path: String
    let modifiedAt: Date
    let size: Int
    let language: String
    let tokens: [String]
    let symbols: [MCPIndexedSymbol]
}

struct MCPProjectIndexSnapshot: Codable, Sendable {
    let projectID: String
    let rootPath: String
    let generatedAt: Date
    let documents: [MCPIndexedDocument]
}

/// Local, dependency-free project intelligence used by the embedded MCP server.
/// It maintains a persistent lexical/symbol index and refreshes changed files incrementally.
final class MCPProjectIntelligence: @unchecked Sendable {
    static let shared = MCPProjectIntelligence()

    private let lock = NSLock()
    private var snapshots: [String: MCPProjectIndexSnapshot] = [:]
    private var conversations: [String: [String]] = [:]
    private let fm = FileManager.default

    private init() {}

    func refresh(project: MCPProjectDefinition, files: [(URL, String)], force: Bool = false) -> MCPProjectIndexSnapshot {
        lock.lock(); defer { lock.unlock() }
        let normalizedRoot = normalizedRootPath(project.rootPath)
        let candidate = snapshots[project.id] ?? load(projectID: project.id)
        let old = candidate.flatMap { normalizedRootPath($0.rootPath) == normalizedRoot ? $0 : nil }
        if candidate != nil && old == nil {
            snapshots.removeValue(forKey: project.id)
            try? fm.removeItem(at: indexURL(projectID: project.id))
        }
        let oldByPath = Dictionary(uniqueKeysWithValues: (old?.documents ?? []).map { ($0.path, $0) })
        var documents: [MCPIndexedDocument] = []
        documents.reserveCapacity(files.count)

        for (url, relative) in files {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate else { continue }
            let size = values.fileSize ?? 0
            if !force, let cached = oldByPath[relative], cached.modifiedAt == modified, cached.size == size {
                documents.append(cached)
                continue
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            documents.append(MCPIndexedDocument(
                path: relative,
                modifiedAt: modified,
                size: size,
                language: language(for: url),
                tokens: Array(Set(tokenize(relative + "\n" + String(text.prefix(250_000))))).sorted(),
                symbols: extractSymbols(text: text, path: relative)
            ))
        }

        let snapshot = MCPProjectIndexSnapshot(projectID: project.id, rootPath: project.rootPath, generatedAt: Date(), documents: documents.sorted { $0.path < $1.path })
        snapshots[project.id] = snapshot
        save(snapshot)
        return snapshot
    }

    /// Rebuilds an index directly from the configured project root. This is used by the native UI and
    /// avoids depending on an MCP client request to discover files first.
    func rebuild(project: MCPProjectDefinition, force: Bool = true) throws -> MCPProjectIndexSnapshot {
        let files = try discoverProjectFiles(project: project)
        guard !files.isEmpty else {
            throw MCPServerError.invalidArguments("No indexable source files were found under \(project.rootPath). Check the project path and exclude rules.")
        }
        let snapshot = refresh(project: project, files: files, force: force)
        try saveThrowing(snapshot)
        return snapshot
    }

    func persistedStatus(project: MCPProjectDefinition) throws -> [String: Any] {
        let url = indexURL(projectID: project.id)
        guard fm.fileExists(atPath: url.path) else {
            return [
                "indexed": false,
                "project": project.id,
                "indexPath": url.path,
                "message": "No index has been created yet."
            ]
        }
        let snapshot = try JSONDecoder().decode(MCPProjectIndexSnapshot.self, from: Data(contentsOf: url))
        guard normalizedRootPath(snapshot.rootPath) == normalizedRootPath(project.rootPath) else {
            try? fm.removeItem(at: url)
            lock.lock(); snapshots.removeValue(forKey: project.id); lock.unlock()
            return [
                "indexed": false,
                "project": project.id,
                "indexPath": url.path,
                "message": "The saved index belonged to a different project root and was removed. Rebuild the index."
            ]
        }
        return [
            "indexed": true,
            "project": project.id,
            "generatedAt": ISO8601DateFormatter().string(from: snapshot.generatedAt),
            "fileCount": snapshot.documents.count,
            "symbolCount": snapshot.documents.reduce(0) { $0 + $1.symbols.count },
            "indexPath": url.path
        ]
    }

    func removeIndex(projectID: String) throws {
        lock.lock(); snapshots.removeValue(forKey: projectID); lock.unlock()
        let url = indexURL(projectID: projectID)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    }

    func status(project: MCPProjectDefinition, files: [(URL, String)]) -> [String: Any] {
        let snapshot = refresh(project: project, files: files)
        let symbols = snapshot.documents.reduce(0) { $0 + $1.symbols.count }
        let languages = Dictionary(grouping: snapshot.documents, by: \.language).mapValues(\.count)
        return [
            "generatedAt": ISO8601DateFormatter().string(from: snapshot.generatedAt),
            "fileCount": snapshot.documents.count,
            "symbolCount": symbols,
            "languages": languages,
            "indexPath": indexURL(projectID: project.id).path,
            "mode": "incremental lexical and structured symbol index"
        ]
    }

    func semanticMatches(project: MCPProjectDefinition, files: [(URL, String)], question: String, limit: Int) -> [[String: Any]] {
        let snapshot = refresh(project: project, files: files)
        let query = Set(tokenize(question))
        let symbolHints = significantTerms(question)
        return snapshot.documents.compactMap { document -> (Int, MCPIndexedDocument)? in
            let overlap = query.intersection(Set(document.tokens)).count
            let pathScore = symbolHints.reduce(0) { $0 + (document.path.localizedCaseInsensitiveContains($1) ? 8 : 0) }
            let symbolScore = document.symbols.reduce(0) { partial, symbol in
                partial + (symbolHints.contains(where: { symbol.name.localizedCaseInsensitiveContains($0) }) ? 12 : 0)
            }
            let score = overlap * 2 + pathScore + symbolScore
            return score > 0 ? (score, document) : nil
        }
        .sorted { $0.0 > $1.0 }
        .prefix(limit)
        .map { score, document in
            ["path": document.path, "score": score, "language": document.language, "symbols": document.symbols.prefix(20).map { ["name": $0.name, "kind": $0.kind, "line": $0.line, "signature": $0.signature] }]
        }
    }

    func definitions(project: MCPProjectDefinition, files: [(URL, String)], symbol: String, limit: Int) -> [[String: Any]] {
        let snapshot = refresh(project: project, files: files)
        return snapshot.documents.flatMap(\.symbols)
            .filter { $0.name.localizedCaseInsensitiveContains(symbol) }
            .prefix(limit)
            .map { ["name": $0.name, "kind": $0.kind, "path": $0.path, "line": $0.line, "signature": $0.signature] }
    }

    func dependencyGraph(project: MCPProjectDefinition, files: [(URL, String)], limit: Int) -> [[String: Any]] {
        var edges: [[String: Any]] = []
        for (url, relative) in files.prefix(2_000) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for target in imports(text: text, extension: url.pathExtension.lowercased()) {
                edges.append(["source": relative, "target": target])
                if edges.count >= limit { return edges }
            }
        }
        return edges
    }

    func remember(session: String, question: String) {
        lock.lock(); defer { lock.unlock() }
        var history = conversations[session] ?? []
        history.append(question)
        conversations[session] = Array(history.suffix(12))
    }

    func conversationContext(session: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return conversations[session] ?? []
    }

    func previewEdit(project: MCPProjectDefinition, relativePath: String, find: String, replace: String) throws -> [String: Any] {
        let url = try safeURL(project: project, relativePath: relativePath)
        guard let original = try? String(contentsOf: url, encoding: .utf8) else { throw MCPServerError.notTextFile(relativePath) }
        guard !find.isEmpty, original.contains(find) else { throw MCPServerError.invalidArguments("The exact text to replace was not found in \(relativePath).") }
        let updated = original.replacingOccurrences(of: find, with: replace)
        return ["path": relativePath, "changed": original != updated, "occurrences": original.components(separatedBy: find).count - 1, "preview": unifiedPreview(original: original, updated: updated)]
    }

    func applyEdit(project: MCPProjectDefinition, relativePath: String, find: String, replace: String, expectedSHA256: String?) throws -> [String: Any] {
        let url = try safeURL(project: project, relativePath: relativePath)
        let data = try Data(contentsOf: url)
        let currentHash = simpleHash(data)
        if let expectedSHA256, !expectedSHA256.isEmpty, expectedSHA256 != currentHash {
            throw MCPServerError.invalidArguments("File changed since preview. Expected hash \(expectedSHA256), current hash \(currentHash).")
        }
        guard let original = String(data: data, encoding: .utf8), !find.isEmpty, original.contains(find) else {
            throw MCPServerError.invalidArguments("The exact text to replace was not found in \(relativePath).")
        }
        let updated = original.replacingOccurrences(of: find, with: replace)
        let backup = url.appendingPathExtension("absdev-backup")
        try data.write(to: backup, options: .atomic)
        try Data(updated.utf8).write(to: url, options: .atomic)
        return ["path": relativePath, "backup": backup.path, "previousHash": currentHash, "newHash": simpleHash(Data(updated.utf8))]
    }

    func fileHash(project: MCPProjectDefinition, relativePath: String) throws -> String {
        simpleHash(try Data(contentsOf: safeURL(project: project, relativePath: relativePath)))
    }

    private func extractSymbols(text: String, path: String) -> [MCPIndexedSymbol] {
        let patterns: [(String, String)] = [
            ("class", "\\b(?:final\\s+)?class\\s+([A-Za-z_][A-Za-z0-9_]*)"),
            ("struct", "\\bstruct\\s+([A-Za-z_][A-Za-z0-9_]*)"),
            ("enum", "\\benum\\s+([A-Za-z_][A-Za-z0-9_]*)"),
            ("protocol", "\\b(?:protocol|interface|trait)\\s+([A-Za-z_][A-Za-z0-9_]*)"),
            ("function", "\\b(?:func|function|def|fn)\\s+([A-Za-z_][A-Za-z0-9_]*)"),
            ("route", "Route::[A-Za-z]+\\([^\\n]*?(?:->name\\(['\"]([^'\"]+)|['\"]([^'\"]+)['\"])"),
        ]
        let lines = text.components(separatedBy: .newlines)
        var output: [MCPIndexedSymbol] = []
        for (lineIndex, line) in lines.enumerated() {
            for (kind, pattern) in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)) else { continue }
                var name: String?
                for idx in 1..<match.numberOfRanges where match.range(at: idx).location != NSNotFound {
                    if let range = Range(match.range(at: idx), in: line) { name = String(line[range]); break }
                }
                if let name { output.append(MCPIndexedSymbol(name: name, kind: kind, path: path, line: lineIndex + 1, signature: String(line.trimmingCharacters(in: .whitespaces).prefix(500)))) }
            }
        }
        return output
    }

    private func imports(text: String, extension ext: String) -> [String] {
        let patterns: [String]
        switch ext {
        case "swift": patterns = ["(?m)^\\s*import\\s+([A-Za-z0-9_.]+)"]
        case "php": patterns = ["(?m)^\\s*use\\s+([^;]+)", "(?m)require(?:_once)?\\s*\\(?['\"]([^'\"]+)"]
        case "js", "ts", "tsx", "jsx": patterns = ["from\\s+['\"]([^'\"]+)", "require\\(['\"]([^'\"]+)"]
        case "py": patterns = ["(?m)^\\s*(?:from|import)\\s+([A-Za-z0-9_.]+)"]
        default: patterns = []
        }
        var values: [String] = []
        for pattern in patterns where values.count < 100 {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) where match.numberOfRanges > 1 {
                if let range = Range(match.range(at: 1), in: text) { values.append(String(text[range])) }
            }
        }
        return values
    }

    private func tokenize(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 && !Self.stopWords.contains($0) }
    }

    private func significantTerms(_ text: String) -> [String] { Array(Set(tokenize(text))).sorted { $0.count > $1.count }.prefix(24).map { $0 } }
    private func language(for url: URL) -> String { url.pathExtension.lowercased().isEmpty ? url.lastPathComponent : url.pathExtension.lowercased() }

    private func safeURL(project: MCPProjectDefinition, relativePath: String) throws -> URL {
        let root = URL(fileURLWithPath: project.rootPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else { throw MCPServerError.pathTraversal }
        return candidate
    }

    private func unifiedPreview(original: String, updated: String) -> String {
        let before = original.components(separatedBy: .newlines)
        let after = updated.components(separatedBy: .newlines)
        var output = ["--- original", "+++ updated"]
        for index in 0..<max(before.count, after.count) {
            let lhs = index < before.count ? before[index] : nil
            let rhs = index < after.count ? after[index] : nil
            if lhs != rhs {
                if let lhs { output.append("-\(lhs)") }
                if let rhs { output.append("+\(rhs)") }
            }
            if output.count > 400 { output.append("…preview truncated…"); break }
        }
        return output.joined(separator: "\n")
    }

    private func simpleHash(_ data: Data) -> String {
        // Stable change-detection hash without adding a CryptoKit dependency to this file.
        var hash: UInt64 = 1469598103934665603
        for byte in data { hash ^= UInt64(byte); hash &*= 1099511628211 }
        return String(format: "%016llx", hash)
    }


    private func normalizedRootPath(_ rawPath: String) -> String {
        URL(fileURLWithPath: NSString(string: rawPath).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private func indexURL(projectID: String) -> URL {
        let directory = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ABSDEVStudio/MCPIndexes", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(projectID + ".json")
    }
    private func save(_ snapshot: MCPProjectIndexSnapshot) {
        do { try saveThrowing(snapshot) }
        catch {
            // The explicit rebuild API surfaces this error to the UI. Automatic incremental refreshes
            // remain usable in memory even when persistence is temporarily unavailable.
        }
    }

    private func saveThrowing(_ snapshot: MCPProjectIndexSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)
        try data.write(to: indexURL(projectID: snapshot.projectID), options: .atomic)
    }

    private func load(projectID: String) -> MCPProjectIndexSnapshot? {
        try? JSONDecoder().decode(MCPProjectIndexSnapshot.self, from: Data(contentsOf: indexURL(projectID: projectID)))
    }

    private func discoverProjectFiles(project: MCPProjectDefinition, maximumBytes: Int = 1_500_000) throws -> [(URL, String)] {
        let root = URL(fileURLWithPath: NSString(string: project.rootPath).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MCPServerError.projectRootMissing(root.path)
        }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw MCPServerError.invalidArguments("Unable to enumerate project folder \(root.path).")
        }
        let extensions = Set(["swift", "php", "js", "ts", "tsx", "jsx", "py", "rb", "java", "kt", "kts", "go", "rs", "c", "h", "cpp", "hpp", "cs", "json", "xml", "yml", "yaml", "toml", "md", "sql"])
        var files: [(URL, String)] = []
        for case let url as URL in enumerator {
            let relative = String(url.path.dropFirst(root.path.count + 1)).replacingOccurrences(of: "\\", with: "/")
            if isExcluded(relative, project: project) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                continue
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            let lower = relative.lowercased()
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= maximumBytes,
                  extensions.contains(url.pathExtension.lowercased()) || lower.hasSuffix(".blade.php") || url.lastPathComponent == "Package.swift" else { continue }
            files.append((url, relative))
        }
        return files
    }

    private func isExcluded(_ relativePath: String, project: MCPProjectDefinition) -> Bool {
        let path = relativePath.replacingOccurrences(of: "\\", with: "/")
        return project.exclude.contains { pattern in
            let normalized = pattern.replacingOccurrences(of: "\\", with: "/")
            let prefix = normalized.replacingOccurrences(of: "/**", with: "").replacingOccurrences(of: "**/", with: "")
            if normalized.hasPrefix("*.") { return path.lowercased().hasSuffix(String(normalized.dropFirst()).lowercased()) }
            return path == prefix || path.hasPrefix(prefix + "/")
        }
    }

    private static let stopWords: Set<String> = ["the", "and", "for", "with", "this", "that", "from", "where", "what", "why", "how", "does", "are", "into", "about", "project", "code", "file", "files"]
}
