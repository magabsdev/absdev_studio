import XCTest
@testable import ABSDEVStudio

@MainActor
final class KnowledgeBaseTrashTests: XCTestCase {
  func testRestoreMovesDocumentBackToDocumentsAndSelectsIt() async {
    let persistence = KBPersistence(memory: true)
    let store = KBStore(projectID: UUID(), persistence: persistence)

    store.create()
    let documentID = try! XCTUnwrap(store.selection)
    store.delete(documentID: documentID)
    store.showingTrash = true

    store.restore(documentID: documentID)
    await waitForStatus("Restored", store: store)

    XCTAssertFalse(store.showingTrash)
    XCTAssertEqual(store.selection, documentID)
    XCTAssertEqual(store.documents.first(where: { $0.id == documentID })?.isTrashed, false)
    XCTAssertEqual(store.status, "Restored")
  }

  func testEmptyTrashPermanentlyRemovesOnlyTrashedDocuments() async {
    let persistence = KBPersistence(memory: true)
    let store = KBStore(projectID: UUID(), persistence: persistence)

    store.create()
    let keptID = try! XCTUnwrap(store.selection)
    store.create()
    let deletedID = try! XCTUnwrap(store.selection)
    store.delete(documentID: deletedID)
    store.showingTrash = true

    store.emptyTrash()
    await waitForStatus("Trash emptied", store: store)

    XCTAssertTrue(store.documents.contains(where: { $0.id == keptID }))
    XCTAssertFalse(store.documents.contains(where: { $0.id == deletedID }))
    XCTAssertNil(store.selection)
    XCTAssertEqual(store.status, "Trash emptied")
  }

  private func waitForStatus(_ expected: String, store: KBStore) async {
    for _ in 0..<100 {
      if store.status == expected { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for status \(expected); current status: \(store.status)")
  }
}
