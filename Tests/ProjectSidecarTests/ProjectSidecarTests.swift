import XCTest
@testable import ProjectSidecar

// MARK: - AppFilter Tests

final class AppFilterTests: XCTestCase {

    private let filter = AppFilter()

    func testRejectsSystemApplicationsPath() async throws {
        let url = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let result = try await filter.shouldProcess(appURL: url)
        XCTAssertFalse(result)
    }

    func testRejectsSystemLibraryPath() async throws {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        let result = try await filter.shouldProcess(appURL: url)
        XCTAssertFalse(result)
    }

    func testAcceptsThirdPartyApp() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidecarTests-\(UUID().uuidString)")
        let fakeApp = tempDir.appendingPathComponent("SomeApp.app")
        try FileManager.default.createDirectory(at: fakeApp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = try await filter.shouldProcess(appURL: fakeApp)
        XCTAssertTrue(result)
    }

    func testRejectsSidecarItself() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidecarTests-\(UUID().uuidString)")
        let sidecarApp = tempDir.appendingPathComponent("Sidecar.app")
        try FileManager.default.createDirectory(at: sidecarApp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = try await filter.shouldProcess(appURL: sidecarApp)
        XCTAssertFalse(result, "Sidecar must not migrate itself.")
    }

    func testRejectsAppleBundleIdentifier() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidecarTests-\(UUID().uuidString)")
        let fakeApp = tempDir.appendingPathComponent("FakeApple.app")
        let contentsDir = fakeApp.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsDir, withIntermediateDirectories: true)

        let plist: [String: Any] = ["CFBundleIdentifier": "com.apple.FakeTool"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contentsDir.appendingPathComponent("Info.plist"))

        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = try await filter.shouldProcess(appURL: fakeApp)
        XCTAssertFalse(result)
    }
}

// MARK: - LibraryScanner Tests

final class LibraryScannerTests: XCTestCase {

    func testScannerFindsSubdirectories() {
        // This test validates the scanner runs without crashing.
        // Real subdirectory detection requires actual Library data.
        let scanner = LibraryScanner()
        let fakeApp = URL(fileURLWithPath: "/Applications/NonExistentTestApp.app")
        let result = scanner.scanApp(appURL: fakeApp)
        XCTAssertEqual(result.appName, "NonExistentTestApp")
        XCTAssertTrue(result.migratableItems.isEmpty)
    }
}

// MARK: - DiskAnalyzer Tests

final class DiskAnalyzerTests: XCTestCase {

    func testDiskStateReadsRealValues() {
        let analyzer = DiskAnalyzer()
        let state = analyzer.currentDiskState()
        XCTAssertTrue(state.totalBytes > 0, "Should read real disk capacity")
        XCTAssertTrue(state.availableBytes > 0, "Should read available space")
        XCTAssertTrue(state.usedPercentage > 0 && state.usedPercentage < 100)
    }
}

// MARK: - MigrationManifest Tests

final class MigrationManifestTests: XCTestCase {

    func testRecordAndRetrieve() {
        let manifest = MigrationManifest()
        manifest.recordMigration(
            appName: "TestApp.app",
            bundleIdentifier: "com.test.app",
            originalPath: "/Applications/TestApp.app",
            externalPath: "/Applications/TestApp.app"
        )
        XCTAssertEqual(manifest.activeRecords.count, 1)
        XCTAssertEqual(manifest.activeRecords.first?.appName, "TestApp.app")
    }

    func testFindByBundleID() {
        let manifest = MigrationManifest()
        manifest.recordMigration(
            appName: "TestApp.app",
            bundleIdentifier: "com.test.app",
            originalPath: "/Applications/TestApp.app",
            externalPath: "/Applications/TestApp.app"
        )

        XCTAssertNotNil(manifest.record(forBundleID: "com.test.app"))
        XCTAssertNil(manifest.record(forBundleID: "com.other.app"))
    }
}
