# Technical Specifications

## Environment
- **Platform:** macOS 14+ (Sonoma/Sequoia/later)
- **Language:** Swift/SwiftUI (recommended for native dialogs and permissions)
- **Permissions:** Requires 'Full Disk Access' to move files in /Applications.

## Logic Architecture
1. **File Monitoring:** Use `VNODE` or `FSEvents` to monitor directory changes.
2. **Identification:** Use `MDItemCopyAttribute` to check the `kMDItemCreator` or `BundleIdentifier`.
3. **Move Logic:**
    - Use `FileManager.default.moveItem` for the initial transfer.
    - Ensure attributes and permissions are preserved (ditto or rsync style).
4. **Symlink:** `FileManager.default.createSymbolicLink`.
5. **LaunchAgent:** Generate a `.plist` to ensure the app starts at login.

## Error Handling
- Handle "Drive Disconnected" state gracefully: The app should pause monitoring and notify the user.
- Handle "Permission Denied": Trigger a prompt directing user to System Settings.