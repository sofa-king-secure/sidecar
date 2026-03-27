import Foundation

/// Scans `~/Library` and related directories to discover all data folders
/// belonging to a given application. This is the key to actually freeing
/// disk space — the .app bundle is often a fraction of total footprint.
///
/// Targets (per macOS conventions):
///   ~/Library/Application Support/{bundleID or appName}
///   ~/Library/Caches/{bundleID}
///   ~/Library/Containers/{bundleID}
///   ~/Library/Group Containers/*.{bundleID component}
///   ~/Library/Preferences/{bundleID}.plist
///   ~/Library/Saved Application State/{bundleID}.savedState
///   ~/Library/Logs/{bundleID or appName}
///   ~/Library/HTTPStorages/{bundleID}
///   ~/Library/WebKit/{bundleID}
///
/// All discovery uses native FileManager — no shell calls per CLAUDE.md.
struct LibraryScanner {

    // MARK: - Types

    /// A discovered library data folder and its role.
    struct LibraryItem: Sendable, Identifiable {
        let id: String          // Composite key: "{category}:{path}"
        let url: URL
        let category: Category
        let sizeBytes: UInt64

        /// How important this data is — affects migration strategy.
        enum Category: String, Sendable, CaseIterable, Comparable {
            case applicationSupport = "Application Support"
            case containers         = "Containers"
            case groupContainers    = "Group Containers"
            case caches             = "Caches"
            case preferences        = "Preferences"
            case savedState         = "Saved Application State"
            case logs               = "Logs"
            case httpStorages       = "HTTPStorages"
            case webKit             = "WebKit"

            /// Rough priority: higher = more important to migrate for space.
            var migrationPriority: Int {
                switch self {
                case .containers:         return 100  // Often huge (sandboxed app data)
                case .applicationSupport: return 90   // Plugins, caches, databases
                case .groupContainers:    return 80
                case .caches:             return 70   // Can be large but regenerable
                case .webKit:             return 50
                case .httpStorages:       return 40
                case .savedState:         return 30
                case .logs:               return 20
                case .preferences:        return 10   // Tiny plists, rarely worth moving
                }
            }

            /// Whether this category is safe to symlink. Some categories
            /// cause issues when symlinked (sandboxed containers).
            var symlinkSafe: Bool {
                switch self {
                case .containers, .groupContainers:
                    return false  // Sandboxed apps may reject symlinked containers.
                default:
                    return true
                }
            }

            static func < (lhs: Self, rhs: Self) -> Bool {
                lhs.migrationPriority < rhs.migrationPriority
            }
        }
    }

    /// Complete footprint of an app across the system.
    struct AppFootprint: Sendable {
        let bundleIdentifier: String?
        let appBundleURL: URL
        let appBundleSize: UInt64
        let libraryItems: [LibraryItem]

        /// Total bytes across app bundle + all library data.
        var totalSize: UInt64 {
            appBundleSize + libraryItems.reduce(0) { $0 + $1.sizeBytes }
        }

        /// Only the items that are safe to symlink.
        var symlinkableItems: [LibraryItem] {
            libraryItems.filter { $0.category.symlinkSafe }
        }

        /// Items that need special handling (copy + periodic sync, not symlink).
        var unsafeItems: [LibraryItem] {
            libraryItems.filter { !$0.category.symlinkSafe }
        }

        /// Human-readable size.
        var formattedTotalSize: String {
            ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file)
        }
    }

    // MARK: - Properties

    private let fileManager = FileManager.default
    private let homeLibrary: URL

    init() {
        self.homeLibrary = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
    }

    // MARK: - Public API

    /// Scan the full disk footprint for an app.
    func scanFootprint(for appURL: URL) async -> AppFootprint {
        let bundleID = readBundleIdentifier(from: appURL)
        let appName = appURL.deletingPathExtension().lastPathComponent

        // Gather search terms: bundle ID and app name.
        var searchTerms: [String] = []
        if let bid = bundleID { searchTerms.append(bid) }
        searchTerms.append(appName)

        // Scan each library subdirectory.
        var items: [LibraryItem] = []

        for category in LibraryItem.Category.allCases {
            let discovered = scanCategory(category, searchTerms: searchTerms, bundleID: bundleID)
            items.append(contentsOf: discovered)
        }

        // De-duplicate by path.
        var seen = Set<String>()
        items = items.filter { seen.insert($0.url.path).inserted }

        // Sort by size descending — biggest offenders first.
        items.sort { $0.sizeBytes > $1.sizeBytes }

        let appSize = directorySize(at: appURL)

        return AppFootprint(
            bundleIdentifier: bundleID,
            appBundleURL: appURL,
            appBundleSize: appSize,
            libraryItems: items
        )
    }

    /// Batch scan: analyze all third-party apps and return sorted by total footprint.
    func scanAllApps(in applicationsDir: String = "/Applications") async -> [AppFootprint] {
        let filter = AppFilter()
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(atPath: applicationsDir) else {
            return []
        }

        var footprints: [AppFootprint] = []

        for item in contents where item.hasSuffix(".app") {
            let appURL = URL(fileURLWithPath: applicationsDir)
                .appendingPathComponent(item)

            // Skip system apps.
            guard (try? await filter.shouldProcess(appURL: appURL)) == true else {
                continue
            }

            // Skip items that are already symlinks (already migrated).
            var isSymlink: Bool {
                let resourceValues = try? appURL.resourceValues(forKeys: [.isSymbolicLinkKey])
                return resourceValues?.isSymbolicLink ?? false
            }
            guard !isSymlink else { continue }

            let footprint = await scanFootprint(for: appURL)
            footprints.append(footprint)
        }

        // Sort biggest first — these are the migration candidates.
        footprints.sort { $0.totalSize > $1.totalSize }
        return footprints
    }

    // MARK: - Category Scanning

    private func scanCategory(
        _ category: LibraryItem.Category,
        searchTerms: [String],
        bundleID: String?
    ) -> [LibraryItem] {
        let categoryDir = homeLibrary.appendingPathComponent(category.rawValue)

        guard fileManager.fileExists(atPath: categoryDir.path) else { return [] }

        // Preferences are individual .plist files, not directories.
        if category == .preferences {
            return scanPreferences(searchTerms: searchTerms, bundleID: bundleID)
        }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: categoryDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [LibraryItem] = []

        for itemURL in contents {
            let name = itemURL.lastPathComponent

            let matches: Bool = {
                for term in searchTerms {
                    // Exact match or contains (case-insensitive).
                    if name.localizedCaseInsensitiveContains(term) {
                        return true
                    }
                    // Group Containers use format: "*.{bundleID-component}"
                    if category == .groupContainers,
                       let bid = bundleID,
                       let teamGroup = bid.split(separator: ".").last,
                       name.contains(String(teamGroup)) {
                        return true
                    }
                }
                return false
            }()

            if matches {
                let size = directorySize(at: itemURL)
                let item = LibraryItem(
                    id: "\(category.rawValue):\(itemURL.path)",
                    url: itemURL,
                    category: category,
                    sizeBytes: size
                )
                results.append(item)
            }
        }

        return results
    }

    private func scanPreferences(searchTerms: [String], bundleID: String?) -> [LibraryItem] {
        let prefsDir = homeLibrary.appendingPathComponent("Preferences")
        guard let contents = try? fileManager.contentsOfDirectory(
            at: prefsDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [LibraryItem] = []

        for fileURL in contents where fileURL.pathExtension == "plist" {
            let name = fileURL.deletingPathExtension().lastPathComponent

            for term in searchTerms {
                if name.localizedCaseInsensitiveContains(term) {
                    let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                        .flatMap { UInt64($0) } ?? 0
                    results.append(LibraryItem(
                        id: "Preferences:\(fileURL.path)",
                        url: fileURL,
                        category: .preferences,
                        sizeBytes: size
                    ))
                    break
                }
            }
        }

        return results
    }

    // MARK: - Helpers

    /// Recursively compute directory size using native API.
    private func directorySize(at url: URL) -> UInt64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            // Single file?
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
