# Per-project PHP runtime

Each `LaravelProject` stores its own `phpExecutablePath`, detection source, and detected version.

## Configure a project

1. Select the project in the sidebar.
2. Click the sliders button at the bottom of the sidebar, or right-click the project and choose **Edit Project…**.
3. In **PHP Runtime**, choose **Choose PHP…** and select the exact executable for that project.
4. Alternatively, use **Detect Installed PHP** and verify the detected version.

The setting is persisted in the selected project record and does not alter any other project.

Projects with no configured PHP runtime do not silently use a global runtime.
