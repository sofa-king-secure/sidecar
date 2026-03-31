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
        print("[Sidecar] Drive reconnected — restoring symlinks.")

        stopAppLaunchMonitor()

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
