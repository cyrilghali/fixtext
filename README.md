# FixText

Fix the spelling, grammar and awkward phrasing of whatever text is selected, in any macOS app, in place. Press ⌃F and the selection is replaced by its corrected version.

It is one Swift file, no dependencies, no Xcode project. The app lives in the menu bar and does nothing until you ask.

## What makes it work in Slack?

macOS Services only reach Cocoa apps, so Electron apps ignore them. FixText takes both paths:

| Path | Trigger | Works in |
|---|---|---|
| Global hotkey | ⌃F | Everything, including Slack, VS Code, browsers |
| macOS Services | Right-click, Services, Fix Text | Cocoa apps, no synthetic keystrokes |

The hotkey path copies the selection, corrects it, and pastes it back. That needs Accessibility permission; the menu bar tells you whether it is granted.

## Which engine answers?

FixText tries Claude Haiku first. If it does not answer, it tries the local Ollama model:

| Engine | Latency | Needs |
|---|---|---|
| Resident `claude -p` session, Claude Haiku | ~1 s | Claude Code on a subscription |
| Ollama, `gemma3:4b` | ~3 s | Ollama running locally, works offline |
| `fix-text` CLI, one-shot `claude -p` | slow | Claude Code |

The resident Claude session keeps one process alive so boot and prompt cache are paid once, and recycles it every 30 fixes for a clean context.

## How do I install it?

```sh
git clone https://github.com/cyrilghali/fixtext.git
cd fixtext
./make-cert.sh   # once: a self-signed certificate, so Accessibility survives rebuilds
./build.sh       # builds ~/Applications/FixText.app and registers the service
open ~/Applications/FixText.app
```

For the CLI fallback, `cp fix-text ~/.local/bin/fix-text`.

Grant Accessibility to FixText in System Settings, Privacy & Security, and ⌃F starts typing.

## What does it refuse to change?

The prompt corrects spelling, grammar, accents and punctuation in English, French and other languages. It also smooths awkward phrasing, including non-native writing, while preserving meaning, tone and register. Mentions, emoji shortcodes, URLs and code pass through untouched. Texting shorthand is expanded into full words.

One thing is stripped before the model ever sees the text: the quote gutter a terminal drags along when you copy from it, the block glyph that prefixes every selected line.

## What is each file?

| File | Role |
|---|---|
| `main.swift` | The whole app |
| `build.sh` | Compile, sign, register the service |
| `make-cert.sh` | A self-signed code-signing identity, run once |
| `make-icon.swift` | Regenerate `FixText.icns` |
| `fix-text` | The one-shot CLI fallback |

MIT.
