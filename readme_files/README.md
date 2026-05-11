# Agentic

Multi-backend LLM chat and orchestrator workbench. Originally a minimal,
Claude-style chat client for the Hugging Face Router API, the project has
grown into a Flutter desktop/mobile application that drives Hugging Face,
Groq, Gemini, OpenRouter, GitHub Models, and a local Python orchestrator —
with conversation history, sidebar, SQLite persistence, and per-conversation
model management.

No backend is required: the Flutter app is the client, the LLM provider you
pick is the backend.

---

## Features

- New chat button + persistent conversation sidebar (like Claude / ChatGPT)
- Full in-session history sent to the model on every request
- Local persistence on SQLite (token, saved models, conversations, messages)
- HF token stored locally only
- Model switcher per conversation + favorites
- Markdown rendering with syntax-highlighted code blocks and copy button
- Auto-resize input, Enter to send, Shift+Enter for newline
- Minimal, Claude-inspired theme

---

## Project layout

```
agentic/
  pubspec.yaml
  analysis_options.yaml
  lib/
    main.dart
    app.dart
    core/
      constants/api_constants.dart
      theme/app_theme.dart
    statemanagement/
      method_data.dart
      method_listener.dart
      state_manager.dart
      state_stream_factory.dart
    data/
      database/app_database.dart
      models/
        conversation.dart
        message.dart
        hf_model.dart
      repositories/
        conversation_repository.dart
        message_repository.dart
        model_repository.dart
        settings_repository.dart
    services/
      huggingface_service.dart
    ui/
      screens/
        home_screen.dart
        settings_screen.dart
      widgets/
        sidebar.dart
        chat_view.dart
        chat_input.dart
        message_bubble.dart
        code_block.dart
        model_switcher.dart
```

---

## Setup (step by step)

1. **Install Flutter 3.19+.**
   Verify with `flutter --version`.

2. **Create the platform scaffolding.**
   This project ships only the `lib/`, `pubspec.yaml` and `analysis_options.yaml`
   files. You need to generate the platform folders (`android/`, `ios/`,
   `windows/`, `linux/`, `macos/`, `web/`) in place:

   ```bash
   cd agentic
   flutter create . --project-name agentic \
     --platforms=windows,macos,linux,android,ios
   ```

   This preserves the existing `lib/` and `pubspec.yaml` while creating the
   missing platform folders.

3. **Install dependencies.**

   ```bash
   flutter pub get
   ```

4. **Run on desktop (recommended).**

   ```bash
   flutter run -d windows   # or macos / linux
   ```

   Mobile works too:

   ```bash
   flutter run -d android   # or ios
   ```

   Note: pure Flutter Web is not supported out-of-the-box because `sqflite`
   requires native or ffi. Desktop uses `sqflite_common_ffi` automatically.

5. **First-run configuration.**
   - Open the gear icon (top-left sidebar) to go to **Settings**.
   - Paste your Hugging Face token (`hf_...`) and press **Save**.
   - The default model `Qwen/Qwen3-Coder-480B-A35B-Instruct:hyperbolic` is
     pre-seeded; add more via the "Saved models" section.
   - Close Settings, press **New chat** in the sidebar, and type.

---

## Example: how a message is sent

`HuggingFaceService` rebuilds the full history on every call, identical to the
original `HF.html` behaviour:

```dart
await HuggingFaceService.instance.sendChat(
  token: token,
  modelId: modelId,
  history: _messages, // full in-memory history for the current chat
);
```

The service POSTs to `/v1/chat/completions` with:

```json
{
  "model": "Qwen/Qwen3-Coder-480B-A35B-Instruct:hyperbolic",
  "messages": [
    {"role": "user", "content": "..."},
    {"role": "assistant", "content": "..."},
    {"role": "user", "content": "..."}
  ]
}
```

---

## Memory model

- On chat open: messages are loaded from SQLite into `_messages` (in the
  `ChatView` state).
- On user send: the user message is persisted, then the **entire in-memory
  list** is sent to HF. The assistant reply is persisted as well.
- This mirrors the `messages.push(...)` + `messages: messages` pattern of the
  original HF.html.

---

## State management

This project uses the custom `statemanagement/` bus (your own pattern):

- Each stateful widget that needs to react to events extends
  `StateManager<T>` and implements `onMethodListener(MethodData)`.
- Cross-widget events are fired via
  `MethodListener<TargetWidget>().callMethod("name", params: {...})`.
- Scoped to one widget instance via `methodReceiverId`.

Key channels used in this app:
- `HomeScreen.openConversation` / `closeActiveConversation`
- `Sidebar.refreshConversations`
- `ChatView.modelChanged` / `conversationUpdated`

---

## Best practices adopted

- Clean layering: `ui` -> `services` -> `repositories` -> `database`.
- Single responsibility per file, classes exported completely.
- No hardcoded secrets: token lives in SQLite and is user-provided.
- Centralised config in `ApiConstants`.
- Dio timeouts + typed `HuggingFaceException` with status code and raw body.
- Foreign keys with `ON DELETE CASCADE` for message cleanup.
- Indexed SQLite columns for recent-first sorting.

---

## Next steps (not implemented in v1)

- Streaming responses (HF router supports SSE via `stream: true`)
- Dedicated artifact side panel for code (as in HF.html)
- Export chat (txt / md)
- File upload and analysis
- Light/dark theme switch
