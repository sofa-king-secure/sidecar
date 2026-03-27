import AppKit
import SwiftUI

/// First-run onboarding wizard. Shown once on initial launch.
///
/// Flow:
///   1. Welcome — "Keep your Mac clean" pitch
///   2. Drive Selection — detect external drives, validate filesystem
///   3. System Check — verify permissions, check internal disk state
///   4. Initial Scan — show what could be migrated, let user pick
///   5. Done — start monitoring
struct OnboardingView: View {

    @ObservedObject var config: SidecarConfig
    let onComplete: () -> Void

    @State private var currentStep: Step = .welcome
    @State private var discoveredVolumes: [DriveSetup.DiscoveredVolume] = []
    @State private var selectedVolume: DriveSetup.DiscoveredVolume?
    @State private var validationResult: DriveSetup.ValidationResult?
    @State private var systemCheckPassed = false
    @State private var diskState: DiskAnalyzer.DiskState?
    @State private var scanResults: [DiskAnalyzer.MigrationCandidate] = []
    @State private var selectedForMigration: Set<String> = []
    @State private var isScanning = false
    @State private var errorMessage: String?

    private let driveSetup = DriveSetup()
    private let diskAnalyzer = DiskAnalyzer()
    private let libraryScanner = LibraryScanner()

    enum Step: Int, CaseIterable {
        case welcome
        case driveSelection
        case systemCheck
        case initialScan
        case done
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            progressBar
                .padding(.horizontal, 32)
                .padding(.top, 24)

            // Content area
            Group {
                switch currentStep {
                case .welcome:       welcomeStep
                case .driveSelection: driveSelectionStep
                case .systemCheck:   systemCheckStep
                case .initialScan:   initialScanStep
                case .done:          doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)

            // Error banner
            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                }
                .padding(12)
                .background(.red.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal, 32)
            }

            // Navigation buttons
            navigationButtons
                .padding(24)
        }
        .frame(width: 600, height: 520)
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(step.rawValue <= currentStep.rawValue ? Color.accentColor : Color.gray.opacity(0.3))
                    .frame(height: 4)
            }
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("Welcome to Sidecar")
                .font(.largeTitle.bold())

            Text("Keep your Mac's internal drive clean by automatically moving large applications and their data to an external drive.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)

            VStack(alignment: .leading, spacing: 12) {
                featureRow(icon: "arrow.right.circle", text: "Moves apps and Library data to your external drive")
                featureRow(icon: "link", text: "Creates symlinks so everything still works normally")
                featureRow(icon: "eye", text: "Monitors for new installs and handles them automatically")
                featureRow(icon: "arrow.uturn.backward", text: "Full rollback — undo any migration with one click")
            }
            .padding(.top, 8)
        }
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundColor(.accentColor)
            Text(text)
                .font(.callout)
        }
    }

    // MARK: - Step 2: Drive Selection

    private var driveSelectionStep: some View {
        VStack(spacing: 16) {
            Text("Select External Drive")
                .font(.title2.bold())

            Text("Choose the drive where Sidecar should store your applications.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if discoveredVolumes.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.questionmark")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No external drives detected.")
                        .foregroundStyle(.secondary)
                    Button("Refresh") {
                        Task { await scanForDrives() }
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(discoveredVolumes) { volume in
                            driveCard(volume)
                        }
                    }
                }

                if let validation = validationResult, !validation.isReady {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(validation.issues, id: \.self) { issue in
                            Label(issue, systemImage: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .task { await scanForDrives() }
    }

    private func driveCard(_ volume: DriveSetup.DiscoveredVolume) -> some View {
        HStack {
            Image(systemName: volume.isReady ? "externaldrive.fill" : "externaldrive.badge.xmark")
                .font(.title2)
                .foregroundColor(volume.isReady ? .accentColor : .red)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(volume.name).font(.headline)
                    if volume.hasSidecarData {
                        Text("Previously used")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
                Text("\(volume.formattedAvailable) free of \(volume.formattedCapacity) • \(volume.fileSystem.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if selectedVolume?.id == volume.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
            }
        }
        .padding(12)
        .background(selectedVolume?.id == volume.id ? Color.accentColor.opacity(0.1) : Color.gray.opacity(0.05))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selectedVolume?.id == volume.id ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard volume.isReady else {
                errorMessage = volume.fileSystem.formatAdvice
                return
            }
            selectedVolume = volume
            validationResult = driveSetup.validateVolume(volume)
            errorMessage = nil
        }
    }

    // MARK: - Step 3: System Check

    private var systemCheckStep: some View {
        VStack(spacing: 20) {
            Text("System Check")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 16) {
                checkRow(
                    label: "Full Disk Access",
                    detail: "Required to move apps in /Applications",
                    passed: checkFullDiskAccess()
                )

                checkRow(
                    label: "External Drive Ready",
                    detail: selectedVolume.map { "\($0.name) — \($0.formattedAvailable) available" } ?? "No drive selected",
                    passed: selectedVolume != nil
                )

                if let state = diskState {
                    checkRow(
                        label: "Internal Drive",
                        detail: "\(state.formattedAvailable) free of \(state.formattedTotal) (\(Int(state.usedPercentage))% used)",
                        passed: true
                    )

                    if state.pressure >= .high {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Your internal drive is \(Int(state.usedPercentage))% full. Sidecar will prioritize large apps to free up space quickly.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                        .background(.orange.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
            }
            .frame(maxWidth: 440, alignment: .leading)

            if !checkFullDiskAccess() {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
                    )
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear {
            diskState = diskAnalyzer.currentDiskState()
            systemCheckPassed = checkFullDiskAccess() && selectedVolume != nil
        }
    }

    private func checkRow(label: String, detail: String, passed: Bool) -> some View {
        HStack {
            Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(passed ? .green : .red)
            VStack(alignment: .leading) {
                Text(label).font(.callout.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Step 4: Initial Scan

    private var initialScanStep: some View {
        VStack(spacing: 16) {
            Text("Initial Scan")
                .font(.title2.bold())

            if isScanning {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Scanning applications and Library data...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
            } else if scanResults.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.green)
                    Text("No apps large enough to migrate right now.")
                        .foregroundStyle(.secondary)
                    Text("Sidecar will monitor for new installs going forward.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
            } else {
                Text("Select apps to migrate now (you can always migrate more later):")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(scanResults) { candidate in
                            scanResultRow(candidate)
                        }
                    }
                }

                let totalSelected = scanResults
                    .filter { selectedForMigration.contains($0.id) }
                    .reduce(0) { $0 + $1.reclaimableBytes }
                let formatted = ByteCountFormatter.string(fromByteCount: Int64(totalSelected), countStyle: .file)

                Text("\(selectedForMigration.count) selected — ~\(formatted) reclaimable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task { await runInitialScan() }
    }

    private func scanResultRow(_ candidate: DiskAnalyzer.MigrationCandidate) -> some View {
        let appName = candidate.footprint.appBundleURL
            .deletingPathExtension().lastPathComponent
        let isSelected = selectedForMigration.contains(candidate.id)

        return HStack {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? .accentColor : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(appName).font(.callout.bold())
                Text("\(candidate.footprint.formattedTotalSize) total • \(candidate.formattedReclaimable) reclaimable • \(candidate.footprint.libraryItems.count) library folders")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.05) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected {
                selectedForMigration.remove(candidate.id)
            } else {
                selectedForMigration.insert(candidate.id)
            }
        }
    }

    // MARK: - Step 5: Done

    private var doneStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)

            Text("You're All Set!")
                .font(.largeTitle.bold())

            VStack(spacing: 8) {
                if let vol = selectedVolume {
                    Text("Sidecar is configured to use **\(vol.name)**.")
                }
                Text("New apps will be automatically detected and you'll be prompted to migrate them.")
                Text("Look for the drive icon in your menu bar.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 400)
        }
    }

    // MARK: - Navigation

    private var navigationButtons: some View {
        HStack {
            if currentStep != .welcome {
                Button("Back") {
                    withAnimation {
                        currentStep = Step(rawValue: currentStep.rawValue - 1) ?? .welcome
                    }
                }
            }

            Spacer()

            switch currentStep {
            case .welcome:
                Button("Get Started") {
                    withAnimation { currentStep = .driveSelection }
                }
                .buttonStyle(.borderedProminent)

            case .driveSelection:
                Button("Continue") {
                    guard let volume = selectedVolume else { return }
                    // Register + configure the drive.
                    config.registerDrive(
                        volumeUUID: volume.id,
                        volumeName: volume.name,
                        capacityBytes: volume.totalBytes
                    )
                    config.configureDrive(volumeUUID: volume.id, volumeName: volume.name)

                    // Initialize directory structure if fresh.
                    if !volume.hasSidecarData {
                        do {
                            try driveSetup.initializeDrive(at: volume.mountPoint)
                        } catch {
                            errorMessage = "Failed to set up drive: \(error)"
                            return
                        }
                    }

                    withAnimation { currentStep = .systemCheck }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedVolume == nil)

            case .systemCheck:
                Button("Continue") {
                    withAnimation { currentStep = .initialScan }
                }
                .buttonStyle(.borderedProminent)

            case .initialScan:
                Button(selectedForMigration.isEmpty ? "Skip & Finish" : "Migrate Selected & Finish") {
                    // TODO: Wire up actual migration for selected candidates.
                    // For now, complete onboarding — migration happens on next launch.
                    config.completeOnboarding()
                    withAnimation { currentStep = .done }
                }
                .buttonStyle(.borderedProminent)

            case .done:
                Button("Start Sidecar") {
                    config.completeOnboarding()
                    onComplete()
                    // Close the onboarding window.
                    NSApplication.shared.keyWindow?.close()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Actions

    private func scanForDrives() async {
        discoveredVolumes = await driveSetup.discoverExternalVolumes()
        errorMessage = nil

        // Auto-select if there's exactly one ready drive.
        if discoveredVolumes.count == 1, let only = discoveredVolumes.first, only.isReady {
            selectedVolume = only
            validationResult = driveSetup.validateVolume(only)
        }
    }

    private func runInitialScan() async {
        isScanning = true
        let footprints = await libraryScanner.scanAllApps()
        let state = diskAnalyzer.currentDiskState()
        scanResults = diskAnalyzer.prioritize(footprints: footprints, diskState: state)

        // Pre-select top candidates.
        let plan = diskAnalyzer.recommendMigrationPlan(candidates: scanResults, diskState: state)
        selectedForMigration = Set(plan.toMigrate.map(\.id))

        isScanning = false
    }

    private func checkFullDiskAccess() -> Bool {
        // Heuristic: try to read a protected path.
        return FileManager.default.isReadableFile(atPath: "/Library/Application Support/com.apple.TCC/TCC.db")
    }
}
