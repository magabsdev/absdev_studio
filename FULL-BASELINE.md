# ABSDEV Studio — Full Laravel Control Baseline

This baseline adds first-pass native control surfaces for the approved Laravel project-control roadmap.

## Added control centres

- Application Status
- Cache Control Centre
- Migration Manager
- Events & Listeners
- Model Inspector
- Services & Integrations
- Testing Centre
- Frontend Control
- Real-Time Services (conditional on `laravel/reverb`)
- Observability (conditional on Pulse, Telescope, Horizon, Octane, or Debugbar)
- Feature Flags (conditional on `laravel/pennant`)
- Deployment Preparation
- Maintenance Mode
- Project Architecture Map
- File & Storage Manager
- API Development Centre
- Mail & Notifications
- Laravel AI Inspector (conditional on `laravel/ai`)

The existing Queue, Scheduler, Routes, Database, Composer, Containers, Logs, Project Doctor, Environment, Artisan, Tinker, Terminal, Database Console, Knowledge Base, ServBay and Sail tools remain intact.

## Safety model

Destructive actions use native confirmation before execution. Commands are routed through the existing AppStore process runner so command progress, output capture and failure handling remain consistent.

## Conditional navigation

Package-specific sections are hidden unless their Composer package is present. Frontend Control is hidden unless `package.json` exists. Containers remains visible only while Docker or Apple Containers is running.
