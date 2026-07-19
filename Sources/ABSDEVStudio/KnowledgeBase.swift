import AppKit
import CoreData
import CoreSpotlight
import CryptoKit
import Observation
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

@objc(KBDocument) final class KBDocument: NSManagedObject, Identifiable {
  @NSManaged var id: UUID
  @NSManaged var projectID: UUID
  @NSManaged var title: String
  @NSManaged var text: String
  @NSManaged var priority: Int16
  @NSManaged var order: Int32
  @NSManaged var createdAt: Date
  @NSManaged var updatedAt: Date
  @NSManaged var attachments: Set<KBAttachment>
  @NSManaged var richTextData: Data?
  @NSManaged var tags: String
  @NSManaged var isFavorite: Bool
  @NSManaged var isTrashed: Bool
  @NSManaged var deletedAt: Date?
  @NSManaged var version: Int32
}
@objc(KBAttachment) final class KBAttachment: NSManagedObject, Identifiable {
  @NSManaged var id: UUID
  @NSManaged var name: String
  @NSManaged var relativePath: String
  @NSManaged var size: Int64
  @NSManaged var checksum: String
  @NSManaged var createdAt: Date
  @NSManaged var data: Data?
  @NSManaged var document: KBDocument
}

enum KBPriority: Int16, CaseIterable, Identifiable, Codable {
  case critical, high, normal, low
  var id: Int16 { rawValue }
  var name: String { ["Critical", "High", "Normal", "Low"][Int(rawValue)] }
  var icon: String {
    [
      "exclamationmark.octagon.fill", "arrow.up.circle.fill", "minus.circle.fill",
      "arrow.down.circle.fill",
    ][Int(rawValue)]
  }
  var colour: Color { [Color.red, .orange, .blue, .secondary][Int(rawValue)] }
}
enum KBSort: String, CaseIterable, Identifiable {
  case custom = "Custom"
  case priority = "Priority"
  case updated = "Updated"
  case title = "Title"
  var id: String { rawValue }
}

final class KBPersistence {
  static let shared = KBPersistence()

  let container: NSPersistentCloudKitContainer
  private(set) var cloudSyncEnabled = false
  private(set) var startupError: String?

  init(memory: Bool = false) {
    let model = Self.model()
    let primary = NSPersistentCloudKitContainer(name: "ABSDEVKnowledge", managedObjectModel: model)
    let storeURL = Self.support.appendingPathComponent("KnowledgeBase.sqlite")

    let cloudDescription = Self.storeDescription(
      memory: memory,
      url: storeURL,
      cloudKitEnabled: !memory
    )
    primary.persistentStoreDescriptions = [cloudDescription]

    var cloudError: Error?
    primary.loadPersistentStores { _, error in
      cloudError = error
    }

    if let cloudError, !memory {
      let nsError = cloudError as NSError
      NSLog(
        "ABSDEV Knowledge Base iCloud store failed to load: %@ (%@)",
        nsError.localizedDescription,
        nsError.userInfo.description
      )

      // Keep the user's existing database available even when CloudKit is not
      // configured for the current signing team or iCloud account. The same
      // SQLite store is opened locally, so no documents are discarded.
      let local = NSPersistentCloudKitContainer(name: "ABSDEVKnowledge", managedObjectModel: model)
      local.persistentStoreDescriptions = [
        Self.storeDescription(memory: false, url: storeURL, cloudKitEnabled: false)
      ]

      var localError: Error?
      local.loadPersistentStores { _, error in
        localError = error
      }

      if let localError {
        let localNSError = localError as NSError
        startupError = "Knowledge Base could not be opened: \(localNSError.localizedDescription)"
        NSLog(
          "ABSDEV Knowledge Base local fallback failed: %@ (%@)",
          localNSError.localizedDescription,
          localNSError.userInfo.description
        )
      } else {
        startupError = "iCloud sync is unavailable. Documents are open locally."
      }
      container = local
    } else {
      container = primary
      cloudSyncEnabled = !memory
    }

    container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    container.viewContext.automaticallyMergesChangesFromParent = true
    container.viewContext.transactionAuthor = "ABSDEVStudio"
  }

  private static func storeDescription(
    memory: Bool,
    url: URL,
    cloudKitEnabled: Bool
  ) -> NSPersistentStoreDescription {
    let description = NSPersistentStoreDescription()
    description.type = memory ? NSInMemoryStoreType : NSSQLiteStoreType
    description.shouldAddStoreAsynchronously = false
    description.shouldMigrateStoreAutomatically = true
    description.shouldInferMappingModelAutomatically = true

    if !memory {
      description.url = url
      description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
      description.setOption(
        true as NSNumber,
        forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey
      )
      if cloudKitEnabled {
        description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
          containerIdentifier: "iCloud.com.absdev.studio"
        )
      }
    }

    return description
  }
  static var support: URL {
    let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ABSDEVStudio")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
  }
  static var attachments: URL {
    let u = support.appendingPathComponent("KnowledgeBaseAttachments")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
  }
  private static func model() -> NSManagedObjectModel {
    func a(_ n: String, _ t: NSAttributeType, _ optional: Bool = false, _ def: Any? = nil)
      -> NSAttributeDescription
    {
      let x = NSAttributeDescription()
      x.name = n
      x.attributeType = t
      x.isOptional = optional
      x.defaultValue = def
      return x
    }
    let m = NSManagedObjectModel()
    let d = NSEntityDescription()
    let f = NSEntityDescription()
    d.name = "KBDocument"
    d.managedObjectClassName = NSStringFromClass(KBDocument.self)
    f.name = "KBAttachment"
    f.managedObjectClassName = NSStringFromClass(KBAttachment.self)
    d.properties = [
      a("id", .UUIDAttributeType, false, UUID()), a("projectID", .UUIDAttributeType, false, UUID()),
      a("title", .stringAttributeType, false, "Untitled Document"),
      a("text", .stringAttributeType, false, ""), a("priority", .integer16AttributeType, false, 2),
      a("order", .integer32AttributeType, false, 0),
      a("createdAt", .dateAttributeType, false, Date()),
      a("updatedAt", .dateAttributeType, false, Date()),
      a("richTextData", .binaryDataAttributeType, true),
      a("tags", .stringAttributeType, false, ""),
      a("isFavorite", .booleanAttributeType, false, false),
      a("isTrashed", .booleanAttributeType, false, false),
      a("deletedAt", .dateAttributeType, true),
      a("version", .integer32AttributeType, false, 1),
    ]
    f.properties = [
      a("id", .UUIDAttributeType, false, UUID()),
      a("name", .stringAttributeType, false, "Attachment"),
      a("relativePath", .stringAttributeType, false, ""),
      a("size", .integer64AttributeType, false, 0),
      a("checksum", .stringAttributeType, false, ""),
      a("createdAt", .dateAttributeType, false, Date()),
      a("data", .binaryDataAttributeType, true),
    ]
    if let richText = d.properties.first(where: { $0.name == "richTextData" }) as? NSAttributeDescription {
      richText.allowsExternalBinaryDataStorage = true
    }
    if let attachmentData = f.properties.first(where: { $0.name == "data" }) as? NSAttributeDescription {
      attachmentData.allowsExternalBinaryDataStorage = true
    }
    let ds = NSRelationshipDescription()
    let fd = NSRelationshipDescription()
    ds.name = "attachments"
    ds.destinationEntity = f
    ds.maxCount = 0
    ds.deleteRule = .cascadeDeleteRule
    fd.name = "document"
    fd.destinationEntity = d
    fd.minCount = 0
    fd.maxCount = 1
    fd.deleteRule = .nullifyDeleteRule
    ds.inverseRelationship = fd
    fd.inverseRelationship = ds
    d.properties.append(ds)
    f.properties.append(fd)
    m.entities = [d, f]
    return m
  }
}

struct KBTransferAttachment: Codable {
  let id: UUID, name: String, relativePath: String
  let size: Int64
  let checksum: String
  let createdAt: Date
}
struct KBTransferDocument: Codable {
  let id: UUID, title: String, text: String
  let priority: Int16, order: Int32
  let createdAt, updatedAt: Date
  let attachments: [KBTransferAttachment]
}
struct KBManifest: Codable {
  let version: Int
  let sourceProjectID: UUID
  let exportedAt: Date
  let documents: [KBTransferDocument]
}

@MainActor @Observable final class KBStore {
  let projectID: UUID
  private let context: NSManagedObjectContext
  var documents: [KBDocument] = []
  var selection: UUID?
  var search = ""
  var filter: KBPriority?
  var sort = KBSort.custom
  var status = "Ready"
  var error: String?
  var copied: UUID?
  var cut = false
  var showingTrash = false
  private var saver: Task<Void, Never>?
  static func purge(projectID: UUID, persistence: KBPersistence = .shared) throws {
    let context = persistence.container.viewContext
    let request = NSFetchRequest<NSFetchRequestResult>(entityName: "KBDocument")
    request.predicate = NSPredicate(format: "projectID == %@", projectID as CVarArg)
    try context.execute(NSBatchDeleteRequest(fetchRequest: request))
    try context.save()
    let attachments = KBPersistence.attachments.appendingPathComponent(projectID.uuidString)
    if FileManager.default.fileExists(atPath: attachments.path) {
      try FileManager.default.removeItem(at: attachments)
    }
  }

  init(projectID: UUID, persistence: KBPersistence = .shared) {
    self.projectID = projectID
    context = persistence.container.viewContext
    reload()
  }
  var selected: KBDocument? { documents.first { $0.id == selection } }
  var canDeleteSelected: Bool {
    guard let document = selected else { return false }
    return status == "Saved" && !document.isInserted && !document.isDeleted && !document.hasChanges
  }
  var visible: [KBDocument] {
    var r = documents.filter {
      $0.isTrashed == showingTrash
        && (filter == nil || $0.priority == filter!.rawValue)
        && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
          || $0.text.localizedCaseInsensitiveContains(search)
          || $0.attachments.contains {
            $0.name.localizedCaseInsensitiveContains(search)
              || searchableAttachmentText($0).localizedCaseInsensitiveContains(search)
          })
    }
    switch sort {
    case .custom: r.sort { $0.order < $1.order }
    case .priority: r.sort { ($0.priority, $0.order) < ($1.priority, $1.order) }
    case .updated: r.sort { $0.updatedAt > $1.updatedAt }
    case .title: r.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
    return r
  }

  private func searchableAttachmentText(_ attachment: KBAttachment) -> String {
    let fileURL = attachmentURL(attachment)
    let supported = ["txt", "md", "markdown", "json", "xml", "yaml", "yml", "csv", "log", "php", "swift", "js", "ts", "css", "html", "env"]
    guard supported.contains(fileURL.pathExtension.lowercased()),
      let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
      (values.fileSize ?? 0) <= 1_000_000,
      let data = try? Data(contentsOf: fileURL),
      let value = String(data: data, encoding: .utf8)
    else { return "" }
    return value
  }

  func reload() {
    let currentSelection = selection
    let r = NSFetchRequest<KBDocument>(entityName: "KBDocument")
    r.predicate = NSPredicate(format: "projectID == %@", projectID as CVarArg)
    r.sortDescriptors = [NSSortDescriptor(key: "order", ascending: true)]
    do {
      documents = try context.fetch(r)
      selection = currentSelection.flatMap { selectedID in
        documents.contains(where: { $0.id == selectedID }) ? selectedID : nil
      }
    } catch { self.error = error.localizedDescription }
  }
  func create() {
    let documentID = UUID()
    let defaultTitle = "Untitled Document"
    let d = KBDocument(context: context)
    d.id = documentID
    d.projectID = projectID
    d.title = defaultTitle
    d.text = ""
    d.priority = KBPriority.normal.rawValue
    d.order = (documents.map(\.order).max() ?? -1) + 1
    d.createdAt = Date()
    d.updatedAt = Date()
    d.tags = ""
    d.isFavorite = false
    d.isTrashed = false
    d.version = 1
    save()
    reload()

    // Select the newly persisted document and guarantee its visible title is never blank.
    if let created = documents.first(where: { $0.id == documentID }),
       created.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      created.title = defaultTitle
      save()
    }
    selection = documentID
  }
  func update(title: String? = nil, text: String? = nil, priority: KBPriority? = nil) {
    guard let d = selected else { return }
    if let title { d.title = title }
    if let text { d.text = text }
    if let priority { d.priority = priority.rawValue }
    d.updatedAt = Date()
    saver?.cancel()
    status = "Saving…"
    saver = Task {
      try? await Task.sleep(for: .milliseconds(450))
      guard !Task.isCancelled else { return }
      save()
      status = "Saved"
    }
  }
  func delete(documentID: UUID) {
    saver?.cancel()
    saver = nil
    guard let document = documents.first(where: { $0.id == documentID }), !document.isDeleted else { return }
    selection = nil
    document.isTrashed = true
    document.deletedAt = Date()
    document.updatedAt = Date()
    save()
    status = "Moved to Trash"
    reload()
    KBSpotlightIndexer.shared.remove(documentID: documentID)
  }

  func restore(documentID: UUID) {
    saver?.cancel()
    saver = nil
    selection = nil
    status = "Restoring…"

    // Context-menu and Menu content is hosted by a remote AppKit view. Yield one
    // run-loop turn so that view can dismiss before changing the fetched objects
    // which backed it. Capturing only the UUID also avoids retaining a managed
    // object across the asynchronous boundary.
    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self else { return }

      let request = NSFetchRequest<KBDocument>(entityName: "KBDocument")
      request.fetchLimit = 1
      request.predicate = NSPredicate(
        format: "projectID == %@ AND id == %@",
        self.projectID as CVarArg,
        documentID as CVarArg
      )

      do {
        guard let document = try self.context.fetch(request).first else {
          self.reload()
          self.status = "Ready"
          return
        }
        document.isTrashed = false
        document.deletedAt = nil
        document.updatedAt = Date()
        try self.context.save()

        let spotlight = KBSpotlightDocument(
          id: document.id,
          title: document.title,
          text: document.text,
          tags: document.tags
        )
        self.showingTrash = false
        self.reload()
        self.selection = documentID
        self.status = "Restored"
        KBSpotlightIndexer.shared.index(spotlight)
      } catch {
        self.context.rollback()
        self.reload()
        self.status = "Ready"
        self.error = error.localizedDescription
      }
    }
  }

  func permanentlyDelete(documentID: UUID) {
    saver?.cancel()
    saver = nil
    selection = nil
    status = "Deleting…"

    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self else { return }

      let request = NSFetchRequest<KBDocument>(entityName: "KBDocument")
      request.fetchLimit = 1
      request.predicate = NSPredicate(
        format: "projectID == %@ AND id == %@ AND isTrashed == YES",
        self.projectID as CVarArg,
        documentID as CVarArg
      )

      do {
        guard let document = try self.context.fetch(request).first else {
          self.reload()
          self.status = "Ready"
          return
        }
        let folderURL = self.folder(documentID)

        // Clear the observable list before invalidating any managed objects.
        self.documents = []
        await Task.yield()

        self.context.delete(document)
        try self.context.save()
        self.context.reset()
        self.reload()
        self.status = "Deleted permanently"

        try? FileManager.default.removeItem(at: folderURL)
        KBSpotlightIndexer.shared.remove(documentID: documentID)
      } catch {
        self.context.rollback()
        self.context.reset()
        self.reload()
        self.status = "Ready"
        self.error = error.localizedDescription
      }
    }
  }

  func emptyTrash() {
    saver?.cancel()
    saver = nil
    selection = nil
    status = "Emptying Trash…"

    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self else { return }

      let request = NSFetchRequest<KBDocument>(entityName: "KBDocument")
      request.predicate = NSPredicate(
        format: "projectID == %@ AND isTrashed == YES",
        self.projectID as CVarArg
      )

      do {
        let trashed = try self.context.fetch(request)
        guard !trashed.isEmpty else {
          self.reload()
          self.status = "Trash is empty"
          return
        }

        // Copy plain values before deleting; never retain deleted managed objects.
        let deletedIDs = trashed.map(\.id)
        let folderURLs = deletedIDs.map(self.folder)

        self.documents = []
        await Task.yield()

        trashed.forEach(self.context.delete)
        try self.context.save()
        self.context.reset()
        self.reload()
        self.status = "Trash emptied"

        folderURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        KBSpotlightIndexer.shared.remove(documentIDs: deletedIDs)
      } catch {
        self.context.rollback()
        self.context.reset()
        self.reload()
        self.status = "Ready"
        self.error = error.localizedDescription
      }
    }
  }

  func updateMetadata(tags: String? = nil, favorite: Bool? = nil) {
    guard let d = selected else { return }
    if let tags { d.tags = tags }
    if let favorite { d.isFavorite = favorite }
    d.updatedAt = Date()
    saveNow()
  }

  func createVersionSnapshot() {
    guard let d = selected else { return }
    KBVersionStore.shared.save(document: d)
    d.version += 1
    save()
  }

  func copy() {
    copied = selection
    cut = false
  }
  func cutDoc() {
    copied = selection
    cut = true
  }
  func paste() {
    guard let id = copied, let source = documents.first(where: { $0.id == id }) else { return }
    if cut {
      copied = nil
      cut = false
      return
    }
    duplicate(source)
  }
  func duplicateSelected() { if let d = selected { duplicate(d) } }
  private func duplicate(_ source: KBDocument) {
    let d = KBDocument(context: context)
    d.id = UUID()
    d.projectID = projectID
    d.title = source.title + " Copy"
    d.text = source.text
    d.priority = source.priority
    d.order = (documents.map(\.order).max() ?? -1) + 1
    d.createdAt = Date()
    d.updatedAt = Date()
    d.tags = source.tags
    d.isFavorite = source.isFavorite
    d.isTrashed = false
    d.version = 1
    for a in source.attachments { try? clone(a, to: d) }
    let sourceArchive = richTextArchiveURL(for: source.id)
    let destinationArchive = richTextArchiveURL(for: d.id)
    if FileManager.default.fileExists(atPath: sourceArchive.path) {
      try? FileManager.default.copyItem(at: sourceArchive, to: destinationArchive)
    }
    save()
    reload()
    selection = d.id
  }
  func move(up: Bool) {
    guard sort == .custom, let d = selected, let i = visible.firstIndex(of: d) else { return }
    let j = up ? i - 1 : i + 1
    guard visible.indices.contains(j) else { return }
    let other = visible[j]
    let o = d.order
    d.order = other.order
    other.order = o
    save()
    reload()
  }
  @discardableResult
  func addFiles() -> [KBAttachment] {
    guard let d = selected else { return [] }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK else { return [] }
    var added: [KBAttachment] = []
    for url in panel.urls {
      if let attachment = try? add(url, to: d) { added.append(attachment) }
    }
    save()
    reload()
    return added
  }
  func drop(_ urls: [URL]) {
    guard let d = selected else { return }
    for u in urls where !u.hasDirectoryPath { _ = try? add(u, to: d) }
    save()
    reload()
  }
  func open(_ a: KBAttachment) { NSWorkspace.shared.open(url(a)) }
  func reveal(_ a: KBAttachment) { NSWorkspace.shared.activateFileViewerSelecting([url(a)]) }
  func download(_ a: KBAttachment) {
    let source = url(a)
    guard FileManager.default.fileExists(atPath: source.path) else {
      error = "The attachment file could not be found."
      return
    }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = a.name
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    do {
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.copyItem(at: source, to: destination)
      status = "Attachment saved"
    } catch {
      self.error = error.localizedDescription
    }
  }
  func remove(_ a: KBAttachment) {
    try? FileManager.default.removeItem(at: url(a))
    context.delete(a)
    save()
    reload()
  }
  private func folder(_ id: UUID) -> URL {
    KBPersistence.attachments.appendingPathComponent(projectID.uuidString).appendingPathComponent(
      id.uuidString)
  }
  func attachmentURL(_ attachment: KBAttachment) -> URL {
    let localURL = KBPersistence.attachments.appendingPathComponent(attachment.relativePath)
    if !FileManager.default.fileExists(atPath: localURL.path), let data = attachment.data {
      try? FileManager.default.createDirectory(
        at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true
      )
      try? data.write(to: localURL, options: .atomic)
    }
    return localURL
  }
  func richTextArchiveURL(for documentID: UUID) -> URL {
    let directory = folder(documentID)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("document-rich-text.archive")
  }
  private func url(_ a: KBAttachment) -> URL { attachmentURL(a) }
  private func add(_ source: URL, to d: KBDocument) throws -> KBAttachment {
    let access = source.startAccessingSecurityScopedResource()
    defer { if access { source.stopAccessingSecurityScopedResource() } }
    let dir = folder(d.id)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let stored = UUID().uuidString + "." + source.pathExtension
    let target = dir.appendingPathComponent(stored)
    try FileManager.default.copyItem(at: source, to: target)
    let a = KBAttachment(context: context)
    a.id = UUID()
    a.name = source.lastPathComponent
    a.relativePath = "\(projectID.uuidString)/\(d.id.uuidString)/\(stored)"
    a.size = Int64((try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    a.data = try Data(contentsOf: target)
    a.checksum = SHA256.hash(data: a.data ?? Data()).map { String(format: "%02x", $0) }
      .joined()
    a.createdAt = Date()
    a.document = d
    d.updatedAt = Date()
    return a
  }
  private func clone(_ a: KBAttachment, to d: KBDocument) throws {
    let dir = folder(d.id)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let name = URL(fileURLWithPath: a.relativePath).lastPathComponent
    let target = dir.appendingPathComponent(name)
    try FileManager.default.copyItem(at: url(a), to: target)
    let n = KBAttachment(context: context)
    n.id = UUID()
    n.name = a.name
    n.relativePath = "\(projectID.uuidString)/\(d.id.uuidString)/\(name)"
    n.size = a.size
    n.data = a.data ?? (try? Data(contentsOf: url(a)))
    n.checksum = a.checksum
    n.createdAt = Date()
    n.document = d
  }
  func exportArchive() {
    let p = NSSavePanel()
    p.allowedContentTypes = [.zip]
    p.nameFieldStringValue = "ABSDEV-Knowledge-\(projectID.uuidString.prefix(8)).zip"
    guard p.runModal() == .OK, let out = p.url else { return }
    do {
      try export(to: out)
      status = "Exported"
    } catch { self.error = error.localizedDescription }
  }
  func importArchive() {
    let p = NSOpenPanel()
    p.allowedContentTypes = [.zip]
    guard p.runModal() == .OK, let u = p.url else { return }
    let a = NSAlert()
    a.messageText = "Import Knowledge Base"
    a.informativeText = "Merge with existing documents or replace them?"
    a.addButton(withTitle: "Merge")
    a.addButton(withTitle: "Replace")
    a.addButton(withTitle: "Cancel")
    let r = a.runModal()
    guard r != .alertThirdButtonReturn else { return }
    do {
      try importFrom(u, replace: r == .alertSecondButtonReturn)
      reload()
      status = "Imported"
    } catch { self.error = error.localizedDescription }
  }
  private func export(to out: URL) throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    let docs = documents.map { d in
      KBTransferDocument(
        id: d.id, title: d.title, text: d.text, priority: d.priority, order: d.order,
        createdAt: d.createdAt, updatedAt: d.updatedAt,
        attachments: d.attachments.map {
          KBTransferAttachment(
            id: $0.id, name: $0.name, relativePath: $0.relativePath, size: $0.size,
            checksum: $0.checksum, createdAt: $0.createdAt)
        })
    }
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    try e.encode(
      KBManifest(version: 1, sourceProjectID: projectID, exportedAt: Date(), documents: docs)
    ).write(to: temp.appendingPathComponent("manifest.json"))
    let src = KBPersistence.attachments.appendingPathComponent(projectID.uuidString)
    if FileManager.default.fileExists(atPath: src.path) {
      try FileManager.default.copyItem(at: src, to: temp.appendingPathComponent("attachments"))
    }
    try? FileManager.default.removeItem(at: out)
    try runDitto(["-c", "-k", "--sequesterRsrc", temp.path, out.path])
    try? FileManager.default.removeItem(at: temp)
  }
  private func importFrom(_ archive: URL, replace: Bool) throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    try runDitto(["-x", "-k", archive.path, temp.path])
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    let m = try d.decode(
      KBManifest.self, from: Data(contentsOf: temp.appendingPathComponent("manifest.json")))
    if replace {
      for x in documents { context.delete(x) }
      try? FileManager.default.removeItem(
        at: KBPersistence.attachments.appendingPathComponent(projectID.uuidString))
    }
    for x in m.documents {
      let current = documents.first { $0.id == x.id }
      if let current, current.updatedAt >= x.updatedAt { continue }
      let item = current ?? KBDocument(context: context)
      item.id = x.id
      item.projectID = projectID
      item.title = x.title
      item.text = x.text
      item.priority = x.priority
      item.order = x.order
      item.createdAt = x.createdAt
      item.updatedAt = x.updatedAt
      for old in item.attachments { context.delete(old) }
      for f in x.attachments {
        let source = temp.appendingPathComponent("attachments").appendingPathComponent(
          x.id.uuidString
        ).appendingPathComponent(URL(fileURLWithPath: f.relativePath).lastPathComponent)
        let dir = folder(x.id)
        let target = dir.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: source.path) {
          try? FileManager.default.removeItem(at: target)
          try FileManager.default.copyItem(at: source, to: target)
        }
        let a = KBAttachment(context: context)
        a.id = f.id
        a.name = f.name
        a.relativePath = "\(projectID.uuidString)/\(x.id.uuidString)/\(target.lastPathComponent)"
        a.size = f.size
        a.data = FileManager.default.fileExists(atPath: target.path) ? try? Data(contentsOf: target) : nil
        a.checksum = f.checksum
        a.createdAt = f.createdAt
        a.document = item
      }
    }
    save()
    try? FileManager.default.removeItem(at: temp)
  }
  private func runDitto(_ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    p.arguments = args
    try p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 { throw CocoaError(.fileWriteUnknown) }
  }
  func saveNow() {
    saver?.cancel()
    guard let d = selected else { return }
    d.updatedAt = Date()
    createVersionSnapshot()
    save()
    status = "Saved"
    KBSpotlightIndexer.shared.index(d)
  }
  private func save() {
    do { if context.hasChanges { try context.save() } } catch {
      self.error = error.localizedDescription
    }
  }
}

struct KnowledgeBaseView: View {
  @Environment(AppStore.self) private var app
  @State private var store: KBStore?
  @State private var pendingDeleteID: UUID?
  var body: some View {
    Group {
      if let id = app.selectedProjectID, let store {
        KBWorkspace(store: store, pendingDeleteID: $pendingDeleteID).id(id)
      } else {
        ContentUnavailableView(
          "Select a Project", systemImage: "books.vertical",
          description: Text("Knowledge Base documents are project-specific."))
      }
    }.navigationTitle("Knowledge Base").task(id: app.selectedProjectID) {
      store = app.selectedProjectID.map { KBStore(projectID: $0) }
    }
  }
}
private struct KBWorkspace: View {
  @Bindable var store: KBStore
  @Binding var pendingDeleteID: UUID?
  @FocusState private var titleFocused: Bool
  @FocusState private var searchFocused: Bool
  @State private var inlineInsertion: KBInlineInsertion?
  @State private var formatCommand: KBFormatCommand?
  @State private var selectedFontFamily = "System"
  @State private var selectedFontSize: Double = 14
  @State private var selectedTextColor = Color.white
  @State private var selectedHighlightColor = Color.clear
  @State private var inspectorVisible = false
  @State private var commandPaletteVisible = false
  @State private var paletteSearch = ""

  var body: some View {
    VStack(spacing: 0) {
      commandBar
      Divider()
      HSplitView {
        documentNavigator
          .frame(
            minWidth: 200,
            idealWidth: 220,
            maxWidth: 300,
            maxHeight: .infinity,
            alignment: .top
          )

        documentEditor
          .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      }
    }
    .sheet(isPresented: $commandPaletteVisible) {
      KBCommandPalette(store: store, search: $paletteSearch, isPresented: $commandPaletteVisible)
    }
    .onKeyPress(.init("p"), phases: .down) { press in
      guard press.modifiers.contains([.command, .shift]) else { return .ignored }
      commandPaletteVisible = true
      return .handled
    }
    .alert(
      "Delete Document?",
      isPresented: Binding(
        get: { pendingDeleteID != nil },
        set: { if !$0 { pendingDeleteID = nil } }
      )
    ) {
      Button("Delete", role: .destructive) {
        guard let documentID = pendingDeleteID else { return }
        pendingDeleteID = nil
        store.delete(documentID: documentID)
      }
      Button("Cancel", role: .cancel) { pendingDeleteID = nil }
    } message: {
      Text("The document and all of its attachments will be permanently deleted.")
    }
    .alert(
      "Knowledge Base Error",
      isPresented: Binding(
        get: { store.error != nil },
        set: { if !$0 { store.error = nil } }
      )
    ) {
      Button("OK") {}
    } message: {
      Text(store.error ?? "Unknown error")
    }
  }

  private var commandBar: some View {
    HStack(spacing: 8) {
      Button {
        store.create()
        titleFocused = true
      } label: {
        Label("Create Document", systemImage: "doc.badge.plus")
      }
      .buttonStyle(.borderedProminent)
      .keyboardShortcut("n", modifiers: .command)

      Button {
        store.duplicateSelected()
      } label: {
        Label("Duplicate", systemImage: "plus.square.on.square")
      }
      .keyboardShortcut("d", modifiers: .command)
      .disabled(store.selected == nil)

      Button {
        store.cutDoc()
      } label: {
        Label("Cut", systemImage: "scissors")
      }
      .keyboardShortcut("x", modifiers: .command)
      .disabled(store.selected == nil)

      Button {
        store.copy()
      } label: {
        Label("Copy", systemImage: "doc.on.doc")
      }
      .keyboardShortcut("c", modifiers: .command)
      .disabled(store.selected == nil)

      Button {
        store.paste()
      } label: {
        Label("Paste", systemImage: "doc.on.clipboard")
      }
      .keyboardShortcut("v", modifiers: .command)
      .disabled(store.copied == nil)

      Button { commandPaletteVisible = true } label: {
        Label("Find Document", systemImage: "command")
      }
      .keyboardShortcut("p", modifiers: [.command, .shift])


      Spacer(minLength: 12)

      Menu {
        Button("Move Up") { store.move(up: true) }
        Button("Move Down") { store.move(up: false) }
        Divider()
        Button("Import…") { store.importArchive() }
        Button("Export…") { store.exportArchive() }
          .disabled(store.documents.isEmpty)
        Divider()
        Button(store.showingTrash ? "Show Documents" : "Show Trash") {
          store.selection = nil
          store.showingTrash.toggle()
        }
        if store.showingTrash {
          Button("Empty Trash", role: .destructive) { store.emptyTrash() }
            .disabled(store.visible.isEmpty)
        }
      } label: {
        Label("More", systemImage: "ellipsis.circle")
      }

      statusPill
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.bar)
  }

  private var statusPill: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(store.status == "Saved" ? Color.green : Color.orange)
        .frame(width: 7, height: 7)
      Text(store.status)
        .font(.caption.weight(.medium))
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .background(.quaternary.opacity(0.55), in: Capsule())
  }

  private var documentNavigator: some View {
    VStack(spacing: 0) {
      VStack(spacing: 10) {
        HStack(spacing: 8) {
          TextField("Search documents", text: $store.search)
            .textFieldStyle(.roundedBorder)
            .focused($searchFocused)

          Button {
            store.create()
            titleFocused = true
          } label: {
            Image(systemName: "plus")
          }
          .buttonStyle(.borderedProminent)
          .help("Create Document")
        }

        HStack(spacing: 8) {
          Menu {
            Button("All Priorities") { store.filter = nil }
            Divider()
            ForEach(KBPriority.allCases) { priority in
              Button {
                store.filter = priority
              } label: {
                Label(priority.name, systemImage: priority.icon)
              }
            }
          } label: {
            Label(
              store.filter?.name ?? "All Priorities",
              systemImage: "line.3.horizontal.decrease.circle")
          }

          Picker("Sort", selection: $store.sort) {
            ForEach(KBSort.allCases) { sort in
              Text(sort.rawValue).tag(sort)
            }
          }
          .labelsHidden()
          .pickerStyle(.menu)

          Spacer()

          Text("\(store.visible.count)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      .padding(12)
      .background(.bar)

      Divider()

      if store.visible.isEmpty {
        ContentUnavailableView {
          Label(store.showingTrash ? "Trash is Empty" : "No Documents", systemImage: store.showingTrash ? "trash" : "doc.text")
        } description: {
          Text(store.showingTrash ? "Deleted documents appear here until permanently removed." : "Create notes, guides and project documentation from the toolbar.")
        }
      } else {
        List(store.visible) { document in
          documentRow(document)
            .contentShape(Rectangle())
            .listRowBackground(
              store.selection == document.id
                ? Color.accentColor.opacity(0.22)
                : Color.clear
            )
            .onTapGesture {
              store.selection = store.selection == document.id ? nil : document.id
            }
            .contextMenu {
              Button("Open") { store.selection = document.id }
              Button("Duplicate") {
                store.selection = document.id
                store.duplicateSelected()
              }
              Divider()
              Button("Cut") {
                store.selection = document.id
                store.cutDoc()
              }
              Button("Copy") {
                store.selection = document.id
                store.copy()
              }
              Button("Paste") { store.paste() }
                .disabled(store.copied == nil)
              Divider()
              Button("Move Up") {
                store.selection = document.id
                store.move(up: true)
              }
              Button("Move Down") {
                store.selection = document.id
                store.move(up: false)
              }
              Divider()
              if store.showingTrash {
                Button("Restore") { store.restore(documentID: document.id) }
                Button("Delete Permanently", role: .destructive) {
                  store.permanentlyDelete(documentID: document.id)
                }
              } else {
                Button("Move to Trash", role: .destructive) {
                  store.selection = document.id
                  pendingDeleteID = document.id
                }
                .disabled(document.isInserted || document.isDeleted || document.hasChanges)
              }
            }
        }
        .listStyle(.sidebar)
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
  }

  private func documentRow(_ document: KBDocument) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 7) {
        Circle()
          .fill(KBPriority(rawValue: document.priority)?.colour ?? .secondary)
          .frame(width: 8, height: 8)

        Text(document.title)
          .font(.body.weight(.semibold))
          .lineLimit(1)

        Spacer(minLength: 6)

        if document.isFavorite {
          Image(systemName: "star.fill").foregroundStyle(.yellow)
        }
        if !document.attachments.isEmpty {
          Label("\(document.attachments.count)", systemImage: "paperclip")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }

      Text(documentBodyPreview(document.text))
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)

      HStack {
        Text(KBPriority(rawValue: document.priority)?.name ?? "Normal")
        Spacer()
        Text(document.updatedAt, format: .relative(presentation: .named))
      }
      .font(.caption2)
      .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 6)
  }


  private func documentBodyPreview(_ text: String) -> String {
    let withoutAttachmentTokens = text.replacingOccurrences(
      of: #"\[\[attachment:[0-9A-Fa-f-]+\]\]"#,
      with: "",
      options: .regularExpression
    )
    let collapsed = withoutAttachmentTokens
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !collapsed.isEmpty else { return "No content" }
    let preview = String(collapsed.prefix(30))
    return collapsed.count > 30 ? preview + "…" : preview
  }

  @ViewBuilder private var documentEditor: some View {
    if let document = store.selected {
      HStack(spacing: 0) {
      VStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 12) {
          HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
              Text("DOCUMENT")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
              Text("Created \(document.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
              store.updateMetadata(favorite: !document.isFavorite)
            } label: {
              Image(systemName: document.isFavorite ? "star.fill" : "star")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(document.isFavorite ? .yellow : .secondary)
            .help(document.isFavorite ? "Remove from Favorites" : "Add to Favorites")

              let selectedPriority = KBPriority(rawValue: document.priority) ?? .normal

              Menu {
                ForEach(KBPriority.allCases) { priority in
                  Button {
                    store.update(priority: priority)
                  } label: {
                    Label(priority.name, systemImage: priority.icon)
                  }
                }
              } label: {
                HStack(spacing: 7) {
                  Image(systemName: selectedPriority.icon)
                    .foregroundStyle(.white)

                  Text(selectedPriority.name)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)

                  Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background {
                  Capsule()
                    .fill(selectedPriority.colour)
                }
                .overlay {
                  Capsule()
                    .stroke(.white.opacity(0.22), lineWidth: 1)
                }
                .shadow(
                  color: selectedPriority.colour.opacity(0.30),
                  radius: 3,
                  y: 1
                )
                .contentShape(Capsule())
              }
              .menuStyle(.borderlessButton)
              .fixedSize(horizontal: true, vertical: false)
              .help("Document priority")


            Button {
              store.saveNow()
            } label: {
              Label("Save", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
            .fixedSize(horizontal: true, vertical: false)

            Button(role: .destructive) {
              pendingDeleteID = document.id
            } label: {
              Label("Move to Trash", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.delete, modifiers: .command)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(!store.canDeleteSelected)
            .help(
              store.canDeleteSelected
                ? "Delete this saved document" : "Save the document before deleting it")


            Button {
              inspectorVisible.toggle()
            } label: {
              Label(
                inspectorVisible ? "Hide Inspector" : "Show Inspector",
                systemImage: "sidebar.right"
              )
            }
            .buttonStyle(.borderedProminent)
            .fixedSize(horizontal: true, vertical: false)
            .help(inspectorVisible ? "Hide Inspector" : "Show Inspector")
          }

          TextField(
            "Document title",
            text: Binding(
              get: { document.title },
              set: { store.update(title: $0) }
            )
          )
          .focused($titleFocused)
          .font(.system(size: 24, weight: .semibold))
          .textFieldStyle(.plain)
          .padding(.vertical, 8)
          .padding(.horizontal, 10)
          .background(.background, in: RoundedRectangle(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
        }
        .padding(16)
        .background(.bar)

        Divider()

        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Label("Content", systemImage: "text.alignleft")
              .font(.headline)
            Spacer()
            Text("\(document.text.count) characters")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          VStack(spacing: 8) {
            HStack(spacing: 8) {
              Button("Insert File…", systemImage: "paperclip") {
                let files = store.addFiles()
                if !files.isEmpty { inlineInsertion = KBInlineInsertion(attachments: files) }
              }
              .buttonStyle(.bordered)

              Divider().frame(height: 20)

              Menu {
                ForEach(["System", "Rounded", "Serif", "Monospaced"], id: \.self) { family in
                  Button {
                    selectedFontFamily = family
                    formatCommand = .fontFamily(family)
                  } label: {
                    if selectedFontFamily == family { Label(family, systemImage: "checkmark") }
                    else { Text(family) }
                  }
                }
              } label: {
                Label(selectedFontFamily, systemImage: "textformat")
                  .lineLimit(1)
                  .frame(minWidth: 108, alignment: .leading)
              }
              .buttonStyle(.bordered)
              .controlSize(.small)
              .help("Font")

              Menu {
                ForEach([10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32, 36, 48], id: \.self) { size in
                  Button("\(size) pt") {
                    selectedFontSize = Double(size)
                    formatCommand = .fontSize(CGFloat(size))
                  }
                }
              } label: {
                Text("\(Int(selectedFontSize)) pt")
                  .monospacedDigit()
                  .frame(minWidth: 50)
              }
              .buttonStyle(.bordered)
              .controlSize(.small)
              .help("Font size")

              ControlGroup {
                Button { formatCommand = .bold } label: { Image(systemName: "bold") }
                  .help("Bold")
                Button { formatCommand = .italic } label: { Image(systemName: "italic") }
                  .help("Italic")
                Button { formatCommand = .underline } label: { Image(systemName: "underline") }
                  .help("Underline")
              }
              .controlSize(.small)

              ControlGroup {
                Button { formatCommand = .bulletList } label: { Image(systemName: "list.bullet") }
                  .help("Bulleted List")
                Button { formatCommand = .numberedList } label: { Image(systemName: "list.number") }
                  .help("Numbered List")
              }
              .controlSize(.small)

              Menu {
                ForEach(KBTextPalette.allCases, id: \.self) { item in
                  Button {
                    selectedTextColor = item.color
                    formatCommand = .textColor(item.nsColor)
                  } label: { Label(item.title, systemImage: "circle.fill") }
                }
              } label: {
                HStack(spacing: 5) {
                  Image(systemName: "character.cursor.ibeam")
                  Circle().fill(selectedTextColor).frame(width: 10, height: 10)
                    .overlay(Circle().stroke(.secondary, lineWidth: 0.5))
                }
              }
              .buttonStyle(.bordered)
              .controlSize(.small)
              .help("Text colour")

              Menu {
                Button {
                  selectedHighlightColor = .clear
                  formatCommand = .highlightColor(.clear)
                } label: { Label("No Highlight", systemImage: "nosign") }
                Divider()
                ForEach(KBHighlightPalette.allCases, id: \.self) { item in
                  Button {
                    selectedHighlightColor = item.color
                    formatCommand = .highlightColor(item.nsColor)
                  } label: { Label(item.title, systemImage: "highlighter") }
                }
              } label: {
                HStack(spacing: 5) {
                  Image(systemName: "highlighter")
                  RoundedRectangle(cornerRadius: 2)
                    .fill(selectedHighlightColor == .clear ? Color.secondary.opacity(0.18) : selectedHighlightColor)
                    .frame(width: 14, height: 8)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(.secondary, lineWidth: 0.5))
                }
              }
              .buttonStyle(.bordered)
              .controlSize(.small)
              .help("Highlight colour")

              Menu {
                Button("Align Left") { formatCommand = .alignment(.left) }
                Button("Centre") { formatCommand = .alignment(.center) }
                Button("Align Right") { formatCommand = .alignment(.right) }
                Button("Justify") { formatCommand = .alignment(.justified) }
              } label: {
                Image(systemName: "text.alignleft")
              }
              .menuStyle(.borderlessButton)

              Spacer()

              if !document.attachments.isEmpty {
                Menu {
                  ForEach(Array(document.attachments).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { attachment in
                    Button {
                      store.download(attachment)
                    } label: {
                      Label(attachment.name, systemImage: "arrow.down.circle")
                    }
                  }
                } label: {
                  Label("Download Attachment", systemImage: "square.and.arrow.down")
                }
                .menuStyle(.borderlessButton)
              }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))

            KBInlineDocumentEditor(
              text: Binding(
                get: { document.text },
                set: { store.update(text: $0) }
              ),
              attachments: document.attachments,
              attachmentURL: store.attachmentURL,
              richTextData: Binding(
                get: { document.richTextData },
                set: { document.richTextData = $0; store.update() }
              ),
              insertion: $inlineInsertion,
              formatCommand: $formatCommand
            )
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      }
      .dropDestination(for: URL.self) { urls, _ in
        store.drop(urls)
        return true
      }
      if inspectorVisible {
        Divider()
        KBInspector(store: store, document: document)
          .frame(minWidth: 240, idealWidth: 280, maxWidth: 340, maxHeight: .infinity)
      }
      }
    } else {
      Color.clear
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }
  }
}

private enum KBTextPalette: String, CaseIterable {
  case white, lightGray, red, orange, yellow, green, cyan, blue, purple
  var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
  var color: Color {
    switch self {
    case .white: return .white
    case .lightGray: return .gray
    case .red: return .red
    case .orange: return .orange
    case .yellow: return .yellow
    case .green: return .green
    case .cyan: return .cyan
    case .blue: return .blue
    case .purple: return .purple
    }
  }
  var nsColor: NSColor { NSColor(color) }
}

private enum KBHighlightPalette: String, CaseIterable {
  case yellow, orange, green, cyan, blue, purple, red
  var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
  var color: Color {
    switch self {
    case .yellow: return .yellow.opacity(0.65)
    case .orange: return .orange.opacity(0.65)
    case .green: return .green.opacity(0.55)
    case .cyan: return .cyan.opacity(0.55)
    case .blue: return .blue.opacity(0.55)
    case .purple: return .purple.opacity(0.55)
    case .red: return .red.opacity(0.55)
    }
  }
  var nsColor: NSColor { NSColor(color) }
}

private enum KBFormatCommand {
  case fontFamily(String)
  case fontSize(CGFloat)
  case bold
  case italic
  case underline
  case textColor(NSColor)
  case highlightColor(NSColor)
  case alignment(NSTextAlignment)
  case bulletList
  case numberedList
}

private struct KBInlineInsertion: Equatable {
  let id = UUID()
  let attachments: [KBAttachment]
  static func == (lhs: KBInlineInsertion, rhs: KBInlineInsertion) -> Bool { lhs.id == rhs.id }
}

private struct KBInlineDocumentEditor: NSViewRepresentable {
  @Binding var text: String
  let attachments: Set<KBAttachment>
  let attachmentURL: (KBAttachment) -> URL
  @Binding var richTextData: Data?
  @Binding var insertion: KBInlineInsertion?
  @Binding var formatCommand: KBFormatCommand?

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    scroll.drawsBackground = true
    scroll.backgroundColor = .black

    let editor = NSTextView()
    editor.isRichText = true
    editor.allowsUndo = true
    editor.isAutomaticSpellingCorrectionEnabled = true
    editor.isAutomaticLinkDetectionEnabled = true
    editor.textContainerInset = NSSize(width: 12, height: 12)
    editor.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    editor.backgroundColor = .black
    editor.textColor = .white
    editor.insertionPointColor = .white
    editor.delegate = context.coordinator
    scroll.documentView = editor
    context.coordinator.editor = editor
    context.coordinator.loadInitialContent(fallback: text)
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let editor = context.coordinator.editor else { return }
    if context.coordinator.serialisedText() != text && !context.coordinator.isEditing {
      context.coordinator.render(text)
    }
    if let insertion, context.coordinator.lastInsertionID != insertion.id {
      context.coordinator.lastInsertionID = insertion.id
      context.coordinator.insert(insertion.attachments)
      DispatchQueue.main.async { self.insertion = nil }
    }
    if let formatCommand, !context.coordinator.isFormatCommandQueued {
      context.coordinator.isFormatCommandQueued = true
      let coordinator = context.coordinator

      // NSTextView formatting can invalidate AppKit layout. Running it synchronously
      // inside updateNSView causes a recursive constraints-update cycle on macOS.
      DispatchQueue.main.async {
        coordinator.apply(formatCommand)
        coordinator.isFormatCommandQueued = false
        self.formatCommand = nil
      }
    }
    editor.isEditable = true
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    private static let attachmentIDKey = NSAttributedString.Key("ABSDEVKnowledgeAttachmentID")
    var parent: KBInlineDocumentEditor
    weak var editor: NSTextView?
    var isEditing = false
    var lastInsertionID: UUID?
    var isFormatCommandQueued = false
    private var archiveSaveGeneration = UUID()

    init(_ parent: KBInlineDocumentEditor) { self.parent = parent }

    func textDidBeginEditing(_ notification: Notification) { isEditing = true }
    func textDidEndEditing(_ notification: Notification) { isEditing = false }
    func textDidChange(_ notification: Notification) {
      guard !isRendering, !isApplyingFormat else { return }
      parent.text = serialisedText()
      saveArchive()
    }

    private var isRendering = false
    private var isApplyingFormat = false

    func loadInitialContent(fallback: String) {
      guard let editor else { return }
      if let data = parent.richTextData,
        let archived = try? NSKeyedUnarchiver.unarchivedObject(
          ofClass: NSAttributedString.self,
          from: data
        ),
        !archived.string.contains("[[attachment:")
      {
        isRendering = true
        editor.textStorage?.setAttributedString(sanitisedArchive(archived))
        isRendering = false
      } else {
        let cleaned = sanitisedSource(fallback)
        render(cleaned)
        if cleaned != fallback {
          parent.text = cleaned
          saveArchive()
        }
      }
    }

    private func sanitisedSource(_ source: String) -> String {
      let validIDs = Set(parent.attachments.map { $0.id.uuidString.lowercased() })
      let pattern = #"\[\[attachment:([0-9A-Fa-f-]{36})\]\]"#
      guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
      let ns = source as NSString
      let result = NSMutableString(string: source)
      for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)).reversed() {
        let id = ns.substring(with: match.range(at: 1)).lowercased()
        if !validIDs.contains(id) { result.replaceCharacters(in: match.range, with: "") }
      }
      return (result as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitisedArchive(_ archived: NSAttributedString) -> NSAttributedString {
      let value = NSMutableAttributedString(attributedString: archived)
      let validIDs = Set(parent.attachments.map { $0.id.uuidString.lowercased() })
      value.enumerateAttribute(Self.attachmentIDKey, in: NSRange(location: 0, length: value.length), options: [.reverse]) { raw, range, _ in
        guard let id = (raw as? String)?.lowercased(), validIDs.contains(id) else {
          if raw != nil { value.deleteCharacters(in: range) }
          return
        }
      }
      value.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: value.length))
      return value
    }

    private func saveArchive() {
      guard let storage = editor?.textStorage else { return }

      let snapshot = NSAttributedString(attributedString: storage)
      guard let data = try? NSKeyedArchiver.archivedData(
        withRootObject: snapshot,
        requiringSecureCoding: false
      ) else {
        // Plain text remains safely stored if rich-text archiving fails.
        return
      }

      // Avoid publishing the same archive repeatedly. Reassigning identical data causes
      // SwiftUI to update this representable again and can create an AppKit layout loop.
      guard data != parent.richTextData else { return }

      let generation = UUID()
      archiveSaveGeneration = generation
      DispatchQueue.main.async { [weak self] in
        guard let self, self.archiveSaveGeneration == generation else { return }
        guard self.parent.richTextData != data else { return }
        self.parent.richTextData = data
      }
    }

    func apply(_ command: KBFormatCommand) {
      guard let editor, editor.textStorage != nil else { return }
      let selected = editor.selectedRange()
      let range = selected.length > 0 ? selected : NSRange(location: selected.location, length: 0)

      isApplyingFormat = true
      defer { isApplyingFormat = false }

      switch command {
      case .fontFamily(let family):
        applyFont(in: range) { current in
          self.safeFont(family: family, size: current.pointSize, traits: current.fontDescriptor.symbolicTraits)
        }
      case .fontSize(let size):
        applyFont(in: range) { current in
          self.safeFont(family: current.familyName ?? "System", size: max(8, min(size, 96)), traits: current.fontDescriptor.symbolicTraits)
        }
      case .bold:
        applyFont(in: range) { current in
          NSFontManager.shared.convert(current, toHaveTrait: .boldFontMask)
        }
      case .italic:
        applyFont(in: range) { current in
          NSFontManager.shared.convert(current, toHaveTrait: .italicFontMask)
        }
      case .underline:
        toggleAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, in: range)
      case .textColor(let colour):
        applyAttribute(.foregroundColor, value: colour, in: range)
      case .highlightColor(let colour):
        if colour.alphaComponent <= 0.01 {
          removeAttribute(.backgroundColor, in: range)
        } else {
          applyAttribute(.backgroundColor, value: colour, in: range)
        }
      case .alignment(let alignment):
        applyParagraphAlignment(alignment, in: range)
      case .bulletList:
          insertListPrefix("• ")
      case .numberedList:
          insertListPrefix("1. ")
      }
      // Formatting changes attributed text only. Do not rewrite the plain-text binding here:
      // doing so re-enters SwiftUI's update cycle while the command is still pending.
      saveArchive()
      editor.window?.makeFirstResponder(editor)
    }

    private func safeFont(family: String, size: CGFloat, traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
      let design: NSFontDescriptor.SystemDesign
      switch family {
      case "Rounded": design = .rounded
      case "Serif": design = .serif
      case "Monospaced": design = .monospaced
      default: design = .default
      }
      let base = NSFont.systemFont(ofSize: size).fontDescriptor
      let designed = base.withDesign(design) ?? base
      let descriptor = designed.withSymbolicTraits(traits)
      return NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size)
    }

    private func effectiveRange(_ range: NSRange) -> NSRange {
      guard let editor else { return range }
      if range.length > 0 { return range }
      editor.typingAttributes[.font] = editor.typingAttributes[.font]
        ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
      return range
    }

    private func insertListPrefix(_ prefix: String) {
      guard let editor else { return }
      let selection = editor.selectedRange()
      editor.insertText(prefix, replacementRange: NSRange(location: selection.location, length: 0))
      parent.text = serialisedText()
      saveArchive()
    }

    private func applyFont(in range: NSRange, transform: (NSFont) -> NSFont) {
      guard let editor, let storage = editor.textStorage else { return }
      if range.length == 0 {
        let current = editor.typingAttributes[.font] as? NSFont
          ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        editor.typingAttributes[.font] = transform(current)
        return
      }
      storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
        let current = value as? NSFont ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        storage.addAttribute(.font, value: transform(current), range: subrange)
      }
    }

    private func applyAttribute(_ key: NSAttributedString.Key, value: Any, in range: NSRange) {
      guard let editor, let storage = editor.textStorage else { return }
      if range.length == 0 {
        editor.typingAttributes[key] = value
      } else {
        storage.addAttribute(key, value: value, range: range)
      }
    }

    private func removeAttribute(_ key: NSAttributedString.Key, in range: NSRange) {
      guard let editor, let storage = editor.textStorage else { return }
      if range.length == 0 {
        editor.typingAttributes.removeValue(forKey: key)
      } else {
        storage.removeAttribute(key, range: range)
      }
    }

    private func toggleAttribute(_ key: NSAttributedString.Key, value: Any, in range: NSRange) {
      guard let editor, let storage = editor.textStorage else { return }
      if range.length == 0 {
        if editor.typingAttributes[key] != nil { editor.typingAttributes.removeValue(forKey: key) }
        else { editor.typingAttributes[key] = value }
        return
      }
      let current = storage.attribute(key, at: range.location, effectiveRange: nil)
      if current == nil { storage.addAttribute(key, value: value, range: range) }
      else { storage.removeAttribute(key, range: range) }
    }

    private func applyParagraphAlignment(_ alignment: NSTextAlignment, in range: NSRange) {
      guard let editor, let storage = editor.textStorage else { return }
      if range.length == 0 {
        let style = (editor.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy()
          as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.alignment = alignment
        editor.typingAttributes[.paragraphStyle] = style
        return
      }
      let paragraphRange = (storage.string as NSString).paragraphRange(for: range)
      storage.enumerateAttribute(.paragraphStyle, in: paragraphRange) { value, subrange, _ in
        let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
          ?? NSMutableParagraphStyle()
        style.alignment = alignment
        storage.addAttribute(.paragraphStyle, value: style, range: subrange)
      }
    }

    func render(_ source: String) {
      guard let editor else { return }
      isRendering = true
      let selected = editor.selectedRange()
      editor.textStorage?.setAttributedString(attributed(from: source))
      editor.setSelectedRange(NSRange(location: min(selected.location, editor.string.utf16.count), length: 0))
      isRendering = false
    }

    func insert(_ items: [KBAttachment]) {
      guard let editor, let storage = editor.textStorage else { return }
      let range = editor.selectedRange()
      let value = NSMutableAttributedString(string: "")
      for (index, attachment) in items.enumerated() {
        if index > 0 { value.append(NSAttributedString(string: "\n")) }
        value.append(renderedAttachment(attachment))
      }
      storage.replaceCharacters(in: range, with: value)
      editor.setSelectedRange(NSRange(location: range.location + value.length, length: 0))
      parent.text = serialisedText()
      saveArchive()
    }

    func serialisedText() -> String {
      guard let storage = editor?.textStorage else { return parent.text }
      let value = NSAttributedString(attributedString: storage)
      var output = ""
      var lastAttachmentID: String?
      value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attrs, range, _ in
        if let id = attrs[Self.attachmentIDKey] as? String {
          if lastAttachmentID != id {
            output += "[[attachment:\(id)]]"
            lastAttachmentID = id
          }
          return
        }
        lastAttachmentID = nil
        if let attachment = attrs[.attachment] as? NSTextAttachment,
          let name = attachment.fileWrapper?.preferredFilename,
          name.hasPrefix("absdev-kb-")
        {
          let id = name.replacingOccurrences(of: "absdev-kb-", with: "")
          output += "[[attachment:\(id)]]"
        } else {
          output += (value.string as NSString).substring(with: range)
        }
      }
      return output
    }

    private func attributed(from source: String) -> NSAttributedString {
      let result = NSMutableAttributedString(string: "")
      let pattern = #"\[\[attachment:([0-9A-Fa-f-]{36})\]\]"#
      let regex = try? NSRegularExpression(pattern: pattern)
      let ns = source as NSString
      var location = 0
      for match in regex?.matches(in: source, range: NSRange(location: 0, length: ns.length)) ?? [] {
        if match.range.location > location {
          result.append(base(ns.substring(with: NSRange(location: location, length: match.range.location - location))))
        }
        let idText = ns.substring(with: match.range(at: 1))
        if let id = UUID(uuidString: idText), let item = parent.attachments.first(where: { $0.id == id }) {
          result.append(renderedAttachment(item))
        }
        // Orphaned attachment references are intentionally omitted. This can happen when an
        // attachment is removed, imported without its binary, or an older document contains a
        // stale token. Raw storage markup must never be shown in the document editor.
        location = NSMaxRange(match.range)
      }
      if location < ns.length { result.append(base(ns.substring(from: location))) }
      return result
    }

    private func base(_ string: String) -> NSAttributedString {
      NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .regular),
        .foregroundColor: NSColor.white,
      ])
    }

    private func decodeText(_ data: Data) -> String? {
      if let value = String(data: data, encoding: .utf8) { return value }
      if let value = String(data: data, encoding: .utf16) { return value }
      if let value = String(data: data, encoding: .utf16LittleEndian) { return value }
      if let value = String(data: data, encoding: .utf16BigEndian) { return value }
      if let value = String(data: data, encoding: .isoLatin1) { return value }
      return nil
    }

    private func renderedAttachment(_ item: KBAttachment) -> NSAttributedString {
      let url = parent.attachmentURL(item)
      let identifier = item.id.uuidString
      let supportedTextExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "xml", "yaml", "yml", "csv", "log", "php",
        "swift", "js", "jsx", "ts", "tsx", "css", "scss", "html", "htm", "env", "sh",
        "bash", "zsh", "sql", "toml", "ini", "conf", "plist", "vue", "svelte",
        "py", "rb", "go", "rs", "java", "kt", "kts", "c", "h", "cpp", "hpp",
      ]

      if supportedTextExtensions.contains(url.pathExtension.lowercased()),
        let data = try? Data(contentsOf: url),
        data.count <= 2_000_000,
        let fileText = decodeText(data)
      {
        let block = NSMutableAttributedString()
        block.append(NSAttributedString(string: "\n📄  \(item.name)\n", attributes: [
          .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
          .foregroundColor: NSColor.white,
        ]))
        block.append(NSAttributedString(string: fileText, attributes: [
          .font: NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
          .foregroundColor: NSColor.white,
          .backgroundColor: NSColor(calibratedWhite: 0.10, alpha: 1),
        ]))
        if !fileText.hasSuffix("\n") { block.append(NSAttributedString(string: "\n")) }
        block.append(NSAttributedString(string: "\n"))
        block.addAttribute(Self.attachmentIDKey, value: identifier, range: NSRange(location: 0, length: block.length))
        return block
      }

      let attachment = NSTextAttachment()
      attachment.fileWrapper = try? FileWrapper(url: url, options: .immediate)
      attachment.fileWrapper?.preferredFilename = "absdev-kb-\(identifier)"
      if let image = NSImage(contentsOf: url) {
        let maxWidth: CGFloat = 760
        let ratio = min(1, maxWidth / max(image.size.width, 1))
        image.size = NSSize(width: image.size.width * ratio, height: image.size.height * ratio)
        attachment.image = image
      } else {
        attachment.image = NSWorkspace.shared.icon(forFile: url.path)
        attachment.bounds = NSRect(x: 0, y: -4, width: 32, height: 32)
      }
      let block = NSMutableAttributedString(string: "\n")
      block.append(NSAttributedString(attachment: attachment))
      block.append(NSAttributedString(string: "  \(item.name)  •  Use Download Attachment to save a copy\n", attributes: [
        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
        .foregroundColor: NSColor.lightGray,
      ]))
      block.addAttribute(Self.attachmentIDKey, value: identifier, range: NSRange(location: 0, length: block.length))
      return block
    }
  }
}

private struct KBAttachmentInlineView: View {
  let attachment: KBAttachment
  let fileURL: URL
  let open: () -> Void
  let reveal: () -> Void
  let remove: () -> Void

  private var fileExtension: String { fileURL.pathExtension.lowercased() }
  private var isImage: Bool { ["png", "jpg", "jpeg", "gif", "heic", "tif", "tiff", "webp"].contains(fileExtension) }
  private var isText: Bool { ["txt", "md", "markdown", "json", "xml", "yaml", "yml", "csv", "log", "php", "swift", "js", "ts", "css", "html", "env"].contains(fileExtension) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 9) {
        Image(systemName: iconName)
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(attachment.name)
            .font(.subheadline.weight(.semibold))
          Text(ByteCountFormatter.string(fromByteCount: attachment.size, countStyle: .file))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Open", action: open).buttonStyle(.borderless)
        Button("Reveal", action: reveal).buttonStyle(.borderless)
        Button(role: .destructive, action: remove) {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help("Remove attachment")
      }

      Group {
        if isImage, let image = NSImage(contentsOf: fileURL) {
          Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: 520)
            .background(Color(nsColor: .textBackgroundColor))
        } else if isText {
          KBTextAttachmentPreview(url: fileURL)
        } else {
          KBQuickLookPreview(url: fileURL)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .onTapGesture(count: 2, perform: open)
    }
    .padding(12)
    .background(.background, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
    .contextMenu {
      Button("Open", action: open)
      Button("Reveal in Finder", action: reveal)
      Divider()
      Button("Remove", role: .destructive, action: remove)
    }
  }

  private var iconName: String {
    if isImage { return "photo" }
    if fileExtension == "pdf" { return "doc.richtext" }
    if isText { return "doc.text" }
    return "doc"
  }
}

private struct KBTextAttachmentPreview: View {
  let url: URL
  @State private var content = "Loading preview…"

  var body: some View {
    ScrollView([.horizontal, .vertical]) {
      Text(content)
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
    .frame(minHeight: 120, maxHeight: 360)
    .background(Color(nsColor: .textBackgroundColor))
    .task(id: url) {
      do {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let limited = data.prefix(250_000)
        content = String(data: limited, encoding: .utf8) ?? "This text file cannot be previewed."
        if data.count > limited.count { content += "\n\n— Preview truncated —" }
      } catch {
        content = "Preview unavailable: \(error.localizedDescription)"
      }
    }
  }
}

private struct KBQuickLookPreview: View {
  let url: URL
  @State private var thumbnail: NSImage?
  @State private var failed = false

  var body: some View {
    ZStack {
      Color(nsColor: .textBackgroundColor)
      if let thumbnail {
        Image(nsImage: thumbnail)
          .resizable()
          .scaledToFit()
          .padding(12)
      } else if failed {
        ContentUnavailableView("Preview Unavailable", systemImage: "doc")
      } else {
        ProgressView("Generating preview…")
      }
    }
    .frame(minHeight: 180, maxHeight: 460)
    .task(id: url) { await loadThumbnail() }
  }

  private func loadThumbnail() async {
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    let request = QLThumbnailGenerator.Request(
      fileAt: url,
      size: CGSize(width: 900, height: 700),
      scale: scale,
      representationTypes: [.thumbnail, .lowQualityThumbnail]
    )
    do {
      let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
      thumbnail = representation.nsImage
    } catch {
      failed = true
    }
  }
}



private struct KBVersionSnapshot: Codable, Identifiable {
  let id: UUID
  let documentID: UUID
  let title: String
  let text: String
  let richTextData: Data?
  let createdAt: Date
}

private final class KBVersionStore {
  static let shared = KBVersionStore()
  private var url: URL { KBPersistence.support.appendingPathComponent("KnowledgeBaseVersions.json") }
  func all(for documentID: UUID) -> [KBVersionSnapshot] {
    guard let data = try? Data(contentsOf: url), let values = try? JSONDecoder().decode([KBVersionSnapshot].self, from: data) else { return [] }
    return values.filter { $0.documentID == documentID }.sorted { $0.createdAt > $1.createdAt }
  }
  func save(document: KBDocument) {
    var values: [KBVersionSnapshot] = []
    if let data = try? Data(contentsOf: url) { values = (try? JSONDecoder().decode([KBVersionSnapshot].self, from: data)) ?? [] }
    if let last = values.last(where: { $0.documentID == document.id }), last.title == document.title, last.text == document.text { return }
    values.append(KBVersionSnapshot(id: UUID(), documentID: document.id, title: document.title, text: document.text, richTextData: document.richTextData, createdAt: Date()))
    if values.count > 500 { values.removeFirst(values.count - 500) }
    if let data = try? JSONEncoder().encode(values) { try? data.write(to: url, options: .atomic) }
  }
}

private struct KBSpotlightDocument: Sendable {
  let id: UUID
  let title: String
  let text: String
  let tags: String
}

private final class KBSpotlightIndexer: @unchecked Sendable {
  static let shared = KBSpotlightIndexer()
  private let queue = DispatchQueue(label: "com.absdev.studio.knowledge.spotlight")

  func index(_ document: KBDocument) {
    index(KBSpotlightDocument(
      id: document.id,
      title: document.title,
      text: document.text,
      tags: document.tags
    ))
  }

  func index(_ document: KBSpotlightDocument) {
    queue.async {
      let attributes = CSSearchableItemAttributeSet(contentType: .text)
      attributes.title = document.title
      attributes.contentDescription = document.text
      attributes.keywords = document.tags.split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      let item = CSSearchableItem(
        uniqueIdentifier: document.id.uuidString,
        domainIdentifier: "com.absdev.studio.knowledge",
        attributeSet: attributes
      )
      CSSearchableIndex.default().indexSearchableItems([item]) { error in
        if let error {
          NSLog("ABSDEV Knowledge Spotlight indexing skipped: %@", error.localizedDescription)
        }
      }
    }
  }

  func remove(documentID: UUID) {
    remove(documentIDs: [documentID])
  }

  func remove(documentIDs: [UUID]) {
    guard !documentIDs.isEmpty else { return }
    let identifiers = documentIDs.map(\.uuidString)
    queue.async {
      CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: identifiers) { error in
        if let error {
          NSLog("ABSDEV Knowledge Spotlight removal skipped: %@", error.localizedDescription)
        }
      }
    }
  }
}

private struct KBInspector: View {
  @Bindable var store: KBStore
  let document: KBDocument
  @State private var tags = ""
  @State private var versions: [KBVersionSnapshot] = []
  private var headings: [String] {
    document.text.split(separator: "\n").map(String.init).filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Label("Inspector", systemImage: "info.circle").font(.headline)
        GroupBox("Metadata") {
          VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Words", value: "\(document.text.split { $0.isWhitespace }.count)")
            LabeledContent("Characters", value: "\(document.text.count)")
            LabeledContent("Version", value: "\(document.version)")
            LabeledContent("Updated", value: document.updatedAt.formatted(date: .abbreviated, time: .shortened))
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
        GroupBox("Tags") {
          TextField("architecture, api, todo", text: $tags)
            .textFieldStyle(.roundedBorder)
            .onSubmit { store.updateMetadata(tags: tags) }
        }
        GroupBox("Outline") {
          if headings.isEmpty { Text("No headings").foregroundStyle(.secondary) }
          else { ForEach(headings, id: \.self) { Text($0.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)).lineLimit(1) } }
        }
        GroupBox("Attachments") {
          if document.attachments.isEmpty { Text("No attachments").foregroundStyle(.secondary) }
          else {
            ForEach(Array(document.attachments).sorted { $0.name < $1.name }) { attachment in
              HStack {
                Image(systemName: "paperclip")
                Text(attachment.name).lineLimit(1)
                Spacer()
                Button { store.download(attachment) } label: { Image(systemName: "square.and.arrow.down") }.buttonStyle(.borderless)
              }
            }
          }
        }
        GroupBox("Version History") {
          VStack(alignment: .leading, spacing: 8) {
            Button("Create Snapshot") { store.createVersionSnapshot(); versions = KBVersionStore.shared.all(for: document.id) }
            ForEach(versions.prefix(10)) { version in
              Text(version.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
            }
          }
        }
      }.padding(14)
    }
    .background(.bar)
    .onAppear { tags = document.tags; versions = KBVersionStore.shared.all(for: document.id) }
    .onChange(of: document.id) { _, _ in tags = document.tags; versions = KBVersionStore.shared.all(for: document.id) }
  }
}

private struct KBCommandPalette: View {
  @Bindable var store: KBStore
  @Binding var search: String
  @Binding var isPresented: Bool
  var matches: [KBDocument] {
    let all = store.documents.filter { !$0.isTrashed }
    guard !search.isEmpty else { return Array(all.prefix(20)) }
    return all.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.text.localizedCaseInsensitiveContains(search) }
  }
  var body: some View {
    VStack(spacing: 0) {
      TextField("Jump to a document", text: $search)
        .textFieldStyle(.plain).font(.title3).padding(16)
      Divider()
      List(matches) { document in
        Button {
          store.showingTrash = false
          store.selection = document.id
          isPresented = false
        } label: {
          HStack { Image(systemName: "doc.text"); Text(document.title); Spacer(); Text(KBPriority(rawValue: document.priority)?.name ?? "Normal").foregroundStyle(.secondary) }
        }.buttonStyle(.plain)
      }.listStyle(.plain)
    }.frame(width: 560, height: 440)
  }
}

