import XCTest
@testable import ABSDEVStudio

@MainActor
final class CommandExecutionTests: XCTestCase {
    private func makeStore(projectPath: String) -> AppStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("commands-\(UUID().uuidString).json")
        let defaults = UserDefaults(suiteName: "commands-\(UUID().uuidString)")!
        let store = AppStore(projectsStorageURL: url, performsStartupDiscovery: false, defaults: defaults)
        store.projects = [LaravelProject(name: "Command Project", path: projectPath, laravelVersion: "13", phpVersion: "8.3", branch: "main", appURL: "", environment: "testing")]
        store.selectedProjectID = store.projects[0].id
        return store
    }

    func testRunCommandPublishesProgressAndSuccessfulCompletion() async throws {
        let dir = FileManager.default.temporaryDirectory
        let store = makeStore(projectPath: dir.path)

        store.runCommand("printf 'hello from test\\n'")
        XCTAssertTrue(store.isBusy)
        XCTAssertTrue(store.isCommandProgressPresented)
        XCTAssertEqual(store.commandProgressCommand, "printf 'hello from test\\n'")

        try await waitUntil(timeout: 3) { !store.isBusy }
        XCTAssertFalse(store.isCommandProgressPresented)
        XCTAssertTrue(store.commandOutput.contains(where: { $0.contains("hello from test") }))
        XCTAssertEqual(store.statusMessage, "Command completed")
    }

    func testRunCommandReportsFailure() async throws {
        let store = makeStore(projectPath: FileManager.default.temporaryDirectory.path)
        store.runCommand("echo failed-output; exit 7")

        try await waitUntil(timeout: 3) { !store.isBusy }
        XCTAssertEqual(store.statusMessage, "Command failed")
        XCTAssertTrue(store.commandOutput.contains(where: { $0.contains("Failed (exit 7)") }))
    }

    func testTestCommandCreatesFailureReport() async throws {
        let store = makeStore(projectPath: FileManager.default.temporaryDirectory.path)
        store.runCommand("php artisan test; echo 'FAILED Tests\\Feature\\ExampleTest'; exit 1")

        try await waitUntil(timeout: 3) { !store.isBusy }
        XCTAssertNotNil(store.testFailureReport)
        XCTAssertEqual(store.testFailureReport?.exitCode, 1)
        XCTAssertTrue(store.testFailureReport?.details.contains("FAILED") == true)
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
