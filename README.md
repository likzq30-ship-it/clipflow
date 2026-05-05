# ClipFlow

A lightweight macOS menu bar clipboard manager with AI-powered summarization and categorization via Ollama.

## Features

- **Clipboard History** — Automatically captures text copied to the macOS clipboard
- **Smart Categorization** — Built-in categories: URL, Email, Code, Number, Chinese, English, Mixed
- **AI Summarization** — One-click AI summary of clipboard content via local Ollama
- **AI Custom Categories** — Define custom categories with prompts; AI classifies content automatically
- **Search & Filter** — Full-text search and category-based filtering
- **Favorites** — Star important items to prevent them from being cleared
- **Configurable Retention** — Set history retention from 1 to 30 days
- **Global Hotkey** — Customizable keyboard shortcut to toggle the popover
- **Privacy First** — All data stored locally in SQLite; AI processing runs on your own machine

## Requirements

- macOS 13.0 or later
- Xcode 15.0+ (for building)
- [Ollama](https://ollama.com) (optional, for AI features)

## Installation

### Download

Download the latest release from the [Releases](https://github.com/your-org/clipflow/releases) page.

### Build from Source

```bash
# Clone the repository
git clone https://github.com/your-org/clipflow.git
cd clipflow

# Install dependencies & generate Xcode project (optional — .xcodeproj is committed)
# brew install xcodegen
# xcodegen generate

# Build
xcodebuild -project ClipFlow.xcodeproj -scheme ClipFlow -configuration Release build

# The app will be at:
# build/Release/ClipFlow.app
```

Or open `ClipFlow.xcodeproj` in Xcode and press Cmd+B.

## AI Features Setup

1. Install [Ollama](https://ollama.com)
2. Pull a model: `ollama pull qwen2.5:0.5b` (or any model you prefer)
3. Launch Ollama: `ollama serve`
4. In ClipFlow Settings → AI tab, configure the API URL (default: `http://localhost:11434`) and model name

## Usage

- ClipFlow runs in the menu bar
- Click the clipboard icon or press the global hotkey (default: ⌘⇧V) to open the popover
- Click any item to copy it back to the clipboard
- Use the search bar to find items
- Filter by category using the sidebar
- Star items to mark them as favorites
- Right-click the menu bar icon for settings and quit options

## Privacy

ClipFlow stores all clipboard data locally in a SQLite database at `~/Library/Application Support/ClipFlow/clipflow.sqlite3`. No data is sent to any server unless you configure AI features with a remote Ollama instance — and even then, only the content you explicitly choose to summarize or categorize is sent.

## License

MIT License. See [LICENSE](LICENSE) for details.
