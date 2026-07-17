# Native MCP Integration

ABSDEV Studio includes a native Streamable HTTP Model Context Protocol client.

- Configure trusted MCP servers in Settings > MCP.
- Bearer credentials are stored in the macOS Keychain.
- The MCP workspace negotiates capabilities, discovers tools, displays JSON schemas, and invokes tools with JSON arguments.
- Enabled tool metadata is added to the native Open WebUI system context together with the selected Laravel project.
- Supports JSON and SSE-formatted Streamable HTTP responses and legacy `Mcp-Session-Id` servers.

Only connect servers you trust. MCP tools can read external data and perform actions according to the permissions of the connected server.
