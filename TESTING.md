# ABSDEV Studio Tests

The project now includes an `ABSDEVStudioTests` Swift Package test target.

## Coverage

- `LaravelProject` JSON persistence, including custom symbol, colour, and imported-icon path.
- Project loading, default-project creation, selection, removal, and persistence.
- Project icon selection and reset, including deletion of copied icon files.
- Conditional Sail and ServBay navigation visibility.
- Project-switch state isolation.
- Artisan command namespace and usage parsing.
- Test failure report titles.
- ANSI terminal-output cleaning and common string helpers.
- Native command execution, progress-dialog state, output capture, exit status, and failed-test reporting.
- Stable sidebar section identities and SF Symbol names.

## Run

From the project directory:

```bash
swift test
```

Or open `Package.swift` in Xcode and run **Product → Test**.

The standalone `ABSDEVStudio.xcodeproj` remains available for building the application. The package test target is intentionally kept in `Package.swift` so tests can run from Xcode and CI without modifying application signing settings.

## CI example

```bash
swift package resolve
swift test --parallel
```

The SwiftTerm package must be reachable or already present in Swift Package Manager's cache.
