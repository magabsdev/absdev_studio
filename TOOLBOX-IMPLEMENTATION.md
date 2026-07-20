# ABSDEV Studio Toolbox Implementation

This build consolidates the professional toolbox around the selected project.

## Added Product Studio modules

- Project Digital Twin
- Request Flow
- Architecture Drift
- Runtime Manager
- Dependency Inspector
- Plugin SDK discovery
- Project Health score in Mission Control

## Existing integrated modules

Architecture, database and ERD, Git, deployment, AI/MCP, performance history, security, packages, routes, queues, scheduler, logs, API, containers, upgrades, templates, metrics, documentation, and project replay.

## Plugin manifest

Project extensions can expose an `absdev-plugin.json` file. The initial discovery contract is intentionally data-only and sandbox-safe:

```json
{
  "schemaVersion": 1,
  "identifier": "com.example.project-analyzer",
  "name": "Example Analyzer",
  "version": "1.0.0",
  "capabilities": ["analyzer", "dashboard"],
  "entrypoint": "Scripts/analyze.sh"
}
```

Executable plug-ins should be explicitly trusted before execution. This build only discovers and displays manifests.
