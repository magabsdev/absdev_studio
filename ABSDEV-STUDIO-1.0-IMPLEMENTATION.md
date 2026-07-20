# ABSDEV Studio 1.0 Integrated Toolbox

This baseline consolidates the product around the selected project and adds operational modules for:

- Mission Control and explainable health scoring
- Project Digital Twin and architecture inventory
- Visual request-flow debugging
- Architecture drift and local AI code-review preparation
- Project Doctor Pro
- Database Studio and schema comparison preparation
- Git Client and Advanced Git inventory
- AI Assistant and AI Test Writer preparation
- Deployment, containers and runtime management
- Persistent observability and performance history
- Security, package and dependency inspection
- Routes, queues, scheduler, logs and API inspection
- Documentation, replay, templates and plug-in manifests

## Release validation

Before distribution run:

```bash
swift test
xcodebuild -project ABSDEVStudio.xcodeproj -scheme ABSDEVStudio -configuration Release build
```

Runtime-dependent features must also be tested against at least one Laravel project using MySQL and one using SQLite.
