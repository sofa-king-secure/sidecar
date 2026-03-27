import AppKit
import Foundation
import SwiftUI

/// Application entry point.
///
/// Launch flow:
///   1. Check SidecarConfig — has onboarding completed?
///   2. If NOT → show OnboardingView (setup wizard)
///   3. If YES → start menu bar app with monitoring
///
/// Architecture:
///   SidecarConfig    → persistent settings, drive history, first-run flag
///   DriveSetup       → discover volumes, validate filesystem, initialize
///   OnboardingView   → 5-step SwiftUI wizard (welcome → drive → check → scan → done)
///   DirectoryMonitor → detects new .app in /Applications
///   AppFilter        → rejects Apple/system apps
///   LibraryScanner   → discovers full disk footprint (app + ~/Library data)
///   DiskAnalyzer     → scores and prioritizes by size & disk pressure
///   AppMigrator      → moves files + creates symlinks + records manifest
///   MigrationManifest→ tracks everything for rollback & health checks
///   VolumeMonitor    → pauses everything when drive disconnects

@main
struct ProjectSidecarApp: App {

    @StateObject private var appState = SidecarAppState()

    var body: some Scene {
        // Onboarding window — always declared, visibility controlled by appState.
        WindowGroup("Sidecar Setup", id: "onboarding") {
            OnboardingView(config: SidecarConfig.shared) {
                appState.onboardingCompleted()
            }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Menu bar — always present, but functional only after onboarding.
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

            if appState.showOnboarding {
                Button("Complete Setup...") {
                    // Re-focus onboarding window.
                    NSApp.activate(ignoringOtherApps: true)
                }
            } else {
                Button("Scan & Recommend...") {
                    Task { await appState.runFullScan() }
                }
                .disabled(appState.status == .driveMissing)

                Button("Health Check") {
                    appState.runHealthCheck()
                }

                Divider()

                Menu("Settings") {
                    Toggle("Auto-migrate new apps", isOn: $appState.autoMigrate)
                    Toggle("Migrate Library data", isOn: $appState.migrateLibrary)
                    Toggle("Launch at login", isOn: $appState.launchAtLogin)

                    Divider()

                    Button("Reset & Re-run Setup...") {
                        appState.resetOnboarding()
                    }
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

    // MARK: Published

    @Published var status: Status = .idle
    @Published var diskInfoLabel: String?
    @Published var migratedCountLabel: String?
    @Published var showOnboarding: Bool

    @Published var autoMigrate: Bool {
        didSet {
            SidecarConfig.shared.updatePreferences { $0.autoMigrateNewApps = autoMigrate }
        }
    }
    @Published var migrateLibrary: Bool {
        didSet {
            SidecarConfig.shared.updatePreferences { $0.migrateLibraryData = migrateLibrary }
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            SidecarConfig.shared.updatePreferences { $0.launchAtLogin = launchAtLogin }
            // TODO: Actually register/unregister the LaunchAgent plist.
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
    private let manifest = MigrationManifest()
    private lazy var migrator = AppMigrator(manifest: manifest)
    private let libraryScanner = LibraryScanner()
    private let diskAnalyzer = DiskAnalyzer()
    private let config = SidecarConfig.shared

    // MARK: Init

    init() {
        let prefs = SidecarConfig.shared.state.preferences
        self.showOnboarding = SidecarConfig.shared.needsOnboarding
        self.autoMigrate = prefs.autoMigrateNewApps
        self.migrateLibrary = prefs.migrateLibraryData
        self.launchAtLogin = prefs.launchAtLogin

        if showOnboarding {
            status = .needsSetup
        } else {
            // No onboarding needed — run as menu bar only (no Dock icon).
            NSApp.setActivationPolicy(.accessory)
            startMonitoring()
        }
    }

    // MARK: - Onboarding

    func onboardingCompleted() {
        showOnboarding = false
        // Hide from Dock — this is a menu bar app.
        NSApp.setActivationPolicy(.accessory)
        startMonitoring()
        print("[Sidecar] ✅ Setup complete. Monitoring /Applications for new installs.")
        print("[Sidecar] Look for the drive icon in your menu bar.")
    }

    func resetOnboarding() {
        directoryMonitor?.stop()
        volumeMonitor?.stop()
        config.reset()
        showOnboarding = true
        status = .needsSetup
    }

    // MARK: - Start Monitoring (post-onboarding)

    private func startMonitoring() {
        guard let volumeName = config.configuredVolumeName else {
            status = .needsSetup
            return
        }

        setupVolumeMonitor(volumeName: volumeName)
        setupDirectoryMonitor()
        updateDiskInfo()
        updateMigratedCount()
    }

    // MARK: - Setup

    private func setupVolumeMonitor(volumeName: String) {
        volumeMonitor = VolumeMonitor(
            volumeName: volumeName
        ) { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .mounted:
                    self.status = .active
                    try? self.directoryMonitor?.start()
                    if self.config.preferences.runHealthCheckOnMount {
                        self.runHealthCheck()
                    }
                case .missing:
                    self.status = .driveMissing
                    self.directoryMonitor?.stop()
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
        guard let volumeState = volumeMonitor?.state,
              case .mounted(let volumePath) = volumeState else {
            return
        }

        let footprint = await libraryScanner.scanFootprint(for: appURL)
        let state = diskAnalyzer.currentDiskState()
        let candidates = diskAnalyzer.prioritize(footprints: [footprint], diskState: state)

        guard let candidate = candidates.first else { return }

        // Respect auto-migrate preference.
        if config.preferences.autoMigrateNewApps {
            let shouldProceed = await promptMigration(candidate: candidate)
            guard shouldProceed else { return }
        } else {
            return  // Silent mode — user will run manual scans.
        }

        do {
            try await migrator.migrateFullFootprint(
                footprint: footprint,
                externalBase: volumePath,
                conflictHandler: { [weak self] url in
                    guard let self else { return .skip }
                    return await self.promptConflictResolution(for: url)
                },
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

    // MARK: - Full Scan (Manual)

    func runFullScan() async {
        guard let volumeState = volumeMonitor?.state,
              case .mounted(let volumePath) = volumeState else { return }

        status = .scanning

        let footprints = await libraryScanner.scanAllApps()
        let state = diskAnalyzer.currentDiskState()
        let candidates = diskAnalyzer.prioritize(footprints: footprints, diskState: state)
        let plan = diskAnalyzer.recommendMigrationPlan(candidates: candidates, diskState: state)

        status = .active

        if plan.toMigrate.isEmpty {
            showAlert(
                title: "All Clear",
                message: "No apps meet the migration threshold, or disk space is sufficient."
            )
            return
        }

        let totalReclaimable = plan.toMigrate.reduce(0) { $0 + $1.reclaimableBytes }
        let formatted = ByteCountFormatter.string(fromByteCount: Int64(totalReclaimable), countStyle: .file)
        let appList = plan.toMigrate
            .map { "• \($0.footprint.appBundleURL.deletingPathExtension().lastPathComponent) (\($0.formattedReclaimable))" }
            .joined(separator: "\n")

        let proceed = await promptScanResults(
            message: "Found \(plan.toMigrate.count) app(s) to migrate, freeing ~\(formatted):\n\n\(appList)"
        )

        guard proceed else { return }

        for candidate in plan.toMigrate {
            do {
                try await migrator.migrateFullFootprint(
                    footprint: candidate.footprint,
                    externalBase: volumePath,
                    conflictHandler: { [weak self] url in
                        guard let self else { return .skip }
                        return await self.promptConflictResolution(for: url)
                    },
                    progressHandler: { progress in
                        print("[Sidecar] \(progress.phase): \(progress.detail)")
                    }
                )
            } catch {
                print("[Sidecar] Failed: \(candidate.footprint.appBundleURL.lastPathComponent): \(error)")
            }
        }

        updateMigratedCount()
        updateDiskInfo()
    }

    // MARK: - Health Check

    func runHealthCheck() {
        let issues = manifest.healthCheck()

        if issues.isEmpty {
            print("[Sidecar] Health check: all migrations healthy.")
            return
        }

        for issue in issues {
            switch issue.type {
            case .symlinkMissing:
                print("[Sidecar] ⚠️ \(issue.appName): symlink missing.")
            case .targetUnreachable:
                print("[Sidecar] ⚠️ \(issue.appName): target unreachable.")
            case .updaterReplacedSymlink:
                print("[Sidecar] ⚠️ \(issue.appName): updater replaced symlink.")
            }
        }

        let nuked = issues.filter { $0.type == .updaterReplacedSymlink }
        if !nuked.isEmpty {
            let names = nuked.map(\.appName).joined(separator: ", ")
            showAlert(
                title: "App Updates Detected",
                message: "\(names) replaced their symlink(s) during an update. They may need re-migration."
            )
        }
    }

    // MARK: - UI Helpers

    private func updateDiskInfo() {
        let state = diskAnalyzer.currentDiskState()
        diskInfoLabel = "\(state.formattedAvailable) free of \(state.formattedTotal) (\(Int(state.usedPercentage))% used)"
    }

    private func updateMigratedCount() {
        let count = manifest.activeRecords.count
        migratedCountLabel = count > 0 ? "\(count) app(s) migrated" : nil
    }

    // MARK: - Dialogs

    private func promptMigration(candidate: DiskAnalyzer.MigrationCandidate) async -> Bool {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = "Migrate \(candidate.footprint.appBundleURL.deletingPathExtension().lastPathComponent)?"
            alert.informativeText = """
                Total footprint: \(candidate.footprint.formattedTotalSize)
                Reclaimable: ~\(candidate.formattedReclaimable)
                Library folders: \(candidate.footprint.libraryItems.count)
                \(candidate.reasoning)
                """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Migrate")
            alert.addButton(withTitle: "Skip")
            continuation.resume(returning: alert.runModal() == .alertFirstButtonReturn)
        }
    }

    private func promptScanResults(message: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = "Migration Recommendations"
            alert.informativeText = message
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Migrate All")
            alert.addButton(withTitle: "Cancel")
            continuation.resume(returning: alert.runModal() == .alertFirstButtonReturn)
        }
    }

    private func promptConflictResolution(
        for existingURL: URL
    ) async -> AppMigrator.ConflictResolution {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = "App Already Exists"
            alert.informativeText = "\"\(existingURL.lastPathComponent)\" already exists on the external drive."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Overwrite")
            alert.addButton(withTitle: "Link Only")
            alert.addButton(withTitle: "Skip")

            switch alert.runModal() {
            case .alertFirstButtonReturn:  continuation.resume(returning: .overwrite)
            case .alertSecondButtonReturn: continuation.resume(returning: .linkOnly)
            default:                       continuation.resume(returning: .skip)
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
