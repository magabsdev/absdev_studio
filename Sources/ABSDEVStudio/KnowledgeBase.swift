import AppKit
import CoreData
import CryptoKit
import Foundation
import UniformTypeIdentifiers

@objc(KnowledgeDocument)
final class KnowledgeDocument: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var projectID: UUID
    @NSManaged var title: String
    @NSManaged var content: String
    @NSManaged var priorityRaw: Int16
    @NSManaged var sortOrder: Int32
    @NSManaged var createdAt: Date
    @NSManaged var updatedAt: Date
    @NSManaged var attachments: Set<KnowledgeAttachment>

    var priority: KnowledgePriority {
        get { KnowledgePriority(rawValue: priorityRaw) ?? .normal }
        set { priorityRaw = newValue.rawValue }
    }
}

@objc(KnowledgeAttachment)
final class KnowledgeAttachment: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var filename: String
    @NSManaged var storedFilename: String
    @NSManaged var relativePath: String
    @NSManaged var mimeType: String?
    @NSManaged var fileSize: Int64
    @NSManaged var checksum: String
    @NSManaged var createdAt: Date
    @NSManaged var document: KnowledgeDocument
}

enum KnowledgePriority: Int16, CaseIterable, Identifiable, Codable {
    case critical = 0, high = 1, normal = 2, low = 3
    var id: Int16 { rawValue }
    var title: String { switch self { case .critical: "Critical"; case .high: "High"; case .normal: "Normal"; case .low: "Low" } }
    var symbol: String { switch self { case .critical: "exclamationmark.octagon.fill"; case .high: "arrow.up.circle.fill"; case .normal: "minus.circle.fill"; case .low: "arrow.down.circle.fill" } }
}

enum KnowledgeImportStrategy { case merge, replace }

@MainActor
final class KnowledgeBaseController: ObservableObject {
    let container: NSPersistentContainer
    private let fileManager: FileManager
    let attachmentsRoot: URL

    init(storeURL: URL? = nil, attachmentsRoot: URL? = nil, inMemory: Bool = false, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ABSDEVStudio", isDirectory: true)
        self.attachmentsRoot = attachmentsRoot ?? support.appendingPathComponent("KnowledgeBaseAttachments", isDirectory: true)
        container = NSPersistentContainer(name: "ABSDEVKnowledge", managedObjectModel: Self.makeModel())
        let description = NSPersistentStoreDescription()
        description.type = inMemory ? NSInMemoryStoreType : NSSQLiteStoreType
        if !inMemory {
            let url = storeURL ?? support.appendingPathComponent("KnowledgeBase.sqlite")
            try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            description.url = url
            description.setOption(true as NSNumber, forKey: NSMigratePersistentStoresAutomaticallyOption)
            description.setOption(true as NSNumber, forKey: NSInferMappingModelAutomaticallyOption)
        }
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { fatalError("Unable to load Knowledge Base store: \(loadError)") }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        try? fileManager.createDirectory(at: self.attachmentsRoot, withIntermediateDirectories: true)
    }

    func documents(projectID: UUID, search: String = "") throws -> [KnowledgeDocument] {
        let request = NSFetchRequest<KnowledgeDocument>(entityName: "KnowledgeDocument")
        if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.predicate = NSPredicate(format: "projectID == %@", projectID as CVarArg)
        } else {
            request.predicate = NSPredicate(format: "projectID == %@ AND (title CONTAINS[cd] %@ OR content CONTAINS[cd] %@ OR ANY attachments.filename CONTAINS[cd] %@)", projectID as CVarArg, search, search, search)
        }
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true), NSSortDescriptor(key: "updatedAt", ascending: false)]
        return try container.viewContext.fetch(request)
    }

    @discardableResult
    func createDocument(projectID: UUID, title: String = "Untitled Document") throws -> KnowledgeDocument {
        let existing = try documents(projectID: projectID)
        let item = KnowledgeDocument(context: container.viewContext)
        item.id = UUID(); item.projectID = projectID; item.title = title; item.content = ""
        item.priority = .normal; item.sortOrder = (existing.map(\.sortOrder).max() ?? -1) + 1
        item.createdAt = Date(); item.updatedAt = item.createdAt; item.attachments = []
        try save()
        return item
    }

    func save() throws {
        guard container.viewContext.hasChanges else { return }
        try container.viewContext.save()
    }

    func touch(_ document: KnowledgeDocument) throws { document.updatedAt = Date(); try save() }

    func delete(_ document: KnowledgeDocument) throws {
        try? fileManager.removeItem(at: attachmentDirectory(projectID: document.projectID, documentID: document.id))
        container.viewContext.delete(document)
        try save()
        try normalizeOrder(projectID: document.projectID)
    }

    @discardableResult
    func duplicate(_ document: KnowledgeDocument) throws -> KnowledgeDocument {
        let copy = try createDocument(projectID: document.projectID, title: "\(document.title) Copy")
        copy.content = document.content; copy.priority = document.priority
        for attachment in document.attachments.sorted(by: { $0.filename < $1.filename }) {
            let source = attachmentURL(attachment)
            if fileManager.fileExists(atPath: source.path) { _ = try addAttachment(source, to: copy) }
        }
        try touch(copy)
        return copy
    }

    func move(document: KnowledgeDocument, to index: Int) throws {
        var items = try documents(projectID: document.projectID)
        guard let old = items.firstIndex(of: document) else { return }
        items.remove(at: old); items.insert(document, at: min(max(0, index), items.count))
        for (offset, item) in items.enumerated() { item.sortOrder = Int32(offset) }
        try save()
    }

    @discardableResult
    func addAttachment(_ source: URL, to document: KnowledgeDocument) throws -> KnowledgeAttachment {
        let granted = source.startAccessingSecurityScopedResource(); defer { if granted { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        let id = UUID(); let ext = source.pathExtension
        let stored = ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)"
        let directory = attachmentDirectory(projectID: document.projectID, documentID: document.id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(stored)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.copyItem(at: source, to: destination)

        let item = KnowledgeAttachment(context: container.viewContext)
        item.id = id; item.filename = source.lastPathComponent; item.storedFilename = stored
        item.relativePath = "\(document.projectID.uuidString)/\(document.id.uuidString)/\(stored)"
        item.mimeType = values.contentType?.identifier; item.fileSize = Int64(values.fileSize ?? 0)
        item.checksum = try Self.sha256(destination); item.createdAt = Date(); item.document = document
        document.updatedAt = Date(); try save(); return item
    }

    func removeAttachment(_ attachment: KnowledgeAttachment) throws {
        let document = attachment.document
        try? fileManager.removeItem(at: attachmentURL(attachment))
        container.viewContext.delete(attachment); document.updatedAt = Date(); try save()
    }

    func attachmentURL(_ attachment: KnowledgeAttachment) -> URL { attachmentsRoot.appendingPathComponent(attachment.relativePath) }
    func attachmentDirectory(projectID: UUID, documentID: UUID) -> URL { attachmentsRoot.appendingPathComponent(projectID.uuidString).appendingPathComponent(documentID.uuidString) }

    func exportProject(projectID: UUID, projectName: String, to destination: URL) throws -> URL {
        let package = destination.appendingPathComponent("\(projectName).absdevknowledge", isDirectory: true)
        if fileManager.fileExists(atPath: package.path) { try fileManager.removeItem(at: package) }
        try fileManager.createDirectory(at: package, withIntermediateDirectories: true)
        let attachmentDestination = package.appendingPathComponent("attachments", isDirectory: true)
        try fileManager.createDirectory(at: attachmentDestination, withIntermediateDirectories: true)
        let records = try documents(projectID: projectID).map { document -> TransferDocument in
            let attachments = try document.attachments.map { item -> TransferAttachment in
                let source = attachmentURL(item)
                let relative = "\(document.id.uuidString)/\(item.storedFilename)"
                let target = attachmentDestination.appendingPathComponent(relative)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: source.path) { try fileManager.copyItem(at: source, to: target) }
                return TransferAttachment(id: item.id, filename: item.filename, storedFilename: item.storedFilename, mimeType: item.mimeType, fileSize: item.fileSize, checksum: item.checksum, createdAt: item.createdAt, packagePath: relative)
            }
            return TransferDocument(id: document.id, title: document.title, content: document.content, priority: document.priorityRaw, sortOrder: document.sortOrder, createdAt: document.createdAt, updatedAt: document.updatedAt, attachments: attachments)
        }
        let manifest = TransferManifest(formatVersion: 1, sourceProjectID: projectID, projectName: projectName, exportedAt: Date(), documents: records)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: package.appendingPathComponent("manifest.json"), options: .atomic)
        return package
    }

    func importProject(from package: URL, into projectID: UUID, strategy: KnowledgeImportStrategy) throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(TransferManifest.self, from: Data(contentsOf: package.appendingPathComponent("manifest.json")))
        if case .replace = strategy { for item in try documents(projectID: projectID) { try delete(item) } }
        let request = NSFetchRequest<KnowledgeDocument>(entityName: "KnowledgeDocument")
        for record in manifest.documents {
            request.predicate = NSPredicate(format: "projectID == %@ AND id == %@", projectID as CVarArg, record.id as CVarArg)
            let existing = try container.viewContext.fetch(request).first
            if let existing, existing.updatedAt >= record.updatedAt { continue }
            let document = existing ?? KnowledgeDocument(context: container.viewContext)
            if existing == nil { document.id = record.id; document.projectID = projectID; document.attachments = [] }
            document.title = record.title; document.content = record.content; document.priorityRaw = record.priority
            document.sortOrder = record.sortOrder; document.createdAt = record.createdAt; document.updatedAt = record.updatedAt
            for attachment in record.attachments where !document.attachments.contains(where: { $0.id == attachment.id && $0.checksum == attachment.checksum }) {
                let source = package.appendingPathComponent("attachments").appendingPathComponent(attachment.packagePath)
                guard fileManager.fileExists(atPath: source.path), try Self.sha256(source) == attachment.checksum else { continue }
                let directory = attachmentDirectory(projectID: projectID, documentID: document.id)
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(attachment.storedFilename)
                if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
                try fileManager.copyItem(at: source, to: destination)
                let item = KnowledgeAttachment(context: container.viewContext)
                item.id = attachment.id; item.filename = attachment.filename; item.storedFilename = attachment.storedFilename
                item.relativePath = "\(projectID.uuidString)/\(document.id.uuidString)/\(attachment.storedFilename)"
                item.mimeType = attachment.mimeType; item.fileSize = attachment.fileSize; item.checksum = attachment.checksum
                item.createdAt = attachment.createdAt; item.document = document
            }
        }
        try save(); try normalizeOrder(projectID: projectID)
    }

    private func normalizeOrder(projectID: UUID) throws {
        for (index, item) in try documents(projectID: projectID).enumerated() { item.sortOrder = Int32(index) }
        try save()
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: { () -> Bool in
            let data = try? handle.read(upToCount: 1024 * 1024)
            guard let data, !data.isEmpty else { return false }
            hasher.update(data: data); return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let document = NSEntityDescription(); document.name = "KnowledgeDocument"; document.managedObjectClassName = NSStringFromClass(KnowledgeDocument.self)
        let attachment = NSEntityDescription(); attachment.name = "KnowledgeAttachment"; attachment.managedObjectClassName = NSStringFromClass(KnowledgeAttachment.self)
        func attribute(_ name: String, _ type: NSAttributeType, optional: Bool = false, defaultValue: Any? = nil) -> NSAttributeDescription {
            let value = NSAttributeDescription(); value.name = name; value.attributeType = type; value.isOptional = optional; value.defaultValue = defaultValue; return value
        }
        document.properties = [attribute("id", .UUIDAttributeType), attribute("projectID", .UUIDAttributeType), attribute("title", .stringAttributeType, defaultValue: "Untitled Document"), attribute("content", .stringAttributeType, defaultValue: ""), attribute("priorityRaw", .integer16AttributeType, defaultValue: 2), attribute("sortOrder", .integer32AttributeType, defaultValue: 0), attribute("createdAt", .dateAttributeType), attribute("updatedAt", .dateAttributeType)]
        attachment.properties = [attribute("id", .UUIDAttributeType), attribute("filename", .stringAttributeType), attribute("storedFilename", .stringAttributeType), attribute("relativePath", .stringAttributeType), attribute("mimeType", .stringAttributeType, optional: true), attribute("fileSize", .integer64AttributeType, defaultValue: 0), attribute("checksum", .stringAttributeType), attribute("createdAt", .dateAttributeType)]
        let toAttachments = NSRelationshipDescription(); toAttachments.name = "attachments"; toAttachments.destinationEntity = attachment; toAttachments.minCount = 0; toAttachments.maxCount = 0; toAttachments.deleteRule = .cascadeDeleteRule; toAttachments.isOptional = true; toAttachments.isOrdered = false
        let toDocument = NSRelationshipDescription(); toDocument.name = "document"; toDocument.destinationEntity = document; toDocument.minCount = 1; toDocument.maxCount = 1; toDocument.deleteRule = .nullifyDeleteRule; toDocument.isOptional = false
        toAttachments.inverseRelationship = toDocument; toDocument.inverseRelationship = toAttachments
        document.properties.append(toAttachments); attachment.properties.append(toDocument)
        document.uniquenessConstraints = [["projectID", "id"]]; attachment.uniquenessConstraints = [["id"]]
        model.entities = [document, attachment]; return model
    }
}

private struct TransferManifest: Codable { let formatVersion: Int; let sourceProjectID: UUID; let projectName: String; let exportedAt: Date; let documents: [TransferDocument] }
private struct TransferDocument: Codable { let id: UUID; let title: String; let content: String; let priority: Int16; let sortOrder: Int32; let createdAt: Date; let updatedAt: Date; let attachments: [TransferAttachment] }
private struct TransferAttachment: Codable { let id: UUID; let filename: String; let storedFilename: String; let mimeType: String?; let fileSize: Int64; let checksum: String; let createdAt: Date; let packagePath: String }
