# Contributing to Project Sidecar

Thanks for your interest in contributing! Here's how to get started.

## Development Setup

1. **Requirements**: macOS 14+, Xcode 15+, Swift 5.9+
2. **Clone**: `git clone https://github.com/YOUR_USERNAME/project-sidecar.git`
3. **Build**: `swift build`
4. **Test**: `swift test`

## Code Conventions

These are defined in `CLAUDE.md` and apply to all contributions:

- **SwiftUI** for all UI elements
- **async/await** for file system operations
- **Native macOS APIs** over shell script execution (security best practice)
- Exception: `diskutil` for disk metadata (no pure-Swift API exists)

## Branch Strategy

- `main` — stable, release-ready
- `develop` — integration branch
- `feature/*` — individual features
- `fix/*` — bug fixes

## Pull Request Process

1. Fork the repo and create your branch from `develop`
2. Write or update tests for any new functionality
3. Ensure `swift test` passes
4. Update documentation if you're adding features
5. Submit a PR with a clear description of changes

## Reporting Issues

- Use GitHub Issues
- Include macOS version, drive type/filesystem, and steps to reproduce
- Logs from `Console.app` filtered by "Sidecar" are helpful

## Code of Conduct

Be respectful, constructive, and collaborative. We're all here to build something useful.
