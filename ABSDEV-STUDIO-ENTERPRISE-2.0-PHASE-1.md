# ABSDEV Studio Enterprise 2.0 — Phase 1

## Included

- Shared `StudioEventBus` for cross-module project events.
- Unified `StudioDiagnosticsCentre` with domain, severity and project scoping.
- Unified `StudioLogCentre` with application, project, runtime, database, Git, AI, MCP and documentation channels.
- `ProjectDigitalTwinService` foundation indexing Laravel files, routes, controllers, models, Composer packages, configuration and tests.
- Native searchable Help Centre.
- Help menu integration and tool navigator entry.
- Bundled `Documentation/` help content.
- Twenty-nine Markdown help and reference documents.

## Where to find features

- **Help Centre:** tool navigator → Help Centre, or Help → ABSDEV Studio Help Centre.
- **Keyboard shortcuts:** Help → Keyboard Shortcuts.
- **FAQ:** Help → Frequently Asked Questions.
- **Source documentation:** project root → `Documentation/`.
- **Bundled documentation:** `Resources/Documentation/`.
- **Core services:** `Sources/ABSDEVStudio/EnterpriseCore.swift`.
- **Help implementation:** `Sources/ABSDEVStudio/HelpCentre.swift`.

## Validation

- Every Swift source file passed `swiftc -parse`.
- `ABSDEVStudio.xcodeproj/project.pbxproj` passed `plutil -lint`.
- Swift package tests could not run in the build environment because SwiftPM dependency cache repositories were unavailable.
