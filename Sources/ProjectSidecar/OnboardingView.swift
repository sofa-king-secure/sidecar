import AppKit
import SwiftUI

/// First-run onboarding wizard.
/// Now hosted in an NSWindow (not WindowGroup) to fix lifecycle issues.
struct OnboardingView: View {

    @ObservedObject var config: SidecarConfig
    let onComplete: () -> Void

    @State private var currentStep: Step = .welcome
    @State private var discoveredVolumes: [DriveSetup.DiscoveredVolume] = []
    @State private var selectedVolume: DriveSetup.DiscoveredVolume?
    @State private var validationResult: DriveSetup.ValidationResult?
    @State private var diskState: DiskAnalyzer.DiskState?
    @State private var errorMessage: String?

    private let driveSetup = DriveSetup()
    private let diskAnalyzer = DiskAnalyzer()

    enum Step: Int, CaseIterable {
        case welcome
        case driveSelection
        case systemCheck
        case done
    }

    var body: some View {
        VStack(spacing: 0) {
            progressBar
                .padding(.horizontal, 32)
                .padding(.top, 24)

            Group {
                switch currentStep {
                case .welcome:        welcomeStep
                case .driveSelection: driveSelectionStep
                case .systemCheck:    systemCheckStep
                case .done:           doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)

            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text(error)
                        .font(.caption)
                }
                .padding(12)
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal, 32)
            }

            navigationButtons
                .padding(24)
        }
        .frame(width: 600, height: 480)
    }

    // MARK: - Progress

    private var progressBar: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(step.rawValue <= currentStep.rawValue ? Color.accentColor : Color.gray.opacity(0.3))
                    .frame(height: 4)
            }
        }
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)

            Text("Welcome to Sidecar")
                .font(.largeTitle.bold())

            Text("Keep your Mac's internal drive clean by automatically moving heavy app data to an external drive.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)

            VStack(alignment: .leading, spacing: 12) {
                featureRow(icon: "folder.badge.gearshape", text: "Scans inside app Library folders for heavy subdirectories")
                featureRow(icon: "link", text: "Symlinks data so apps work normally — they don't notice the difference")
                featureRow(icon: "arrow.uturn.backward", text: "Full rollback — undo any migration instantly")
                featureRow(icon: "externaldrive.badge.xmark", text: "Apps still launch when the drive isn't connected")
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

    // MARK: - Drive Selection

    private var driveSelectionStep: some View {
        VStack(spacing: 16) {
            Text("Select External Drive")
                .font(.title2.bold())

            Text("Choose the drive where Sidecar should store migrated data.")
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
                Text(volume.name).font(.headline)
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
        .contentShape(Rectangle())
        .onTapGesture {
            guard volume.isReady else {
                errorMessage = volume.fileSystem.formatAdvice
                return
            }
            selectedVolume = volume
            errorMessage = nil
        }
    }

    // MARK: - System Check

    private var systemCheckStep: some View {
        VStack(spacing: 20) {
            Text("System Check")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 16) {
                checkRow(
                    label: "Library Access",
                    detail: "Can read and write ~/Library data",
                    passed: checkLibraryAccess()
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
                }
            }
            .frame(maxWidth: 440, alignment: .leading)
        }
        .onAppear {
            diskState = diskAnalyzer.currentDiskState()
        }
    }

    private func checkRow(label: String, detail: String, passed: Bool) -> some View {
        HStack {
            Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(passed ? .green : .red)
            VStack(alignment: .leading) {
                Text(label).font(.callout.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Done

    private var doneStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)

            Text("You're All Set!")
                .font(.largeTitle.bold())

            VStack(spacing: 8) {
                if let vol = selectedVolume {
                    Text("Sidecar is configured to use **\(vol.name)**.")
                }
                Text("Use **Scan & Migrate** from the menu bar to choose what to move.")
                Text("New apps will be detected automatically.")
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
                    config.registerDrive(
                        volumeUUID: volume.id,
                        volumeName: volume.name,
                        capacityBytes: volume.totalBytes
                    )
                    config.configureDrive(volumeUUID: volume.id, volumeName: volume.name)

                    // Initialize directory structure on drive.
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
                    config.completeOnboarding()
                    withAnimation { currentStep = .done }
                }
                .buttonStyle(.borderedProminent)

            case .done:
                Button("Start Sidecar") {
                    config.completeOnboarding()
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Actions

    private func scanForDrives() async {
        discoveredVolumes = await driveSetup.discoverExternalVolumes()
        errorMessage = nil
        if discoveredVolumes.count == 1, let only = discoveredVolumes.first, only.isReady {
            selectedVolume = only
        }
    }

    private func checkLibraryAccess() -> Bool {
        let testPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return FileManager.default.isWritableFile(atPath: testPath.path)
    }
}
