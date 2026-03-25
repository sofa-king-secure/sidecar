# Project Sidecar Development Instructions

## Build Commands
- Run build: `swift build`
- Run tests: `swift test`

## Code Conventions
- Use SwiftUI for all UI elements.
- Use async/await for file system operations.
- Prefer native macOS APIs over shell script execution where possible (security best practice).

## Feature Implementation Order
1. Build the Directory Monitor for `/Applications`.
2. Implement the Filtering logic (External vs Internal).
3. Build the Dialog prompt for file conflicts.
4. Add the Menu Bar status indicator.