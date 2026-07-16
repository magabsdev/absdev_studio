import XCTest
@testable import ABSDEVStudio

final class ModelTests: XCTestCase {
    func testLaravelProjectCodableRoundTripPreservesBranding() throws {
        let project = LaravelProject(
            name: "PoolMate",
            path: "/tmp/PoolMate",
            laravelVersion: "13.1",
            phpVersion: "8.3",
            branch: "develop",
            appURL: "https://poolmate.test",
            environment: "local",
            iconSymbol: "shippingbox.fill",
            iconColorHex: "#3366FF",
            customIconPath: "/tmp/icon.svg"
        )

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(LaravelProject.self, from: data)

        XCTAssertEqual(decoded, project)
    }

    func testArtisanCommandNamespaceAndUsage() {
        let command = ArtisanCommand(
            name: "cache:clear",
            description: "Flush the cache",
            usage: ["cache:clear {--store=}"],
            aliases: ["cache:flush"]
        )

        XCTAssertEqual(command.namespace, "Cache")
        XCTAssertEqual(command.primaryUsage, "cache:clear {--store=}")
        XCTAssertEqual(command.id, "cache:clear")
    }

    func testGlobalArtisanCommandUsesGlobalNamespace() {
        let command = ArtisanCommand(name: "about", description: "", usage: [], aliases: [])
        XCTAssertEqual(command.namespace, "Global")
        XCTAssertEqual(command.primaryUsage, "about")
    }

    func testTestFailureReportTitles() {
        XCTAssertEqual(TestFailureReport(command: "test", projectName: "A", exitCode: 1, failureCount: 1, details: "x").title, "1 Test Failed")
        XCTAssertEqual(TestFailureReport(command: "test", projectName: "A", exitCode: 1, failureCount: 3, details: "x").title, "3 Tests Failed")
        XCTAssertEqual(TestFailureReport(command: "test", projectName: "A", exitCode: 1, failureCount: nil, details: "x").title, "Tests Failed")
    }

    func testANSIControlSequenceRemoval() {
        let value = "\u{001B}[32mPASS\u{001B}[0m\r\nDone"
        XCTAssertEqual(value.removingANSIControlSequences, "PASS\r\nDone")
        XCTAssertEqual("  value  ".trimmed, "value")
        XCTAssertNil("".nonEmpty)
        XCTAssertEqual("a\n\nb".lines, ["a", "b"])
    }

    func testEverySectionHasStableIdentityAndSymbol() {
        XCTAssertEqual(Set(AppSection.allCases.map(\.id)).count, AppSection.allCases.count)
        XCTAssertTrue(AppSection.allCases.allSatisfy { !$0.symbol.isEmpty })
    }
}
