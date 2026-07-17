# Native Open WebUI Integration

ABSDEV Studio includes a native SwiftUI client for a self-hosted Open WebUI server.

## Setup

1. In Open WebUI, enable API keys and create a key under **Settings > Account**.
2. In ABSDEV Studio, open **Settings > Open WebUI**.
3. Enter the server URL and API key.
4. Select **Test & Load Models** and choose a default model.
5. Open the dedicated **Open WebUI** menu or sidebar section.

The API key is stored in the macOS Keychain. Chat completions stream directly from the configured server using `/api/chat/completions`, and models are loaded from `/api/models`.
