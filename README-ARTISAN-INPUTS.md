# Artisan structured command inputs

The Artisan workspace now keeps the selected command read-only and generates native SwiftUI controls from the selected project's discovered command usage:

- positional argument fields
- required/optional indicators
- repeatable argument indicators
- boolean option switches
- value-bearing option fields
- automatic shell-safe command construction
- embedded terminal fallback when a required value is omitted and Laravel provides an interactive prompt

Tinker and the base database console remain in their dedicated workspaces.
