import Foundation

/// Scans ~/Library to discover heavy subdirectories belonging to apps.
///
/// KEY INSIGHT (v0.3):
///   Moving entire ~/Library/Application Support/{app} folders breaks
///   Electron apps (and likely others) because they check the real path
///   of their support directory. Instead, we scan INSIDE those folders
///   for heavy subdirectories (caches, blobs, VMs, indexes) and symlink
///   those individually. The parent folder stays real.
///
///   Example: ~/Library/Application Support/Claude/ stays real
///            ~/Library/Application Support/Claude/vm_bundles → external (12GB)
///            ~/Library/Application Support/Claude/Cache → external (146MB)
///
/// Also scans ~/Library/Caches/{bundleID} (safe to symlink entirely).
struct LibraryScanner {

    // MARK: - Types

    /// A single item (file or directory) that can be migrated.
    struct MigratableItem: Sendable, Identifiable {
        let id: String
        let url: URL
        let parentAppName: String
        let bundleIdentifier: String?
        let sizeBytes: UInt64
        let depth: ItemDepth
        let isAlreadySymlinked: Bool

        /// Whether this is a top-level Library folder or a subdirectory inside one.
        enum ItemDepth: String, Sendable {
            case topLevel       // e.g., ~/Library/Caches/Firefox (safe to symlink whole thing)
            case subDirectory   // e.g., ~/Library/Application Support/Claude/vm_bundles
        }

        var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
        }

        var displayName: String {
            let parent = url.deletingLastPathComponent().lastPathComponent
            return "\(parent)/\(url.lastPathComponent)"
        }
    }

    /// Complete scan results for an app.
    struct AppScanResult: Sendable, Identifiable {
        let id: String  // Bundle ID or app name
        let appName: String
        let bundleIdentifier: String?
        let appBundleSize: UInt64
        let migratableItems: [MigratableItem]

        var totalMigratableSize: UInt64 {
            migratableItems.reduce(0) { $0 + $1.sizeBytes }
        }

        var formattedMigratableSize: String {
            ByteCountFormatter.string(fromByteCount: Int64(totalMigratableSize), countStyle: .file)
        }
    }

    // MARK: - Configuration

    /// Minimum size for a subdirectory to be worth migrating.
    var minimumSubdirSize: UInt64 = 10_000_000  // 10 MB

    /// Minimum total migratable size for an app to show up as a candidate.
    var minimumAppMigratableSize: UInt64 = 50_000_000  // 50 MB

    // MARK: - Properties

    private let fileManager = FileManager.default
    private let homeLibrary: URL

    init() {
        self.homeLibrary = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
    }

    // MARK: - Public API

    /// Scan a single app for migratable subdirectories.
    func scanApp(appURL: URL) -> AppScanResult {
        let bundleID = readBundleIdentifier(from: appURL)
        let appName = appURL.deletingPathExtension().lastPathComponent

        var searchTerms: [String] = [appName]
        if let bid = bundleID {
            searchTerms.append(bid)
            let parts = bid.split(separator: ".")
            if parts.count >= 2 {
                searchTerms.append(String(parts.last!))
            }
        }

        var items: [MigratableItem] = []

        // 1. Deep scan Application Support — look INSIDE matching folders
        items.append(contentsOf: deepScanApplicationSupport(
            appName: appName,
            bundleID: bundleID,
            searchTerms: searchTerms
        ))

        // 2. Top-level scan Caches — these are safe to symlink entirely
        items.append(contentsOf: scanTopLevel(
            category: "Caches",
            appName: appName,
            bundleID: bundleID,
            searchTerms: searchTerms
        ))

        // 3. Top-level scan Logs
        items.append(contentsOf: scanTopLevel(
            category: "Logs",
            appName: appName,
            bundleID: bundleID,
            searchTerms: searchTerms
        ))

        // De-duplicate by path
        var seen = Set<String>()
        items = items.filter { seen.insert($0.url.path).inserted }

        // Filter out tiny items and already-symlinked items
        items = items.filter { $0.sizeBytes >= minimumSubdirSize && !$0.isAlreadySymlinked }

        // Sort by size descending
        items.sort { $0.sizeBytes > $1.sizeBytes }

        let appSize = directorySize(at: appURL)

        return AppScanResult(
            id: bundleID ?? appName,
            appName: appName,
            bundleIdentifier: bundleID,
            appBundleSize: appSize,
            migratableItems: items
        )
    }

    /// Scan all third-party apps.
    func scanAllApps(in applicationsDir: String = "/Applications") async -> [AppScanResult] {
        let filter = AppFilter()
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(atPath: applicationsDir) else {
            return []
        }

        var results: [AppScanResult] = []

        for item in contents where item.hasSuffix(".app") {
            let appURL = URL(fileURLWithPath: applicationsDir)
                .appendingPathComponent(item)

            // Skip system apps and symlinks.
            guard (try? await filter.shouldProcess(appURL: appURL)) == true else { continue }

            let resourceValues = try? appURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if resourceValues?.isSymbolicLink == true { continue }

            let result = scanApp(appURL: appURL)

            // Only include apps with enough migratable data.
            if result.totalMigratableSize >= minimumAppMigratableSize {
                results.append(result)
            }
        }

        results.sort { $0.totalMigratableSize > $1.totalMigratableSize }
        return results
    }

    // MARK: - Deep Scan (Inside Application Support)

    /// Scan INSIDE ~/Library/Application Support/{appName} for heavy subdirectories.
    /// The parent folder stays — only subdirectories get symlinked.
    private func deepScanApplicationSupport(
        appName: String,
        bundleID: String?,
        searchTerms: [String]
    ) -> [MigratableItem] {
        let appSupportDir = homeLibrary.appendingPathComponent("Application Support")
        guard fileManager.fileExists(atPath: appSupportDir.path) else { return [] }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: appSupportDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var items: [MigratableItem] = []

        for folderURL in contents {
            let name = folderURL.lastPathComponent

            // Check if this folder belongs to the app.
            let matches = searchTerms.contains { term in
                name.localizedCaseInsensitiveContains(term)
            }
            guard matches else { continue }

            // Don't scan inside if the whole folder is already a symlink.
            if isSymlink(at: folderURL) { continue }

            // Scan subdirectories INSIDE this folder.
            guard let subContents = try? fileManager.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for subURL in subContents {
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: subURL.path, isDirectory: &isDir),
                      isDir.boolValue else { continue }

                let alreadyLinked = isSymlink(at: subURL)
                let size = alreadyLinked ? 0 : directorySize(at: subURL)

                items.append(MigratableItem(
                    id: "AppSupport:\(name)/\(subURL.lastPathComponent)",
                    url: subURL,
                    parentAppName: appName,
                    bundleIdentifier: bundleID,
                    sizeBytes: size,
                    depth: .subDirectory,
                    isAlreadySymlinked: alreadyLinked
                ))
            }
        }

        return items
    }

    // MARK: - Top-Level Scan (Caches, Logs)

    /// Scan for top-level folders in a Library category that match the app.
    /// These are safe to symlink entirely (Caches regenerate, Logs are expendable).
    private func scanTopLevel(
        category: String,
        appName: String,
        bundleID: String?,
        searchTerms: [String]
    ) -> [MigratableItem] {
        let categoryDir = homeLibrary.appendingPathComponent(category)
        guard fileManager.fileExists(atPath: categoryDir.path) else { return [] }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: categoryDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var items: [MigratableItem] = []

        for itemURL in contents {
            let name = itemURL.lastPathComponent
            let matches = searchTerms.contains { term in
                name.localizedCaseInsensitiveContains(term)
            }
            guard matches else { continue }

            let alreadyLinked = isSymlink(at: itemURL)
            let size = alreadyLinked ? 0 : directorySize(at: itemURL)

            items.append(MigratableItem(
                id: "\(category):\(name)",
                url: itemURL,
                parentAppName: appName,
                bundleIdentifier: bundleID,
                sizeBytes: size,
                depth: .topLevel,
                isAlreadySymlinked: alreadyLinked
            ))
        }

        return items
    }

    // MARK: - Helpers

    private func isSymlink(at url: URL) -> Bool {
        let resourceValues = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return resourceValues?.isSymbolicLink ?? false
    }

    private func directorySize(at url: URL) -> UInt64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [],
            errorHandler: nil
        ) else {
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .flatMap { UInt64($0) } ?? 0
        }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += UInt64(size)
        }
        return total
    }

    private func readBundleIdentifier(from appURL: URL) -> String? {
        let plistURL = appURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return plist["CFBundleIdentifier"] as? String
    }
}
