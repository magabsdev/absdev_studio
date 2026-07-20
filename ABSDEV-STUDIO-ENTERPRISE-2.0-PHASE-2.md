# ABSDEV Studio Enterprise 2.0 — Phase 2

## Delivered

Phase 2 adds the Laravel-first product layer on top of the Enterprise Core introduced in Phase 1.

### Runtime Centre

Location: `Sources/ABSDEVStudio/EnterprisePhaseTwo.swift`

Open **Runtime Centre** from the tool navigator. Runtime profiles are stored per project in Application Support and include PHP, Composer, Node, npm, pnpm, Bun, Docker, database-driver preference, and environment name. Use **Detect Installed Tools**, **Validate**, then **Save Profile**.

### Laravel Studio

Location: `Sources/ABSDEVStudio/EnterprisePhaseTwo.swift`

Open **Laravel Studio** from the tool navigator. It uses the shared Project Digital Twin and presents indexed counts for routes, controllers, models, migrations, jobs, events/listeners, views, tests, packages, and configuration. Each metric opens the corresponding existing ABSDEV Studio tool.

### Digital Twin expansion

Location: `Sources/ABSDEVStudio/EnterpriseCore.swift`

The snapshot now indexes migrations, jobs, events, listeners, middleware, policies, and Blade views in addition to Phase 1 project data.

### Complete Help library

Locations:

- Editable source: `Documentation/`
- Bundled application copy: `Resources/Documentation/`
- Master index: `Documentation/INDEX.md`

The help library now contains more than 80 Markdown documents covering application use, Laravel tooling, runtimes, AI, databases, Git, deployment, architecture, security, administration, and troubleshooting.

## Navigation

- **Laravel Studio**: tool navigator → Laravel Studio
- **Runtime Centre**: tool navigator → Runtime Centre
- **Help Centre**: tool navigator → Help Centre
- **Documentation source**: project root → Documentation

## Validation

All Swift files are syntax parsed during packaging. The Xcode project and property lists are validated before release packaging.
