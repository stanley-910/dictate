# dictate

Minimal offline dictation for macOS: press a hotkey, talk, press again, and the
transcript is pasted at the cursor. Runs Cohere Transcribe (GGUF) on Metal via
[transcribe.cpp](https://github.com/handy-computer/transcribe.cpp). No cloud, no
account, no settings UI. Configuration lives in `~/.config/dictate/config.json`
(tracked in dotfiles as the `dictate` stow package).

## Layout

- `Sources/dictate/` — the app: hotkey tap, mic capture, model wrapper, paste.
- `Vendor/TranscribeCpp/` — upstream Swift binding, vendored verbatim (Apache 2.0).
- `Vendor/TranscribeCpp.xcframework/` — prebuilt native library, not tracked; `scripts/fetch-deps.sh`.
- `Resources/Info.plist` — bundle metadata and the microphone usage string.
- `scripts/` — fetch deps, fetch model, make signing cert, build bundle, install.

## Setup

```sh
scripts/fetch-deps.sh          # xcframework into Vendor/
scripts/fetch-model.sh q8      # 2.4 GB GGUF into ~/.local/share/dictate/models
scripts/make-cert.sh           # one-time self-signed "dictate-dev" identity
scripts/build-app.sh           # swift build -c release + dist/Dictate.app, signed
scripts/install.sh             # copy to ~/Applications, load launchd agent if present
```

First launch asks for Accessibility (hotkey tap and Cmd-V) and Microphone.
Both grants are keyed to the `dictate-dev` signature, so rebuilds keep them.

## Use

- Hotkey (default Control+Space) starts recording; the menu bar dot turns red.
- Same hotkey stops, transcribes, and pastes.
- Escape while recording cancels and never reaches the frontmost app. Past
  `cancelConfirmAfterSeconds` (default 10) the first Escape only arms (dot
  turns yellow); a second within 2 s cancels. Set 0 for single-press.
- `mode: "hold"` records only while the key is held. `holdHotkey` adds a
  second key that is always push-to-talk, e.g. `"right_command"` or `"fn"`,
  alongside the toggle key.
- `modifiers` maps a modifier held while the transcript is delivered to an
  action: `paste`, `copy` (clipboard only) or `send` (paste, then Return).
  Default `{"shift": "copy", "option": "send"}`; `command` is also accepted.
  `restoreClipboard: false` leaves the transcript on the clipboard after
  pasting. `capitalize: true` uppercases the first letter.
- `muteWhileRecording: true` mutes system output for the recording and
  restores it after.
- `sounds: false` silences everything; `soundPack` names a sound per event
  (`start`, `stop`, `cancel`, `arm`), each a name from /System/Library/Sounds
  or a file path; `null` skips that one.
- A floating pill above the Dock shows a live waveform while recording
  (`indicator: false` hides it).
- Microphone: menu bar > Microphone. The pick is stored in app defaults;
  `microphone` in config is the fallback when nothing is picked.
- The model loads on first use (about 1 s) and unloads after `unloadAfterSeconds`
  idle, so the resident process is a few MB between sessions.
- `dictionary` is a list of correct spellings (names, tools, jargon). Each
  is matched fuzzily against the transcript after recognition, ignoring
  case, spaces and punctuation, so `"Neovim"` fixes "neo vim" and "Neo-Vim",
  and `"GGUF"` fixes "G G U F". `dictionaryThreshold` (default 0.8) is the
  minimum similarity; near misses are logged. The model itself cannot be
  biased (transcribe.cpp's prompt feature is Whisper-only), so this is a
  post-pass.
- `replacements` run after the dictionary: whole-word, case-insensitive,
  in order; set `"regex": true` on an entry to use a regular expression.
  Use these for rewrites that are not spelling fixes, e.g. "pie" -> "Pi".
- Config keys that are missing take their defaults, so `{}` is valid.
  The file is watched: edits apply within about 2 s without a restart, and
  hotkey changes rebind. A recording in progress is never interrupted.

Commands:

```sh
dictate                    # daemon (what launchd runs)
dictate transcribe f.wav   # offline check without the mic
dictate fix "neo vim"      # apply dictionary + replacements to text
dictate mics               # list input devices
dictate config             # config path and effective values
```

Service on/off:

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/cc.stanleywang.dictate.plist
launchctl bootout gui/$(id -u)/cc.stanleywang.dictate
```

Logs: `~/.local/state/dictate/dictate.log`.

## Model

`handy-computer/cohere-transcribe-03-2026-gguf` on Hugging Face, converted from
Cohere's Apache-2.0 release. `fetch-model.sh` pins the revision and verifies
SHA-256 for Q8_0.
