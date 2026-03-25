import XCTest
@testable import ProjectSidecar

// MARK: - AppFilter Tests

final class AppFilterTests: XCTestCase {

    private let filter = AppFilter()

    func testRejectsSystemApplicationsPath() async throws {
        let url = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let result = try await filter.shouldProcess(appURL: url)
        XCTAssertFalse(result, "Apps under /System/Applications must be rejected.")
    }

    func testRejectsSystemLibraryPath() async throws {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        let result = try await filter.shouldProcess(appURL: url)
        XCTAssertFalse(result, "Apps under /System/Library must be rejected.")
    }

    func testAcceptsThirdPartyAppAtArbitraryPath() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidecarTests-\(UUID().uuidString)")
        let fakeApp = tempDir.appendingPathComponent("SomeApp.app")
        try FileManager.default.createDirectory(at: fakeApp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result = try await filter.shouldProcess(appURL: fakeApp)
        XCTAssertTrue(result, "App without Apple signature should pass filter.")
    }

    func testRejectsAppleBundleIdentifier() async throws {
        // Create a fake .app with a com.apple.* bundle ID.
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
        XCTAssertFalse(result, "com.apple.* bundle ID must be rejected.")
    }
}

// MARK: - DiskAnalyzer Tests

final class DiskAnalyzerTests: XCTestCase {

    func testDiskPressureLevels() {
        // Simulate different usage levels.
        let low = DiskAnalyzer.DiskState(totalBytes: 256_000_000_000, availableBytes: 128_000_000_000, usedBytes: 128_000_000_000)
        XCTAssertEqual(low.pressure, .low)

        let moderate = DiskAnalyzer.DiskState(totalBytes: 256_000_000_000, availableBytes: 64_000_000_000, usedBytes: 192_000_000_000)
        XCTAssertEqual(moderate.pressure, .moderate)

        let high = DiskAnalyzer.DiskState(totalBytes: 256_000_000_000, availableBytes: 38_000_000_000, usedBytes: 218_000_000_000)
        XCTAssertEqual(high.pressure, .high)

        let critical = DiskAnalyzer.DiskState(totalBytes: 256_000_000_000, availableBytes: 10_000_000_000, usedBytes: 246_000_000_000)
        XCTAssertEqual(critical.pressure, .critical)
    }

    func testPrioritizationSortsBySizeDescending() {
        let analyzer = DiskAnalyzer()
        let diskState = DiskAnalyzer.DiskState(
            totalBytes: 256_000_000_000,
            availableBytes: 30_000_000_000,
            usedBytes: 226_000_000_000
        )

        let small = LibraryScanner.AppFootprint(
            bundleIdentifier: "com.test.small",
            appBundleURL: URL(fileURLWithPath: "/Applications/Small.app"),
            appBundleSize: 60_000_000,    // 60 MB
            libraryItems: []
        )

        let large = LibraryScanner.AppFootprint(
            bundleIdentifier: "com.test.large",
            appBundleURL: URL(fileURLWithPath: "/Applications/Large.app"),
            appBundleSize: 4_000_000_000, // 4 GB
            libraryItems: []
        )

        let candidates = analyzer.prioritize(footprints: [small, large], diskState: diskState)

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates.first?.footprint.bundleIdentifier, "com.test.large",
                       "Larger app should be prioritized first.")
        XCTAssertTrue(candidates[0].score > candidates[1].score)
    }

    func testSmallAppsBelowThresholdAreExcluded() {
        var analyzer = DiskAnalyzer()
        analyzer.minimumFootprintBytes = 100_000_000 // 100 MB threshold

        let diskState = DiskAnalyzer.DiskState(
            totalBytes: 256_000_000_000,
            availableBytes: 30_000_000_000,
            usedBytes: 226_000_000_000
        )

        let tinyApp = LibraryScanner.AppFootprint(
            bundleIdentifier: "com.test.tiny",
            appBundleURL: URL(fileURLWithPath: "/Applications/Tiny.app"),
            appBundleSize: 5_000_000,  // 5 MB
            libraryItems: []
        )

        let candidates = analyzer.prioritize(footprints: [tinyApp], diskState: diskState)
        XCTAssertTrue(candidates.isEmpty, "Apps below threshold should be excluded.")
    }

    func testMigrationPlanStopsWhenTargetMet() {
        let analyzer = DiskAnalyzer()
        let diskState = DiskAnalyzer.DiskState(
            totalBytes: 256_000_000_000,
            availableBytes: 20_000_000_000, // 20 GB free, target is 30 GB
            usedBytes: 236_000_000_000
        )

        // Create candidates that together exceed the 10 GB deficit.
        let candidates = [
            DiskAnalyzer.MigrationCandidate(
                id: "a",
                footprint: LibraryScanner.AppFootprint(
                    bundleIdentifier: "a", appBundleURL: URL(fileURLWithPath: "/a.app"),
                    appBundleSize: 8_000_000_000, libraryItems: []
                ),
                score: 90, reclaimableBytes: 8_000_000_000, reasoning: ""
            ),
            DiskAnalyzer.MigrationCandidate(
                id: "b",
                footprint: LibraryScanner.AppFootprint(
                    bundleIdentifier: "b", appBundleURL: URL(fileURLWithPath: "/b.app"),
                    appBundleSize: 5_000_000_000, libraryItems: []
                ),
                score: 80, reclaimableBytes: 5_000_000_000, reasoning: ""
            ),
            DiskAnalyzer.MigrationCandidate(
                id: "c",
                footprint: LibraryScanner.AppFootprint(
                    bundleIdentifier: "c", appBundleURL: URL(fileURLWithPath: "/c.app"),
                    appBundleSize: 3_000_000_000, libraryItems: []
                ),
                score: 70, reclaimableBytes: 3_000_000_000, reasoning: ""
            ),
        ]

        let plan = analyzer.recommendMigrationPlan(candidates: candidates, diskState: diskState)
        // 8 GB + 5 GB = 13 GB > 10 GB deficit, so only 2 apps needed.
        XCTAssertEqual(plan.toMigrate.count, 2, "Plan should stop once deficit is covered.")
    }
}

// MARK: - LibraryScanner Category Tests

final class LibraryScannerCategoryTests: XCTestCase {

    func testContainersNotSymlinkSafe() {
        XCTAssertFalse(
            LibraryScanner.LibraryItem.Category.containers.symlinkSafe,
            "Sandboxed containers should not be symlink-safe."
        )
        XCTAssertFalse(
            LibraryScanner.LibraryItem.Category.groupContainers.symlinkSafe
        )
    }

    func testApplicationSupportIsSymlinkSafe() {
        XCTAssertTrue(
            LibraryScanner.LibraryItem.Category.applicationSupport.symlinkSafe
        )
    }

    func testCachesIsSymlinkSafe() {
        XCTAssertTrue(
            LibraryScanner.LibraryItem.Category.caches.symlinkSafe
        )
    }

    func testPriorityOrdering() {
        // Containers should be highest priority (most space).
        let categories = LibraryScanner.LibraryItem.Category.allCases.sorted(by: >)
        XCTAssertEqual(categories.first, .containers)
        XCTAssertEqual(categories.last, .preferences)
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
            externalPath: "/Volumes/Drive/Applications/TestApp.app"
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
            externalPath: "/Volumes/Drive/Applications/TestApp.app"
        )

        let found = manifest.record(forBundleID: "com.test.app")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.appName, "TestApp.app")

        let notFound = manifest.record(forBundleID: "com.other.app")
        XCTAssertNil(notFound)
    }
}
