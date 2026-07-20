# ABSDEV Studio

Native macOS Laravel project manager built with SwiftUI.

## Open and run

1. Open `ABSDEVStudio.xcodeproj` in Xcode 16 or later.
2. Select the **ABSDEVStudio** scheme and **My Mac** destination.
3. Press **Command-R**.
4. Use **Add Project** and select a directory containing `artisan`.

## Functional features

- Laravel project validation and persistence
- PHP, Laravel and Git branch detection
- Start/stop supervised Laravel server, Vite, queue worker and scheduler processes
- Streaming process output
- Artisan, Composer and database command execution
- `.env` loading, editing, saving and comparison
- Laravel log reading, searching, refreshing and clearing
- Route loading through `artisan route:list --json`
- Project diagnostics with executable repairs
- Browser, Finder, terminal and editor integration
- Configurable PHP executable, editor and terminal

The app sandbox is disabled because this developer tool must execute local PHP, Composer, npm and Git binaries and access selected project directories.

## Container Management

ABSDEV Studio includes a native container workspace inspired by dry and AppleContainerDesktop.

### Docker

- Local or remote daemon support through `DOCKER_HOST`
- Container list, filtering, start, stop, restart, kill, remove, logs, inspect and shell
- Image pull, inspect, delete and prune
- Volume create, inspect, delete and prune
- Network inspect and delete
- Docker Compose project discovery, up, down and logs
- Docker system information, disk usage, events and pruning

### Apple Container

Install Apple's `container` CLI separately (`brew install --cask container`). ABSDEV Studio can detect common installation paths or use a custom executable path.

- Start, stop and restart the Apple container system
- List and manage containers
- Pull, inspect and remove images
- Create, inspect and delete volumes
- Runtime status and system properties

The application invokes the installed Docker or Apple Container command-line tool and does not bundle either runtime.

## Project-aware Artisan command discovery

The Artisan workspace scans the currently selected Laravel project with `artisan list --format=json` and falls back to `artisan list --raw` for older Laravel/Symfony Console releases. This means the UI includes every command actually registered by the project's Laravel version, installed Composer packages, enabled modules, and custom application commands. Commands are grouped by namespace, searchable by name/description/alias, and guarded before execution. Destructive database and queue commands require explicit confirmation.

## Terminal fonts

The embedded terminal automatically prefers installed Nerd Font variants (including MesloLGS NF, JetBrains Mono Nerd Font, Caskaydia Cove Nerd Font, Hack Nerd Font and FiraCode Nerd Font) so Powerline and shell-prompt glyphs render correctly. It falls back to Menlo when no compatible Nerd Font is installed.

## Embedded MCP Server

ABSDEV Studio includes a local Streamable HTTP MCP server at `http://127.0.0.1:8765/mcp`.
It runs inside the macOS application and can be controlled from **Settings → MCP**.

Project definitions are stored as separate JSON files in:

```text
~/Library/Application Support/ABSDEVStudio/MCPProjects/
```

Use **Create JSON for Studio Projects** to generate definitions for projects already registered in ABSDEV Studio, or edit the JSON files manually. Each definition controls its project root, include/exclude rules, enabled state and read/search/list permissions. The server binds to localhost only and rejects paths outside each configured project root.

## Embedded MCP project intelligence

The embedded server exposes `ask_project` as the primary natural-language source tool. Example MCP arguments:

```json
{
  "project": "poolmate",
  "question": "Where are tournament matches created and which tests cover that flow?",
  "maxFiles": 14
}
```

When exactly one MCP project is enabled, `project` may be omitted. Supporting read-only tools include `find_definition`, `find_references`, `project_overview`, `project_git_status`, `project_laravel_routes`, `project_tests`, and `project_index_status`.

## Project Intelligence Suite

The Project Intelligence workspace now provides seven coordinated native capabilities:

- Persistent AI memory scoped by the navigator project's stable UUID.
- A local symbol and dependency knowledge graph backed by the embedded MCP index.
- A Git repository timeline showing recent commits.
- One-click Laravel, Swift, dependency, environment, test, and repository health checks.
- A native MCP Hub linked to the embedded project-aware MCP server.
- Saved Laravel and Swift workflows with streamed command output and stop-on-failure behaviour.
- Cross-project source search excluding generated, vendor, node_modules, Git, and DerivedData content.

Project data is stored under `~/Library/Application Support/ABSDEVStudio/ProjectIntelligence` and does not rename or alter source project folders.
