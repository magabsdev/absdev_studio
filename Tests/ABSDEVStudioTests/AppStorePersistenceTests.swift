import XCTest
@testable import ABSDEVStudio

@MainActor
final class AppStorePersistenceTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var projectsFile: URL!
    private var defaults: UserDefaults!
    private var defaultsName: String!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ABSDEVStudioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        projectsFile = temporaryDirectory.appendingPathComponent("projects.json")
        defaultsName = "ABSDEVStudioTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)!
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        defaults.removePersistentDomain(forName: defaultsName)
    }

    private func makeStore() -> AppStore {
        AppStore(projectsStorageURL: projectsFile, performsStartupDiscovery: false, defaults: defaults)
    }

    func testEmptyStorageCreatesSampleProjectAndSelectsIt() {
        let store = makeStore()
        XCTAssertEqual(store.projects.count, 1)
        XCTAssertEqual(store.projects.first?.name, "PoolMate")
        XCTAssertEqual(store.selectedProjectID, store.projects.first?.id)
    }

    func testStoredProjectsAreLoaded() throws {
        let expected = [LaravelProject(
            name: "Stored",
            path: "/tmp/stored",
            laravelVersion: "13",
            phpVersion: "8.3",
            branch: "main",
            appURL: "http://stored.test",
            environment: "testing"
        )]
        try JSONEncoder().encode(expected).write(to: projectsFile)

        let store = makeStore()
        XCTAssertEqual(store.projects, expected)
        XCTAssertEqual(store.selectedProject, expected[0])
    }

    func testSetProjectIconPersistsAndClearsCustomImage() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.projects.first?.id)
        store.projects[0].customIconPath = "/tmp/old.svg"

        store.setProjectIcon(projectID: id, symbol: "hammer.fill", colorHex: "#112233")

        XCTAssertEqual(store.projects[0].iconSymbol, "hammer.fill")
        XCTAssertEqual(store.projects[0].iconColorHex, "#112233")
        XCTAssertNil(store.projects[0].customIconPath)

        let stored = try JSONDecoder().decode([LaravelProject].self, from: Data(contentsOf: projectsFile))
        XCTAssertEqual(stored[0].iconSymbol, "hammer.fill")
        XCTAssertEqual(stored[0].iconColorHex, "#112233")
    }

    func testResetProjectIconClearsBrandingAndDeletesImportedFile() throws {
        let store = makeStore()
        let id = try XCTUnwrap(store.projects.first?.id)
        let icon = temporaryDirectory.appendingPathComponent("custom.png")
        try Data("icon".utf8).write(to: icon)
        store.projects[0].iconSymbol = "star.fill"
        store.projects[0].iconColorHex = "#ABCDEF"
        store.projects[0].customIconPath = icon.path

        store.resetProjectIcon(projectID: id)

        XCTAssertNil(store.projects[0].iconSymbol)
        XCTAssertNil(store.projects[0].iconColorHex)
        XCTAssertNil(store.projects[0].customIconPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: icon.path))
    }

    func testRemovingSelectedProjectSelectsRemainingProjectAndPersists() throws {
        let store = makeStore()
        let second = LaravelProject(name: "Second", path: "/tmp/second", laravelVersion: "13", phpVersion: "8.3", branch: "main", appURL: "http://second.test", environment: "local")
        store.projects.append(second)
        store.selectedProjectID = store.projects[0].id

        store.removeSelectedProject()

        XCTAssertEqual(store.projects, [second])
        XCTAssertEqual(store.selectedProjectID, second.id)
        let stored = try JSONDecoder().decode([LaravelProject].self, from: Data(contentsOf: projectsFile))
        XCTAssertEqual(stored, [second])
    }

    func testAvailableSectionsHideSailAndServBayUntilRunningOrInstalled() {
        let store = makeStore()
        store.isSailRunning = false
        store.isServBayInstalled = false
        XCTAssertFalse(store.availableSections.contains(.sail))
        XCTAssertFalse(store.availableSections.contains(.servBay))

        store.isSailRunning = true
        store.isServBayInstalled = true
        XCTAssertTrue(store.availableSections.contains(.sail))
        XCTAssertTrue(store.availableSections.contains(.servBay))
    }

    func testChangingProjectResetsProjectScopedState() {
        let store = makeStore()
        let first = store.projects[0]
        let second = LaravelProject(name: "Second", path: "/does/not/exist", laravelVersion: "13", phpVersion: "8", branch: "main", appURL: "", environment: "local")
        store.projects = [first, second]
        store.commandOutput = ["old output"]
        store.routes = [RouteItem(method: "GET", uri: "/", name: "home", action: "x", middleware: "web")]
        store.logLines = ["old log"]
        store.artisanCommands = [ArtisanCommand(name: "about", description: "", usage: [], aliases: [])]

        store.selectedProjectID = second.id

        XCTAssertEqual(store.commandOutput, ["ABSDEV Studio ready."])
        XCTAssertTrue(store.routes.isEmpty)
        XCTAssertTrue(store.logLines.isEmpty)
        XCTAssertTrue(store.artisanCommands.isEmpty)
    }
}
