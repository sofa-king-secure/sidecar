import AppKit
import Foundation

/// Protects migrated sub-directories when the external drive is disconnected.
///
/// On disconnect: replaces dead symlinks with empty placeholder directories.
/// On app launch without drive: warns the user with options.
/// On reconnect: restores symlinks, merges any locally-written data.
final class DisconnectGuard {

    struct PlaceholderInfo: Codable {
        let originalSymlinkTarget: String
        let localPath: String
        let appName: String
        let createdAt: Date
        var wasModified: Bool
    }

    private let manifest: MigrationManifest
    private let fileManager = FileManager.default
    private var placeholders: [PlaceholderInfo] = []
    private var appMonitor: NSObjectProtocol?

    private let placeholderManifestURL: URL = {
        let dir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("ProjectSidecar")
        return dir.appendingPathComponent("placeholders.json")
    }()

    init(manifest: MigrationManifest) {
        self.manifest = manifest
        loadPlaceholders()
    }

    // MARK: - Drive Disconnected

    func onDriveDisconnected() {
        print("[Sidecar] Drive disconnected — creating placeholders for dead symlinks.")

        let activeRecords = manifest.activeRecords

        for record in activeRecords {
            for lib in record.libraryMigrations where lib.isSymlinked {
                if isDeadSymlink(at: lib.originalPath) {
                    do {
                        try fileManager.removeItem(atPath: lib.originalPath)
                        try fileManager.createDirectory(
                            atPath: lib.originalPath,
                            withIntermediateDirectories: true,
                            attributes: nil
                        )
                        placeholders.append(PlaceholderInfo(
                            originalSymlinkTarget: lib.externalPath,
                            localPath: lib.originalPath,
                            appName: record.appName,
                            createdAt: Date(),
                            wasModified: false
                        ))
                        print("[Sidecar]   Placeholder: \(lib.originalPath)")
                    } catch {
                        print("[Sidecar]   Failed: \(lib.originalPath): \(error)")
                    }
                }
            }
        }

        savePlaceholders()
        startAppLaunchMonitor()
    }

    // MARK: - Drive Reconnected

    func onDriveReconnected() {
        print("[Sidecar] Drive reconnected — restoring symlinks and cleaning up.")

        stopAppLaunchMonitor()

        // Step 1: Handle known placeholders (from this session's disconnect).
        for (index, ph) in placeholders.enumerated() {
            let modified = directoryHasContents(at: ph.localPath)

            if modified {
                placeholders[index].wasModified = true
                let tempPath = ph.localPath + ".sidecar-disconnected"
                do {
                    try fileManager.moveItem(atPath: ph.localPath, toPath: tempPath)
                    try fileManager.createSymbolicLink(atPath: ph.localPath, withDestinationPath: ph.originalSymlinkTarget)
                    if fileManager.fileExists(atPath: ph.originalSymlinkTarget) {
                        try mergeDirectories(from: tempPath, into: ph.originalSymlinkTarget)
                    }
                    try? fileManager.removeItem(atPath: tempPath)
                    print("[Sidecar]   ✅ Merged + restored: \(ph.localPath)")
                } catch {
                    print("[Sidecar]   ❌ Failed to restore \(ph.localPath): \(error)")
                }
            } else {
                do {
                    try fileManager.removeItem(atPath: ph.localPath)
                    try fileManager.createSymbolicLink(atPath: ph.localPath, withDestinationPath: ph.originalSymlinkTarget)
                    print("[Sidecar]   ✅ Restored: \(ph.localPath)")
                } catch {
                    print("[Sidecar]   ❌ Failed: \(ph.localPath): \(error)")
                }
            }
        }

        placeholders.removeAll()
        savePlaceholders()

        // Step 2: Full reconnect cleanup — check ALL manifest items.
        // This catches cases where Sidecar wasn't running during disconnect,
        // or where an app recreated directories locally.
        reconnectCleanup()
    }

    /// Scans all active manifest items and ensures symlinks are correct.
    /// If a local real directory exists where a symlink should be:
    ///   - Merges any new local data into the external copy
    ///   - Removes the local directory
    ///   - Recreates the symlink
    /// Also removes empty placeholder directories left behind.
    func reconnectCleanup() {
        let activeRecords = manifest.activeRecords
        var cleanedCount = 0
        var bytesReclaimed: UInt64 = 0

        for record in activeRecords {
            for lib in record.libraryMigrations where lib.isSymlinked {
                let localPath = lib.originalPath
                let externalPath = lib.externalPath

                // Skip if it's already a working symlink.
                if isWorkingSymlink(at: localPath, expectedTarget: externalPath) {
                    continue
                }

                // Check if external target exists (drive is connected and data is there).
                guard fileManager.fileExists(atPath: externalPath) else {
                    print("[Sidecar] Cleanup: external target missing for \(localPath) — skipping.")
                    continue
                }

                // Case 1: Local path is a real directory (app recreated it).
                if !isSymlink(at: localPath) && fileManager.fileExists(atPath: localPath) {
                    let localSize = directorySize(at: localPath)
                    print("[Sidecar] Cleanup: local duplicate found at \(localPath) (\(formatBytes(localSize)))")

                    let tempPath = localPath + ".sidecar-cleanup"
                    do {
                        // Move local to temp.
                        try fileManager.moveItem(atPath: localPath, toPath: tempPath)

                        // Restore symlink.
                        try fileManager.createSymbolicLink(
                            atPath: localPath,
                            withDestinationPath: externalPath
                        )

                        // Merge any new data from local into external.
                        try mergeDirectories(from: tempPath, into: externalPath)

                        // Remove temp.
                        try fileManager.removeItem(atPath: tempPath)

                        bytesReclaimed += localSize
                        cleanedCount += 1
                        print("[Sidecar]   ✅ Cleaned: \(localPath) — \(formatBytes(localSize)) reclaimed")
                    } catch {
                        print("[Sidecar]   ❌ Cleanup failed for \(localPath): \(error)")
                        // Try to restore original state.
                        if !fileManager.fileExists(atPath: localPath),
                           fileManager.fileExists(atPath: tempPath) {
                            try? fileManager.moveItem(atPath: tempPath, toPath: localPath)
                        }
                    }
                }

                // Case 2: Dead symlink (shouldn't happen if drive is connected, but just in case).
                if isDeadSymlink(at: localPath) {
                    do {
                        try fileManager.removeItem(atPath: localPath)
                        try fileManager.createSymbolicLink(
                            atPath: localPath,
                            withDestinationPath: externalPath
                        )
                        cleanedCount += 1
                        print("[Sidecar]   ✅ Fixed dead symlink: \(localPath)")
                    } catch {
                        print("[Sidecar]   ❌ Failed to fix symlink: \(localPath): \(error)")
                    }
                }
            }
        }

        if cleanedCount > 0 {
            print("[Sidecar] Reconnect cleanup: \(cleanedCount) item(s) cleaned, \(formatBytes(bytesReclaimed)) reclaimed.")
        } else {
            print("[Sidecar] Reconnect cleanup: all items clean.")
        }
    }

    // MARK: - App Launch Monitor

    private func startAppLaunchMonitor() {
        let center = NSWorkspace.shared.notificationCenter
        appMonitor = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier,
                  let record = self.manifest.record(forBundleID: bundleID) else { return }

            let hasPlaceholders = self.placeholders.contains { $0.appName == record.appName }
            if hasPlaceholders {
                Task { @MainActor in
                    await self.showDisconnectWarning(for: record, runningApp: app)
                }
            }
        }
    }

    private func stopAppLaunchMonitor() {
        if let monitor = appMonitor {
            NSWorkspace.shared.notificationCenter.removeObserver(monitor)
            appMonitor = nil
        }
    }

    // MARK: - Warning Dialog

    @MainActor
    private func showDisconnectWarning(
        for record: MigrationManifest.MigrationRecord,
        runningApp: NSRunningApplication
    ) async {
        let appName = record.appName.replacingOccurrences(of: ".app", with: "")
        let itemCount = record.libraryMigrations.filter { $0.isSymlinked }.count

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSImage(systemSymbolName: "externaldrive.trianglebadge.exclamationmark",
                            accessibilityDescription: "Drive missing")

        alert.messageText = "\(appName) — external drive not connected"
        alert.informativeText = """
            \(itemCount) data folder(s) for \(appName) live on your external drive, \
            which isn't connected.

            The app is running with empty placeholder data. Your settings should \
            be fine, but cached data, extensions, and VM bundles may be missing.

            • Quit and connect the drive for full functionality
            • Continue — changes will sync when the drive reconnects
            """

        alert.addButton(withTitle: "Quit \(appName)")
        alert.addButton(withTitle: "Continue Without Data")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            runningApp.terminate()
            print("[Sidecar] User quit \(appName).")
        } else {
            print("[Sidecar] User continuing \(appName) without external data.")
        }
    }

    // MARK: - Helpers

    private func isDeadSymlink(at path: String) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let type = attrs[.type] as? FileAttributeType,
              type == .typeSymbolicLink else { return false }
        let target = try? fileManager.destinationOfSymbolicLink(atPath: path)
        return target.map { !fileManager.fileExists(atPath: $0) } ?? true
    }

    private func isSymlink(at path: String) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let type = attrs[.type] as? FileAttributeType else { return false }
        return type == .typeSymbolicLink
    }

    /// Check if a path is a working symlink pointing to the expected target.
    private func isWorkingSymlink(at path: String, expectedTarget: String) -> Bool {
        guard isSymlink(at: path) else { return false }
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: path) else { return false }
        return target == expectedTarget && fileManager.fileExists(atPath: target)
    }

    private func directorySize(at path: String) -> UInt64 {
        let url = URL(fileURLWithPath: path)
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [],
            errorHandler: nil
        ) else { return 0 }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            total += UInt64(size)
        }
        return total
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func directoryHasContents(at path: String) -> Bool {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: path) else { return false }
        return contents.contains { !$0.hasPrefix(".") }
    }

    private func mergeDirectories(from source: String, into dest: String) throws {
        let sourceURL = URL(fileURLWithPath: source)
        let destURL = URL(fileURLWithPath: dest)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: sourceURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }

        for item in contents {
            let destItem = destURL.appendingPathComponent(item.lastPathComponent)
            if fileManager.fileExists(atPath: destItem.path) {
                try fileManager.removeItem(at: destItem)
            }
            try fileManager.moveItem(at: item, to: destItem)
        }
    }

    private func savePlaceholders() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(placeholders) else { return }
        try? data.write(to: placeholderManifestURL, options: .atomic)
    }

    private func loadPlaceholders() {
        guard let data = try? Data(contentsOf: placeholderManifestURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        placeholders = (try? decoder.decode([PlaceholderInfo].self, from: data)) ?? []
    }
}
