# Project Sidecar - Product Requirements

## Goal
Automate the migration of third-party macOS applications from the internal drive to an external USB4 volume via symbolic links to save space.

## Core Features
- **Background Monitor:** Watch `/Applications` for new `.app` additions.
- **System Filtering:** Automatically ignore any app located in `/System/Applications` or signed by Apple (com.apple.*).
- **External Volume Detection:** Only run if a specific external volume (configured by user) is mounted.
- **Conflict Management:** If an app already exists on the external drive, prompt the user with:
    - **Overwrite:** Replace external copy with the new one.
    - **Link Only:** Delete local copy and link to the existing external one.
    - **Skip:** Do nothing.
- **Symlink Creation:** Use `ln -s` logic to ensure the internal `/Applications` folder remains the functional entry point.

## User Interface
- A simple macOS Menu Bar icon showing status (Active/Idle/Drive Missing).
- Native macOS alerts/dialogs for user decisions.