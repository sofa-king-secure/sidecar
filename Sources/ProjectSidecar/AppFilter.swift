import Foundation
import Security

/// Filters out Apple-signed and system applications so only third-party
/// apps are candidates for migration.
///
/// Per PRD: ignore `/System/Applications` and anything signed by Apple (`com.apple.*`).
/// Per CLAUDE.md: prefer native macOS APIs over shell execution.
struct AppFilter: Sendable {

    // MARK: - Paths that are always excluded

    /// Directories whose contents are never eligible for migration.
    private static let excludedPrefixes: [String] = [
        "/System/Applications",
        "/System/Library"
    ]

    // MARK: - Public API

    /// Returns `true` if the app at `appURL` is a third-party app that
    /// should be considered for migration.
    func shouldProcess(appURL: URL) async throws -> Bool {
        // 1. Reject anything under an excluded system path.
        let resolvedPath = appURL.path
        for prefix in Self.excludedPrefixes {
            if resolvedPath.hasPrefix(prefix) {
                return false
            }
        }

        // 2. Reject apps whose bundle identifier starts with "com.apple.".
        if let bundleID = bundleIdentifier(for: appURL),
           bundleID.hasPrefix("com.apple.") {
            return false
        }

        // 3. Reject Apple-signed apps via code-signing metadata (native API).
        if try await isAppleSigned(appURL: appURL) {
            return false
        }

        return true
    }

    // MARK: - Bundle Identifier

    /// Reads the `CFBundleIdentifier` from the app's `Info.plist` using
    /// native Foundation APIs (no shell calls).
    private func bundleIdentifier(for appURL: URL) -> String? {
        let plistURL = appURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Info.plist")

        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, format: nil
              ) as? [String: Any] else {
            return nil
        }

        return plist["CFBundleIdentifier"] as? String
    }

    // MARK: - Code Signature Check (Native)

    /// Uses the Security framework's `SecStaticCode` API to inspect the
    /// code-signing certificate chain. Returns `true` if the leaf
    /// certificate's Organizational Unit is Apple's known team ID
    /// or if the signing identifier begins with `com.apple.`.
    ///
    /// This avoids shelling out to `codesign` per CLAUDE.md conventions.
    private func isAppleSigned(appURL: URL) async throws -> Bool {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            appURL as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard createStatus == errSecSuccess, let code = staticCode else {
            return false // Can't inspect → treat as third-party.
        }

        var cfInfo: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &cfInfo
        )
        guard infoStatus == errSecSuccess, let info = cfInfo as? [String: Any] else {
            return false
        }

        // Check signing identifier.
        if let signingID = info[kSecCodeInfoIdentifier as String] as? String,
           signingID.hasPrefix("com.apple.") {
            return true
        }

        // Check team identifier (Apple's own apps use team ID from Apple).
        if let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String {
            // Apple's first-party team IDs.
            let appleTeamIDs: Set<String> = [
                "APPLECOMPUTER",   // Legacy
                "apple",
                "APPLE"
            ]
            if appleTeamIDs.contains(teamID) {
                return true
            }
        }

        return false
    }
}
