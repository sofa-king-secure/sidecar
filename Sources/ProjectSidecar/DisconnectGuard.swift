import AppKit
import Foundation

/// Protects migrated apps when the external drive is disconnected.
///
/// When the drive unmounts:
///   1. Replaces dead symlinks with empty placeholder directories
///      so apps can launch without crashing.
///   2. Monitors for launches of migrated apps and warns the user.
///
/// When the drive reconnects:
///   1. Removes placeholder directories (if unchanged).
///   2. Restores symlinks to the external drive.
///   3. If the app wrote new data while disconnected, merges it back.
///
/// This is the safety net that makes library-only migration viable.
final class DisconnectGuard {

    // MARK: - Types

    /// State of a placeholder directory.
    struct PlaceholderInfo: Codable {
        let originalSymlinkTarget: String  // Where the symlink pointed
        let localPath: String              // The placeholder directory path
        let appName: String
        let createdAt: Date
        var wasModified: Bool              // Did the app write data while disconnected?
    }

    enum GuardAction: Sendable {
        case continueWithoutData  // User accepts running without their data
        case quitApp              // User wants to quit and connect drive
        case cancel               // Don't launch
    }

    // MARK: - Properties

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

    // MARK: - Init

    init(manifest: MigrationManifest) {
        self.manifest = manifest
        loadPlaceholders()
    }

    // MARK: - Public API: Drive Disconnected

    /// Called when the external drive unmounts.
    /// Replaces dead symlinks with empty placeholder directories
    /// and starts monitoring for migrated app launches.
    func onDriveDisconnected() {
        print("[Sidecar] Drive disconnected — activating disconnect guard.")

        let activeRecords = manifest.activeRecords

        for record in activeRecords {
            for libMigration in record.libraryMigrations where libMigration.isSymlinked {
                let localPath = libMigration.originalPath
                let targetPath = libMigration.externalPath

                // Check if it's a dead symlink (points to unmounted volume).
                if isDeadSymlink(at: localPath) {
                    do {
                        // Remove the dead symlink.
                        try fileManager.removeItem(atPath: localPath)

                        // Create an empty placeholder directory.
                        try fileManager.createDirectory(
                            atPath: localPath,
                            withIntermediateDirectories: true,
                            attributes: nil
                        )

                        let info = PlaceholderInfo(
                            originalSymlinkTarget: targetPath,
                            localPath: localPath,
                            appName: record.appName,
                            createdAt: Date(),
                            wasModified: false
                        )
                        placeholders.append(info)

                        print("[Sidecar] Created placeholder: \(localPath)")
                    } catch {
                        print("[Sidecar] Failed to create placeholder for \(localPath): \(error)")
                    }
                }
            }
        }

        savePlaceholders()
        startAppLaunchMonitor()
    }

    /// Called when the external drive reconnects.
    /// Restores symlinks and handles any data written during disconnect.
    func onDriveReconnected() {
        print("[Sidecar] Drive reconnected — restoring symlinks.")

        stopAppLaunchMonitor()

        for (index, placeholder) in placeholders.enumerated() {
            let localPath = placeholder.localPath
            let targetPath = placeholder.originalSymlinkTarget

            // Check if the placeholder directory was modified.
            let modified = directoryHasContents(at: localPath)

            if modified {
                placeholders[index].wasModified = true
                print("[Sidecar] ⚠️ Data written while disconnected: \(localPath)")

                // Move the locally-written data to a temp location for merge.
                let tempPath = localPath + ".sidecar-disconnected"
                do {
                    try fileManager.moveItem(atPath: localPath, toPath: tempPath)

                    // Restore the symlink.
                    try fileManager.createSymbolicLink(
                        atPath: localPath,
                        withDestinationPath: targetPath
                    )

                    // Merge: copy disconnected data into the external location.
                    if fileManager.fileExists(atPath: targetPath) {
                        try mergeDirectories(from: tempPath, into: targetPath)
                    }

                    // Clean up temp.
                    try? fileManager.removeItem(atPath: tempPath)

                    print("[Sidecar] ✅ Merged disconnected data and restored: \(localPath)")
                } catch {
                    print("[Sidecar] ❌ Failed to restore \(localPath): \(error)")
                }
            } else {
                // Placeholder was empty — just remove and restore symlink.
                do {
                    try fileManager.removeItem(atPath: localPath)
                    try fileManager.createSymbolicLink(
                        atPath: localPath,
                        withDestinationPath: targetPath
                    )
                    print("[Sidecar] ✅ Restored symlink: \(localPath)")
                } catch {
                    print("[Sidecar] ❌ Failed to restore symlink \(localPath): \(error)")
                }
            }
        }

        placeholders.removeAll()
        savePlaceholders()
    }

    // MARK: - App Launch Monitoring

    /// Watch for app launches. If a migrated app starts while the drive
    /// is disconnected, warn the user.
    private func startAppLaunchMonitor() {
        let center = NSWorkspace.shared.notificationCenter

        appMonitor = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }

            // Check if this is a migrated app.
            if let record = self.manifest.record(forBundleID: bundleID) {
                let hasPlaceholders = self.placeholders.contains { $0.appName == record.appName }
                if hasPlaceholders {
                    Task { @MainActor in
                        await self.showDisconnectWarning(for: record, runningApp: app)
                    }
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

    /// Show the disconnect warning when a migrated app launches without the drive.
    @MainActor
    private func showDisconnectWarning(
        for record: MigrationManifest.MigrationRecord,
        runningApp: NSRunningApplication
    ) async {
        let appName = record.appName.replacingOccurrences(of: ".app", with: "")
        let libCount = record.libraryMigrations.filter { $0.isSymlinked }.count

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSImage(systemSymbolName: "externaldrive.trianglebadge.exclamationmark",
                            accessibilityDescription: "Drive missing")

        alert.messageText = "\(appName) is running without its data"
        alert.informativeText = """
            You migrated \(libCount) Library folder(s) for \(appName) to your \
            external drive, but the drive isn't connected.

            The app is running with empty placeholder data. Your settings, \
            extensions, and cached data are on the external drive.

            Options:
            • Quit \(appName), connect the drive, and relaunch for full access
            • Continue — the app may behave like a fresh install. \
            Any changes will be synced when the drive reconnects, \
            but you may lose some session data
            """

        alert.addButton(withTitle: "Quit \(appName)")        // First button
        alert.addButton(withTitle: "Continue Without Data")   // Second button

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            // Quit the app.
            runningApp.terminate()
            print("[Sidecar] User chose to quit \(appName).")
        default:
            // User accepts the risk.
            print("[Sidecar] User continuing \(appName) without external data.")
        }
    }

    // MARK: - Helpers

    /// Check if a path is a symlink pointing to a non-existent target.
    private func isDeadSymlink(at path: String) -> Bool {
        // Check if it's a symlink.
        var isSymlink = false
        if let attrs = try? fileManager.attributesOfItem(atPath: path),
           let type = attrs[.type] as? FileAttributeType,
           type == .typeSymbolicLink {
            isSymlink = true
        }

        guard isSymlink else { return false }

        // Check if target exists.
        let target = try? fileManager.destinationOfSymbolicLink(atPath: path)
        if let target {
            return !fileManager.fileExists(atPath: target)
        }
        return true
    }

    /// Check if a directory has any files in it.
    private func directoryHasContents(at path: String) -> Bool {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: path) else {
            return false
        }
        // Filter out .DS_Store and other macOS cruft.
        let meaningful = contents.filter { !$0.hasPrefix(".") }
        return !meaningful.isEmpty
    }

    /// Merge contents of one directory into another.
    /// Files in `from` overwrite files in `into` if they exist.
    private func mergeDirectories(from sourcePath: String, into destPath: String) throws {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let destURL = URL(fileURLWithPath: destPath)

        guard let contents = try? fileManager.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for itemURL in contents {
            let destItemURL = destURL.appendingPathComponent(itemURL.lastPathComponent)

            if fileManager.fileExists(atPath: destItemURL.path) {
                // Replace with the newer disconnected version.
                try fileManager.removeItem(at: destItemURL)
            }
            try fileManager.moveItem(at: itemURL, to: destItemURL)
        }
    }

    // MARK: - Persistence

    private func savePlaceholders() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
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
