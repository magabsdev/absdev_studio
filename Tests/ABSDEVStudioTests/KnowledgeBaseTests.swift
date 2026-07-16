import XCTest
@testable import ABSDEVStudio

@MainActor
final class KnowledgeBaseTests: XCTestCase {
    private var root: URL!
    private var controller: KnowledgeBaseController!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        controller = KnowledgeBaseController(
            storeURL: root.appendingPathComponent("store.sqlite"),
            attachmentsRoot: root.appendingPathComponent("attachments")
        )
    }

    override func tearDown() async throws {
        controller = nil
        try? FileManager.default.removeItem(at: root)
    }

    func testDocumentsAreIsolatedByProject() throws {
        let first = UUID(), second = UUID()
        _ = try controller.createDocument(projectID: first, title: "First")
        _ = try controller.createDocument(projectID: second, title: "Second")
        XCTAssertEqual(try controller.documents(projectID: first).map(\.title), ["First"])
        XCTAssertEqual(try controller.documents(projectID: second).map(\.title), ["Second"])
    }

    func testDuplicateCopiesTextPriorityAndAttachment() throws {
        let project = UUID()
        let original = try controller.createDocument(projectID: project, title: "Guide")
        original.content = "Deployment instructions"
        original.priority = .high
        let file = root.appendingPathComponent("notes.txt")
        try Data("attachment".utf8).write(to: file)
        _ = try controller.addAttachment(file, to: original)

        let copy = try controller.duplicate(original)
        XCTAssertEqual(copy.title, "Guide Copy")
        XCTAssertEqual(copy.content, original.content)
        XCTAssertEqual(copy.priority, .high)
        XCTAssertEqual(copy.attachments.count, 1)
    }

    func testExportAndMergeImportPreservesDocuments() throws {
        let sourceProject = UUID(), targetProject = UUID()
        let document = try controller.createDocument(projectID: sourceProject, title: "Hosting")
        document.content = "Transfer-ready"
        try controller.touch(document)
        let package = try controller.exportProject(projectID: sourceProject, projectName: "Demo", to: root)

        try controller.importProject(from: package, into: targetProject, strategy: .merge)
        let imported = try XCTUnwrap(controller.documents(projectID: targetProject).first)
        XCTAssertEqual(imported.title, "Hosting")
        XCTAssertEqual(imported.content, "Transfer-ready")
    }
}
