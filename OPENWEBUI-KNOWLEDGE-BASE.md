# Open WebUI Knowledge Base Integration

The native Open WebUI workspace can now save AI material directly into the ABSDEV Studio Knowledge Base for the currently selected Laravel project.

## Manual actions

- Save an individual assistant response from its message card.
- Save the complete conversation from the workspace toolbar.
- Create a documentation-style Knowledge Base article from the conversation.
- Star a conversation so saved documents are marked as favourites.

Saved documents include the source, selected model, date, prompts, responses, inferred tags, and project association.

## Optional automation

Open WebUI Settings now provides:

- Automatically save completed conversations.
- Restrict automatic saving to starred conversations.
- Save as documentation-style articles.
- Save fenced code blocks as separate snippet documents.
- Infer Laravel and development tags.
- Limit the number of messages stored per conversation.

API credentials remain in the macOS Keychain. Knowledge documents use the existing Core Data / CloudKit Knowledge Base store.
