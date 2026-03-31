import AppKit
import Foundation
import SwiftUI

/// Application entry point (v0.3).
///
/// Changes from v0.2:
///   - Removed WindowGroup for onboarding (caused window lifecycle issues)
///   - Onboarding now opens as a standalone NSWindow
///   - Scan & Recommend shows per-item selection
///   - Uses sub-directory migration strategy

@main
struct ProjectSidecarApp: App {

    @StateObject private var appState = SidecarAppState()

    var body: some Scene {
        MenuBarExtra("Sidecar", systemImage: appState.menuBarIcon) {
            VStack(alignment: .leading, spacing: 4) {
                Text(appState.statusLabel)
                    .font(.headline)

                if let diskInfo = appState.diskInfoLabel {
                    Text(diskInfo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let migrated = appState.migratedCountLabel {
                    Text(migrated)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Divider()

            Button("Scan & Migrate...") {
                Task { await appState.runScanAndMigrate() }
            }
            .disabled(appState.status == .driveMissing)

            Button("View Status & Health...") {
                appState.showStatus()
            }

            Divider()

            Menu("Settings") {
                Toggle("Auto-prompt for new apps", isOn: $appState.autoMigrate)
                Toggle("Launch at login", isOn: $appState.launchAtLogin)

                Divider()

                Button("Reset Configuration...") {
                    appState.resetOnboarding()
                }
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

// MARK: - Application State

@MainActor
final class SidecarAppState: ObservableObject {

    @Published var status: Status = .idle
    @Published var diskInfoLabel: String?
    @Published var migratedCountLabel: String?

    @Published var autoMigrate: Bool {
        didSet { SidecarConfig.shared.updatePreferences { $0.autoMigrateNewApps = autoMigrate } }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            SidecarConfig.shared.updatePreferences { $0.launchAtLogin = launchAtLogin }
            updateLaunchAgent(enabled: launchAtLogin)
        }
    }

    enum Status {
        case active, idle, driveMissing, scanning, needsSetup
    }

    var menuBarIcon: String {
        switch status {
        case .active:       return "externaldrive.fill.badge.checkmark"
        case .idle:         return "externaldrive.fill"
        case .driveMissing: return "externaldrive.fill.badge.xmark"
        case .scanning:     return "externaldrive.fill.badge.questionmark"
        case .needsSetup:   return "externaldrive.badge.plus"
        }
    }

    var statusLabel: String {
        switch status {
        case .active:       return "Status: Active"
        case .idle:         return "Status: Idle"
        case .driveMissing: return "Status: Drive Missing"
        case .scanning:     return "Status: Scanning..."
        case .needsSetup:   return "Status: Setup Required"
        }
    }

    // MARK: Components

    private var directoryMonitor: DirectoryMonitor?
    private var volumeMonitor: VolumeMonitor?
    private let manifest: MigrationManifest
    private let migrator: AppMigrator
    private let disconnectGuard: DisconnectGuard
    private let libraryScanner = LibraryScanner()
    private let diskAnalyzer = DiskAnalyzer()
    private let config = SidecarConfig.shared

    init() {
        let manifest = MigrationManifest()
        self.manifest = manifest
        self.migrator = AppMigrator(manifest: manifest)
        self.disconnectGuard = DisconnectGuard(manifest: manifest)

        let prefs = SidecarConfig.shared.state.preferences
        self.autoMigrate = prefs.autoMigrateNewApps
        self.launchAtLogin = prefs.launchAtLogin

        if SidecarConfig.shared.needsOnboarding {
            status = .needsSetup
            // Open onboarding as a standalone window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.openOnboardingWindow()
            }
        } else {
            NSApp.setActivationPolicy(.accessory)
            startMonitoring()
        }
    }

    // MARK: - Onboarding Window

    private var onboardingWindow: NSWindow?

    func openOnboardingWindow() {
        if let existing = onboardingWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = OnboardingView(config: SidecarConfig.shared) { [weak self] in
            self?.onboardingCompleted()
        }

        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Sidecar Setup"
        window.setContentSize(NSSize(width: 600, height: 520))
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.onboardingWindow = window
    }

    func onboardingCompleted() {
        onboardingWindow?.close()
        onboardingWindow = nil
        NSApp.setActivationPolicy(.accessory)
        startMonitoring()
        print("[Sidecar] ✅ Setup complete. Monitoring /Applications for new installs.")
    }

    func resetOnboarding() {
        directoryMonitor?.stop()
        volumeMonitor?.stop()
        config.reset()
        status = .needsSetup
        openOnboardingWindow()
    }

    // MARK: - Start Monitoring

    private func startMonitoring() {
        guard let volumeName = config.configuredVolumeName else {
            status = .needsSetup
            openOnboardingWindow()
            return
        }

        setupVolumeMonitor(volumeName: volumeName)
        setupDirectoryMonitor()
        updateDiskInfo()
        updateMigratedCount()
    }

    private func setupVolumeMonitor(volumeName: String) {
        volumeMonitor = VolumeMonitor(
            volumeName: volumeName
        ) { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .mounted:
                    self.status = .active
                    self.disconnectGuard.onDriveReconnected()
                    try? self.directoryMonitor?.start()
                    self.runHealthCheck()
                case .missing:
                    self.status = .driveMissing
                    self.directoryMonitor?.stop()
                    self.disconnectGuard.onDriveDisconnected()
                }
            }
        }
        volumeMonitor?.start()

        if case .mounted = volumeMonitor?.state {
            status = .active
        } else {
            status = .driveMissing
        }
    }

    private func setupDirectoryMonitor() {
        directoryMonitor = DirectoryMonitor { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .appAdded(let url):
                    await self.handleNewApp(url)
                case .error(let error):
                    print("[Sidecar] Monitor error: \(error)")
                }
            }
        }

        if case .mounted = volumeMonitor?.state {
            try? directoryMonitor?.start()
        }
    }

    // MARK: - New App Detected

    private func handleNewApp(_ appURL: URL) async {
        guard config.state.preferences.autoMigrateNewApps else { return }
        guard let volumeState = volumeMonitor?.state,
              case .mounted(let volumePath) = volumeState else { return }

        let result = libraryScanner.scanApp(appURL: appURL)

        guard !result.migratableItems.isEmpty else { return }

        print("[Sidecar] New app detected: \(result.appName) (\(result.formattedMigratableSize) migratable)")

        let shouldMigrate = await promptNewApp(result: result)
        guard shouldMigrate else { return }

        do {
            try await migrator.migrateItems(
                appName: result.appName,
                bundleIdentifier: result.bundleIdentifier,
                items: result.migratableItems,
                externalBase: volumePath,
                progressHandler: { progress in
                    print("[Sidecar] \(progress.phase): \(progress.detail)")
                }
            )
            updateMigratedCount()
            updateDiskInfo()
        } catch {
            print("[Sidecar] Migration failed: \(error)")
        }
    }

    // MARK: - Scan & Migrate (Manual)

    func runScanAndMigrate() async {
        guard let volumeState = volumeMonitor?.state,
              case .mounted(let volumePath) = volumeState else { return }

        status = .scanning

        let results = await libraryScanner.scanAllApps()

        print("[Sidecar] Scan found \(results.count) app(s) with migratable data:")
        for r in results {
            print("[Sidecar]   \(r.appName): \(r.migratableItems.count) items, \(r.formattedMigratableSize)")
            for item in r.migratableItems {
                print("[Sidecar]     \(item.displayName): \(item.formattedSize)")
            }
        }

        status = .active

        if results.isEmpty {
            showAlert(
                title: "All Clear",
                message: "No apps have subdirectories large enough to migrate (minimum 10 MB per item, 50 MB per app)."
            )
            return
        }

        // Build per-item selection dialog.
        let selectedItems = await promptItemSelection(results: results)

        guard !selectedItems.isEmpty else { return }

        // Group selected items by app.
        let grouped = Dictionary(grouping: selectedItems) { $0.parentAppName }

        for (appName, items) in grouped {
            let bundleID = items.first?.bundleIdentifier
            do {
                try await migrator.migrateItems(
                    appName: appName,
                    bundleIdentifier: bundleID,
                    items: items,
                    externalBase: volumePath,
                    progressHandler: { progress in
                        print("[Sidecar] \(progress.phase): \(progress.detail)")
                    }
                )
            } catch {
                print("[Sidecar] Failed: \(appName): \(error)")
            }
        }

        updateMigratedCount()
        updateDiskInfo()
    }

    // MARK: - Status & Health Check

    func showStatus() {
        let driveConnected: Bool
        let driveName: String

        if case .mounted = volumeMonitor?.state {
            driveConnected = true
        } else {
            driveConnected = false
        }
        driveName = config.configuredVolumeName ?? "Unknown"

        let diskState = diskAnalyzer.currentDiskState()

        showStatusWindow(
            manifest: manifest,
            driveName: driveName,
            driveConnected: driveConnected,
            diskState: diskState
        )
    }

    func runHealthCheck() {
        let issues = manifest.healthCheck()
        if issues.isEmpty {
            print("[Sidecar] Health check: all migrations healthy.")
            return
        }
        for issue in issues {
            print("[Sidecar] ⚠️ \(issue.appName): \(issue.type) at \(issue.itemPath)")
        }
    }

    // MARK: - UI Helpers

    private func updateDiskInfo() {
        let state = diskAnalyzer.currentDiskState()
        diskInfoLabel = "\(state.formattedAvailable) free of \(state.formattedTotal) (\(Int(state.usedPercentage))% used)"
    }

    private func updateMigratedCount() {
        let count = manifest.activeRecords.count
        migratedCountLabel = count > 0 ? "\(count) app(s) with migrated data" : nil
    }

    // MARK: - Dialogs

    private func promptNewApp(result: LibraryScanner.AppScanResult) async -> Bool {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = "Migrate \(result.appName) data to external drive?"
            alert.informativeText = """
                Found \(result.migratableItems.count) heavy folder(s) totaling \(result.formattedMigratableSize).
                The app itself stays in /Applications — only data folders move.
                The app will work normally with or without the drive connected.
                """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Migrate")
            alert.addButton(withTitle: "Skip")
            continuation.resume(returning: alert.runModal() == .alertFirstButtonReturn)
        }
    }

    /// Show a checklist of all migratable items across all apps.
    private func promptItemSelection(
        results: [LibraryScanner.AppScanResult]
    ) async -> [LibraryScanner.MigratableItem] {
        await showMigrationPicker(results: results)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Launch at Login

    private func updateLaunchAgent(enabled: Bool) {
        let bundleID = "com.projectsidecar.app"
        let launchAgentDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
        let plistPath = launchAgentDir.appendingPathComponent("\(bundleID).plist")
        let appPath = "/Applications/Sidecar.app/Contents/MacOS/Sidecar"
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ProjectSidecar")

        if enabled {
            // Create LaunchAgent plist
            try? FileManager.default.createDirectory(at: launchAgentDir, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

            let plist: [String: Any] = [
                "Label": bundleID,
                "ProgramArguments": [appPath],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive",
                "StandardOutPath": logDir.appendingPathComponent("sidecar.log").path,
                "StandardErrorPath": logDir.appendingPathComponent("sidecar-error.log").path
            ]

            let data = try? PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try? data?.write(to: plistPath)

            // Load it
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["load", plistPath.path]
            try? process.run()
            process.waitUntilExit()

            print("[Sidecar] ✅ Launch at Login enabled.")
        } else {
            // Unload and remove
            if FileManager.default.fileExists(atPath: plistPath.path) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                process.arguments = ["unload", plistPath.path]
                try? process.run()
                process.waitUntilExit()

                try? FileManager.default.removeItem(at: plistPath)
            }
            print("[Sidecar] Launch at Login disabled.")
        }
    }
}
