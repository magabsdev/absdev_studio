# Per-project PHP runtime

Each `LaravelProject` stores its own `phpExecutablePath` and detection source in the persisted project JSON.

The selected project is passed directly to the PHP resolver. Resolution never searches by project path and never falls back to another project, PATH, Homebrew, Herd, ServBay, or `/usr/bin/php` during command execution.

Automatic discovery is available only when the user presses **Detect**. The selected executable is then validated and copied into that project's record. Subsequent execution uses only the saved project value.

Entity Diagram generation also requires the project's saved PHP runtime and no longer performs independent global discovery.

Configure a project in **Settings → Tools → Project PHP Runtime** after selecting that project in the sidebar.
