# Per-project PHP runtimes

ABSDEV Studio stores the selected PHP executable on each `LaravelProject` using `phpExecutablePath` and `phpDetectionSource`.

## Behaviour

- **Choose…** validates the executable and records its PHP version before saving it to the selected project.
- **Detect** searches supported runtime managers and persists the first working executable to that project only.
- **Clear** removes only the selected project's runtime preference.
- Artisan, Composer, Tinker, queue workers, the scheduler, development processes, route discovery, database inspection, audits, diagrams, and Product Studio use the selected project's executable.
- The legacy global PHP preference is no longer used to execute project commands.

This allows projects requiring different PHP versions to run side-by-side without changing a global application setting.
