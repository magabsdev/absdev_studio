# Project PHP authority

Each project stores its own PHP executable path in its project record. Project commands never use a global PHP preference or silently fall back to another runtime.

- **Choose…** validates and saves a runtime for only the selected project.
- **Detect** searches installed runtimes and saves the result for only the selected project.
- **Clear** removes the selected project's runtime.
- When no runtime is configured, PHP and Composer actions stop with an explicit configuration message.

The selected project runtime is used for Artisan, Composer, development processes, health audits, workflows, Project Intelligence, and Product Studio.
