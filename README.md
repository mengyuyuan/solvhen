# Solvhen

> A phone that thinks. Not a chatbot — an AI agent that lives on your device.

Solvhen is an open-source Android AI agent built with Flutter. It can see your screen, control your phone, modify its own UI in real time, and remember everything you've told it. Think of it as an operating system for AI on mobile.

> **世于我愿** — "What I wish upon the world."

## What Makes It Different

| Typical AI App | Solvhen |
|---|---|
| Chat in a bubble | Modifies its own interface dynamically |
| Forgets everything between sessions | Persistent memory across conversations |
| Static theme | AI controls the theme, animations, and background |
| Text-only | Voice, tools, code execution, web search |
| No device access | Native Android bridge — clipboard, flashlight, screen, apps |

## Features

- **🛠 Tool System** — 27+ tools including file operations, web search, code execution, system control, clipboard, theme manipulation, and a WebView canvas for AI-generated UI
- **🧠 Memory Engine** — Cross-conversation memory with automatic consolidation. Remembers preferences, facts, and context
- **🎨 Dynamic UI** — AI controls particle effects, gradients, scanlines, and pulse rings. No templates — raw primitives the AI combines freely
- **🗣 Voice** — Edge TTS streaming with natural pauses. Speech-to-text input
- **🖼 WebView Canvas** — AI generates HTML/JS/CSS visualizations rendered in a native WebView
- **👤 Personality System** — Markdown-driven personality files (not hardcoded rules). The AI has biases, blind spots, and inconsistency — by design
- **📱 Android Native** — System-level access via platform channels: clipboard, flashlight, screen lock, app launching, volume, brightness
- **🔄 Streaming** — SSE-based streaming responses with real-time tool call display

## Architecture

```
lib/
├── main.dart                    # Entry point
├── screens/
│   ├── chat_screen.dart         # Main chat UI (Stack: WebView + messages)
│   ├── chat_provider.dart       # Riverpod state management
│   ├── agent_avatar.dart        # 8-state animated avatar engine
│   ├── ui_controller.dart       # AI-controlled UI state (colors, effects)
│   ├── webview_canvas.dart      # WebView rendering layer
│   ├── dynamic_background.dart  # AI-driven background effects
│   ├── particle_overlay.dart    # Particle system
│   ├── thinking_overlay.dart    # Thinking/processing indicator
│   ├── settings_screen.dart     # API config, changelog, voice settings
│   └── voice_chat_screen.dart   # Voice interaction mode
├── services/
│   ├── api_service.dart         # DeepSeek-compatible API (SSE + tools)
│   ├── database_service.dart    # SQLite (sqflite, WAL, migrations v1→v7)
│   ├── prompt_builder.dart      # System prompt assembly (persona + skills + memory)
│   ├── personality_loader.dart  # Markdown personality file loading
│   ├── skill_loader.dart        # Skill file loading from assets/
│   ├── tool_executor.dart       # Tool dispatch and execution
│   ├── voice_service.dart       # Voice pipeline (TTS + STT)
│   ├── edge_tts.dart            # Edge TTS streaming client
│   ├── notification_service.dart # Local notifications
│   └── sub_agent.dart           # Background agent delegation
├── tools/                       # 27+ tool implementations
│   ├── tool_registry.dart       # Tool registration and discovery
│   ├── native_bridge.dart       # Android platform channel bridge
│   ├── tools_code.dart          # Code execution
│   ├── tools_file.dart          # File read/write/list
│   ├── tools_web.dart           # Web search
│   ├── tools_web_extract.dart   # Web content extraction
│   ├── tools_system.dart        # System control (clipboard, screen, apps)
│   ├── tools_ui.dart            # Canvas, theme, effects control
│   ├── tools_memory.dart        # Memory CRUD
│   ├── tools_theme.dart         # Dynamic theme manipulation
│   ├── tools_history.dart       # Conversation history
│   └── tools_delegate.dart      # Sub-agent delegation
├── models/                      # Data models
├── commands/                    # Slash-command system
└── theme/                       # Theme provider
```

## Quick Start

### Prerequisites

- Flutter SDK ≥ 3.2.0
- Android SDK + device/emulator
- DeepSeek API key (or any OpenAI-compatible endpoint)

### Setup

```bash
# Clone
git clone https://github.com/mengyuyuan/solvhen.git
cd solvhen

# Get dependencies
flutter pub get

# Run on connected device
flutter run
```

### Configuration

1. Open the app on your device
2. Go to Settings → API Configuration
3. Enter your API endpoint and key:
   - **URL**: `https://api.deepseek.com/v1/chat/completions`
   - **Model**: `deepseek-chat` (or `deepseek-reasoner`)
   - **Key**: Your DeepSeek API key
4. (Optional) Configure voice settings

### Release Build

```bash
# Copy and edit the signing template
cp android/key.properties.example android/key.properties
# Edit key.properties with your keystore details

# Build
flutter build apk --release
```

## Tech Stack

| Layer | Technology |
|---|---|
| Framework | Flutter 3.2+ / Dart |
| State | Riverpod |
| Database | SQLite (sqflite, WAL mode, 7 migrations) |
| HTTP | Dio (SSE streaming) |
| Voice | Edge TTS + Flutter TTS + speech_to_text |
| Native | Platform channels (Kotlin) |
| WebView | webview_flutter 4.4+ |
| API | DeepSeek (OpenAI-compatible, supports function calling) |

## Design Philosophy

Solvhen was built around a few core ideas:

1. **Give primitives, not menus.** The AI doesn't pick from preset themes — it has access to raw drawing primitives (particles, gradients, polygons) and combines them freely.

2. **Fall forward, never crash.** Every AI-generated effect has a graceful fallback. If the canvas render fails, it falls through to the base theme layer. Nothing breaks.

3. **Personality is character, not rules.** The AI personality is defined in natural-language Markdown — not `IF-THEN` state machines. It has biases, blind spots, and inconsistencies that make it feel real.

4. **The phone is the interface.** Solvhen doesn't just live in a chat bubble — it controls the device. Clipboard, flashlight, screen brightness, app launching — these are all tools the AI can use.

## License

MIT © 2026 mengyuyuan

---

*Built with Flutter, powered by DeepSeek, driven by curiosity.*
