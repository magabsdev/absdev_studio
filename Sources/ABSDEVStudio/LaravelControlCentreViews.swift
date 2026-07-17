import AppKit
import Foundation
import SwiftUI

enum LaravelControlKind: String {
    case applicationStatus, cacheControl, migrations, events, models, services
    case testing, frontend, realtime, observability, featureFlags, deployment
    case maintenance, architecture, storage, apiCentre, mailPreview, aiInspector

    var title: String {
        switch self {
        case .applicationStatus: "Application Status"
        case .cacheControl: "Cache Control Centre"
        case .migrations: "Migration Manager"
        case .events: "Events & Listeners"
        case .models: "Model Inspector"
        case .services: "Services & Integrations"
        case .testing: "Testing Centre"
        case .frontend: "Frontend Control"
        case .realtime: "Real-Time Services"
        case .observability: "Observability"
        case .featureFlags: "Feature Flags"
        case .deployment: "Deployment Preparation"
        case .maintenance: "Maintenance Mode"
        case .architecture: "Project Architecture"
        case .storage: "File & Storage Manager"
        case .apiCentre: "API Development Centre"
        case .mailPreview: "Mail & Notifications"
        case .aiInspector: "Laravel AI Inspector"
        }
    }

    var subtitle: String {
        switch self {
        case .applicationStatus: "Inspect framework, runtime, environment and project health."
        case .cacheControl: "Build, inspect and clear Laravel optimisation caches."
        case .migrations: "Inspect and safely control database schema migrations."
        case .events: "Discover events, listeners, subscribers and cached mappings."
        case .models: "Inspect Eloquent models, relationships, casts and policies."
        case .services: "Review configured Laravel services and external integrations."
        case .testing: "Run focused test suites, coverage and browser tests."
        case .frontend: "Control Vite, Node dependencies, builds and audits."
        case .realtime: "Manage broadcasting, channels and Laravel Reverb."
        case .observability: "Control Pulse, Telescope, Horizon, Octane and diagnostics."
        case .featureFlags: "Inspect and maintain Laravel Pennant feature state."
        case .deployment: "Validate the project and prepare a safe deployment."
        case .maintenance: "Enable, inspect and disable Laravel maintenance mode."
        case .architecture: "Browse the Laravel source structure and generated components."
        case .storage: "Inspect disks, storage links, permissions and local files."
        case .apiCentre: "Inspect API routes, authentication and request tooling."
        case .mailPreview: "Inspect mailers, mailables, notifications and delivery configuration."
        case .aiInspector: "Inspect Laravel AI providers, agents, tools and configuration."
        }
    }
}

private enum ControlCommand {
    case artisan(String)
    case shell(String)
    case navigate(AppSection)
}

private struct ControlAction: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let symbol: String
    let badge: String
    let command: ControlCommand
    var destructive = false
}

struct LaravelControlCentreView: View {
    @Environment(AppStore.self) private var store
    let kind: LaravelControlKind

    private let columns = [GridItem(.adaptive(minimum: 285, maximum: 430), spacing: 20)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                PageHeader(title: kind.title, subtitle: kind.subtitle)
                Button {
                    Task { await store.refreshProject() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(28)

            Divider()

            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    ForEach(actions) { action in
                        controlCard(action)
                    }
                }
                .padding(28)
            }
        }
    }

    private func controlCard(_ action: ControlAction) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: action.symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text(action.title).font(.headline)
                    Text(action.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(action.badge)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
            }

            Spacer(minLength: 4)
            Divider()
            HStack {
                Spacer()
                Button {
                    execute(action)
                } label: {
                    Label(action.destructive ? "Run Safely" : "Run", systemImage: action.destructive ? "exclamationmark.shield" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(action.destructive ? Color.red : Color.accentColor)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.separator.opacity(0.6)))
    }

    private func execute(_ action: ControlAction) {
        if action.destructive, !confirm(action) { return }
        switch action.command {
        case .artisan(let command):
            store.runArtisan(command)
        case .shell(let command):
            store.runCommand(command)
        case .navigate(let section):
            store.selectedSection = section
        }
    }

    private func confirm(_ action: ControlAction) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Run \(action.title)?"
        alert.informativeText = "This operation can change or remove project data. Verify the selected project and environment before continuing."
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private var actions: [ControlAction] {
        switch kind {
        case .applicationStatus:
            return [
                a("Laravel About", "Framework, PHP, environment, drivers and package summary.", "info.circle.fill", "Inspect", .artisan("about")),
                a("Environment", "Review APP_ENV, APP_DEBUG, URL and selected project variables.", "slider.horizontal.3", "Open", .navigate(.environment)),
                a("Project Doctor", "Run writable-directory, key, runtime and dependency checks.", "stethoscope", "Health", .navigate(.doctor)),
                a("Git Status", "Show branch, changed files and current working-tree state.", "arrow.triangle.branch", "Git", .shell("git status --short --branch")),
                a("Runtime Versions", "Display PHP, Composer, Node and package-manager versions.", "terminal.fill", "Runtime", .shell("php -v; composer --version; node --version 2>/dev/null || true; npm --version 2>/dev/null || true"))
            ]
        case .cacheControl:
            return [
                a("Optimise", "Cache framework bootstrap files for production.", "bolt.fill", "Build", .artisan("optimize")),
                a("Clear Optimisation", "Remove generated framework optimisation caches.", "trash", "Clear", .artisan("optimize:clear")),
                a("Configuration Cache", "Build the merged configuration cache.", "gearshape.2.fill", "Build", .artisan("config:cache")),
                a("Route Cache", "Build the route registration cache.", "arrow.triangle.branch", "Build", .artisan("route:cache")),
                a("View Cache", "Precompile Blade templates.", "rectangle.stack.fill", "Build", .artisan("view:cache")),
                a("Event Cache", "Cache discovered event and listener mappings.", "point.3.connected.trianglepath.dotted", "Build", .artisan("event:cache")),
                a("Clear Application Cache", "Flush the configured application cache store.", "externaldrive.badge.xmark", "Destructive", .artisan("cache:clear"), true)
            ]
        case .migrations:
            return [
                a("Migration Status", "List applied and pending migrations.", "list.bullet.rectangle", "Inspect", .artisan("migrate:status")),
                a("Run Migrations", "Apply all pending migrations.", "arrow.up.square.fill", "Apply", .artisan("migrate")),
                a("Rollback", "Rollback the latest migration batch.", "arrow.uturn.backward.square.fill", "Destructive", .artisan("migrate:rollback"), true),
                a("Schema Dump", "Create a schema snapshot for faster fresh databases.", "archivebox.fill", "Generate", .artisan("schema:dump")),
                a("Fresh with Seed", "Drop all tables, migrate and seed the database.", "exclamationmark.triangle.fill", "Destructive", .artisan("migrate:fresh --seed"), true),
                a("Database Inspector", "Open tables, columns, indexes and relationships.", "cylinder.fill", "Open", .navigate(.database))
            ]
        case .events:
            return [
                a("List Events", "Display registered events and listeners.", "list.bullet", "Inspect", .artisan("event:list")),
                a("Cache Events", "Cache event discovery for deployment.", "bolt.horizontal.circle", "Build", .artisan("event:cache")),
                a("Clear Event Cache", "Remove the cached event manifest.", "trash", "Clear", .artisan("event:clear")),
                a("Discover Source", "Find event, listener and subscriber classes.", "magnifyingglass", "Source", .shell("find app -type f \\( -path '*/Events/*' -o -path '*/Listeners/*' \\) | sort"))
            ]
        case .models:
            return [
                a("List Models", "Discover Eloquent model source files.", "cube.transparent", "Source", .shell("find app -type f -path '*/Models/*.php' | sort")),
                a("Inspect Model", "Choose a model and run Laravel model:show.", "doc.text.magnifyingglass", "Inspect", .artisan("model:show")),
                a("Factories", "Find model factories in the project.", "building.2.crop.circle", "Source", .shell("find database/factories -type f 2>/dev/null | sort")),
                a("Policies & Observers", "Discover model policies and observers.", "eye.fill", "Source", .shell("find app -type f \\( -path '*/Policies/*' -o -path '*/Observers/*' \\) | sort")),
                a("Open Tinker", "Start an interactive model inspection session.", "chevron.left.forwardslash.chevron.right", "Interactive", .navigate(.tinker))
            ]
        case .services:
            return [
                a("Configuration Overview", "Inspect cache, queue, session, mail and filesystem drivers.", "switch.2", "Inspect", .artisan("about")),
                a("Redis", "Test the configured Redis connection through Laravel.", "memorychip.fill", "Test", .artisan("tinker --execute=\"try { echo Illuminate\\Support\\Facades\\Redis::ping(); } catch (Throwable $e) { echo $e->getMessage(); }\"")),
                a("Filesystem Disks", "List configured filesystem disk names.", "externaldrive.fill", "Inspect", .shell("php -r '$c=require \"config/filesystems.php\"; echo implode(PHP_EOL,array_keys($c[\"disks\"]??[]));'")),
                a("Composer Packages", "Open installed framework integrations.", "shippingbox.fill", "Open", .navigate(.intelligence))
            ]
        case .testing:
            return [
                a("All Tests", "Run the complete Laravel test suite.", "checkmark.seal.fill", "Test", .artisan("test")),
                a("Parallel Tests", "Run tests concurrently when supported.", "rectangle.3.group.fill", "Test", .artisan("test --parallel")),
                a("Coverage", "Run tests and generate coverage output.", "chart.bar.fill", "Coverage", .artisan("test --coverage")),
                a("Stop on Failure", "Run until the first failing test.", "stop.circle.fill", "Test", .artisan("test --stop-on-failure")),
                a("Dusk", "Run browser tests when Laravel Dusk is installed.", "moon.stars.fill", "Browser", .artisan("dusk"))
            ]
        case .frontend:
            return [
                a("Install Dependencies", "Install locked frontend dependencies.", "square.and.arrow.down.fill", "npm", .shell("npm install")),
                a("Development Server", "Start the Vite development server in the command console.", "play.rectangle.fill", "Vite", .shell("npm run dev")),
                a("Production Build", "Create production frontend assets.", "hammer.fill", "Build", .shell("npm run build")),
                a("Dependency Audit", "Check Node dependencies for known vulnerabilities.", "shield.lefthalf.filled", "Audit", .shell("npm audit")),
                a("Outdated Packages", "List outdated direct Node dependencies.", "clock.arrow.circlepath", "Inspect", .shell("npm outdated || true"))
            ]
        case .realtime:
            return [
                a("Broadcasting Configuration", "Review the configured broadcasting connection.", "antenna.radiowaves.left.and.right", "Inspect", .shell("grep -E '^(BROADCAST_CONNECTION|REVERB_)' .env 2>/dev/null | sed 's/=.*/=<masked>/'")),
                a("Start Reverb", "Start Laravel's WebSocket server.", "wave.3.right.circle.fill", "Reverb", .artisan("reverb:start")),
                a("Restart Reverb", "Gracefully restart active Reverb servers.", "arrow.clockwise.circle.fill", "Reverb", .artisan("reverb:restart")),
                a("List Channels", "Inspect application broadcasting channel definitions.", "dot.radiowaves.left.and.right", "Source", .shell("test -f routes/channels.php && sed -n '1,240p' routes/channels.php || true"))
            ]
        case .observability:
            return [
                a("Pulse Check", "Inspect Pulse installation and command availability.", "waveform.path.ecg", "Pulse", .artisan("about")),
                a("Telescope Prune", "Remove expired Telescope entries.", "scope", "Telescope", .artisan("telescope:prune")),
                a("Horizon Status", "Show the current Horizon supervisor state.", "chart.xyaxis.line", "Horizon", .artisan("horizon:status")),
                a("Restart Horizon", "Gracefully terminate Horizon so the process monitor restarts it.", "arrow.clockwise", "Horizon", .artisan("horizon:terminate")),
                a("Reload Octane", "Reload Octane workers without a full stop.", "hare.fill", "Octane", .artisan("octane:reload")),
                a("Logs", "Open structured application logs and live tailing.", "doc.text.magnifyingglass", "Open", .navigate(.logs))
            ]
        case .featureFlags:
            return [
                a("Pennant Purge", "Purge all resolved feature values.", "trash", "Destructive", .artisan("pennant:purge"), true),
                a("Feature Definitions", "Find project feature definitions and Pennant calls.", "flag.pattern.checkered", "Source", .shell("rg -n 'Feature::|Pennant' app routes config 2>/dev/null || true")),
                a("Pennant Configuration", "Inspect the configured feature flag store.", "gearshape.fill", "Inspect", .shell("test -f config/pennant.php && sed -n '1,240p' config/pennant.php || true"))
            ]
        case .deployment:
            return [
                a("Composer Validate", "Validate composer.json and its lock file.", "checkmark.shield.fill", "Validate", .shell("composer validate --no-check-publish")),
                a("Production Audit", "Run tests, inspect migrations and verify the working tree.", "checklist", "Preflight", .shell("php artisan test && php artisan migrate:status && git status --short --branch")),
                a("Optimise", "Build production framework caches.", "bolt.fill", "Prepare", .artisan("optimize")),
                a("Frontend Build", "Compile production frontend assets.", "hammer.fill", "Build", .shell("npm run build")),
                a("Security Audit", "Check Composer dependencies for advisories.", "lock.shield.fill", "Audit", .shell("composer audit")),
                a("Maintenance Mode", "Open controlled deployment maintenance settings.", "wrench.and.screwdriver.fill", "Open", .navigate(.maintenance))
            ]
        case .maintenance:
            return [
                a("Status", "Check whether the application is in maintenance mode.", "info.circle", "Inspect", .shell("test -f storage/framework/down && echo 'Maintenance mode enabled' || echo 'Application is live'")),
                a("Enable Maintenance", "Place the application into maintenance mode.", "lock.fill", "Destructive", .artisan("down --refresh=15"), true),
                a("Secret Bypass", "Enable maintenance mode with a generated bypass secret.", "key.fill", "Destructive", .artisan("down --with-secret"), true),
                a("Disable Maintenance", "Return the application to normal operation.", "lock.open.fill", "Apply", .artisan("up"))
            ]
        case .architecture:
            return [
                a("Application Tree", "List Laravel application source grouped by directory.", "square.3.layers.3d", "Source", .shell("find app -maxdepth 3 -type f | sort")),
                a("Routes", "Open the route inspector.", "arrow.triangle.branch", "Open", .navigate(.routes)),
                a("Models", "Open the Eloquent model inspector.", "cube.transparent", "Open", .navigate(.models)),
                a("Events", "Open event and listener controls.", "point.3.connected.trianglepath.dotted", "Open", .navigate(.events)),
                a("Tests", "List project test files.", "checkmark.seal", "Source", .shell("find tests -type f | sort")),
                a("Modules", "Discover modular application directories and manifests.", "square.stack.3d.up.fill", "Source", .shell("find Modules modules -maxdepth 3 -type f 2>/dev/null | sort | head -400"))
            ]
        case .storage:
            return [
                a("Storage Link", "Create the public storage symbolic link.", "link", "Apply", .artisan("storage:link")),
                a("Writable Paths", "Check Laravel writable directories and permissions.", "checkmark.shield.fill", "Inspect", .shell("for p in storage bootstrap/cache; do test -w \"$p\" && echo \"✓ $p writable\" || echo \"✕ $p not writable\"; done")),
                a("Disk Usage", "Show project storage and log sizes.", "chart.bar.doc.horizontal", "Inspect", .shell("du -sh storage storage/logs 2>/dev/null || true")),
                a("Configured Disks", "List Laravel filesystem disks.", "externaldrive.fill", "Inspect", .shell("php -r '$c=require \"config/filesystems.php\"; print_r(array_keys($c[\"disks\"]??[]));'")),
                a("Clear Compiled Views", "Remove compiled Blade templates.", "trash", "Clear", .artisan("view:clear"))
            ]
        case .apiCentre:
            return [
                a("API Routes", "List routes whose URI begins with api/.", "network", "Inspect", .artisan("route:list --path=api")),
                a("Route Inspector", "Search all route methods, middleware and actions.", "arrow.triangle.branch", "Open", .navigate(.routes)),
                a("Sanctum Status", "Inspect installed API authentication support.", "lock.shield.fill", "Inspect", .shell("composer show laravel/sanctum 2>/dev/null || true")),
                a("API Tests", "Run tests commonly stored under API paths.", "checkmark.seal.fill", "Test", .artisan("test --filter=Api")),
                a("Rate Limiters", "Find named rate limit definitions.", "speedometer", "Source", .shell("rg -n 'RateLimiter::for' app routes 2>/dev/null || true"))
            ]
        case .mailPreview:
            return [
                a("Mail Configuration", "Review mailer and sender variables with secrets masked.", "envelope.fill", "Inspect", .shell("grep -E '^MAIL_' .env 2>/dev/null | sed 's/=.*/=<masked>/'")),
                a("Mailables", "Discover application mailable classes.", "envelope.open.fill", "Source", .shell("find app -type f -path '*/Mail/*' | sort")),
                a("Notifications", "Discover application notification classes.", "bell.fill", "Source", .shell("find app -type f -path '*/Notifications/*' | sort")),
                a("Queued Mail", "Open queue controls for queued messages and notifications.", "tray.full.fill", "Open", .navigate(.queue)),
                a("Mail Views", "Find Blade views used by mail and notifications.", "doc.richtext.fill", "Source", .shell("find resources/views -type f \\( -path '*/mail/*' -o -path '*/emails/*' \\) | sort"))
            ]
        case .aiInspector:
            return [
                a("AI Package", "Inspect the installed Laravel AI SDK package and version.", "brain.head.profile", "Inspect", .shell("composer show laravel/ai 2>/dev/null || composer show | grep -i ai || true")),
                a("Provider Configuration", "Find AI provider variables while masking values.", "key.viewfinder", "Inspect", .shell("grep -Ei '^(OPENAI|ANTHROPIC|GEMINI|OLLAMA|AI_)' .env 2>/dev/null | sed 's/=.*/=<masked>/'")),
                a("Agents & Tools", "Find agent, tool and AI-related source classes.", "wand.and.stars", "Source", .shell("rg -l 'Agent|Tool|Embedd|OpenAI|Anthropic' app config routes 2>/dev/null | sort")),
                a("AI Tests", "Run tests whose names reference agents or AI.", "checkmark.seal.fill", "Test", .artisan("test --filter=AI"))
            ]
        }
    }

    private func a(_ title: String, _ detail: String, _ symbol: String, _ badge: String, _ command: ControlCommand, _ destructive: Bool = false) -> ControlAction {
        ControlAction(title: title, detail: detail, symbol: symbol, badge: badge, command: command, destructive: destructive)
    }
}
