# dictate

Minimal offline dictation for macOS: press a hotkey, talk, press again, and the
transcript is pasted at the cursor. Runs Cohere Transcribe (GGUF) on Metal via
[transcribe.cpp](https://github.com/handy-computer/transcribe.cpp). No cloud, no
account, no settings UI. Configuration lives in `~/.config/dictate/config.json`
(or `$XDG_CONFIG_HOME/dictate/config.json`).

> **Work in progress.** This is an early-stage personal tool. It is macOS-only,
> there are no prebuilt releases, and config keys and defaults may change
> without a migration path. Expect rough edges.

## Quick start

### Requirements

- macOS 14 (Sonoma) or later.
- An Apple Silicon Mac. Inference runs on Metal; the prebuilt library is
  universal, but only Apple Silicon has been tried.
- Swift 6.0 or later: Xcode 16+ or the matching Command Line Tools.
- About 2.5 GB of disk for the default Q8_0 model (1.6 GB for Q4_K_M).
- Network access for the two fetch scripts only; after that it runs offline.
  `curl`, `shasum` and `openssl` from the base system are enough.

### Install

```sh
git clone https://github.com/stanley-910/dictate.git && cd dictate
scripts/fetch-deps.sh          # transcribe.cpp v0.2.3 xcframework into Vendor/, SHA-256 checked
scripts/fetch-model.sh q8      # 2.4 GB GGUF into ~/.local/share/dictate/models
scripts/make-cert.sh           # one-time self-signed "dictate-dev" identity
scripts/install.sh             # build dist/Dictate.app, copy to ~/Applications
open ~/Applications/Dictate.app
```

- `make-cert.sh` adds a code-signing certificate to your login keychain and
  may ask for your login password. It is optional: without it the app is
  ad-hoc signed and macOS asks for permissions again after every rebuild.
  `DICTATE_SIGN_IDENTITY` picks a different identity name.
- `scripts/build-app.sh` builds and signs `dist/Dictate.app` without
  installing; `scripts/install.sh --no-build` installs what is already there.
- `fetch-model.sh q4` gets the smaller Q4_K_M instead (no pinned checksum).
  The default `model` path points at Q8_0, so set `model` in the config to
  use it. `DICTATE_MODEL_DIR` changes the download directory.

### First launch

First launch asks for Accessibility (hotkey tap and Cmd-V) and Microphone.
Both grants are keyed to the `dictate-dev` signature, so rebuilds keep them.
Until Accessibility is granted the menu bar dot is dimmed; the app retries
every 2 s, so no restart is needed. No config file is required.

### Start at login (optional)

`scripts/install.sh` reloads a launchd agent if one exists at
`~/Library/LaunchAgents/cc.stanleywang.dictate.plist`. To create it:

```sh
cat > ~/Library/LaunchAgents/cc.stanleywang.dictate.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>cc.stanleywang.dictate</string>
  <key>ProgramArguments</key>
  <array><string>$HOME/Applications/Dictate.app/Contents/MacOS/dictate</string></array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
```

Service on/off:

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/cc.stanleywang.dictate.plist
launchctl bootout gui/$(id -u)/cc.stanleywang.dictate
```

### Command line

The `dictate` CLI is the binary inside the bundle. To put it on your `PATH`
(any directory on it works):

```sh
mkdir -p ~/.local/bin && ln -s ~/Applications/Dictate.app/Contents/MacOS/dictate ~/.local/bin/dictate
```

### Uninstall

Quit from the menu bar (or `launchctl bootout` as above), then:

```sh
rm -rf ~/Applications/Dictate.app ~/Library/LaunchAgents/cc.stanleywang.dictate.plist
rm -rf ~/.local/share/dictate ~/.config/dictate ~/.local/state/dictate  # model, config, logs
defaults delete cc.stanleywang.dictate                                  # microphone pick, pill position
tccutil reset Accessibility cc.stanleywang.dictate
tccutil reset Microphone cc.stanleywang.dictate
security delete-identity -c dictate-dev                                 # if you ran make-cert.sh
```

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
  Hold the modifier while pressing the stop key, or any time before the text
  lands; the hotkey still matches with a delivery modifier held.
  `restoreClipboard: false` leaves the transcript on the clipboard after
  pasting; with it on, `restoreClipboardAfterSeconds` (0.25) is how long the
  transcript stays there first, so a clipboard history manager can catch it.
  `casing` is `model` (as transcribed), `lower` (everything lowercase;
  dictionary terms keep their casing) or `sentence` (first letter uppercased).
- `muteSpeakersWhileRecording: true` mutes the speakers for the recording so
  music or a call does not reach the mic, and restores them after.
- `indicatorPosition` anchors the waveform pill: `bottom` (default), `top`,
  `top-left`, `top-right`, `bottom-left` or `bottom-right`, `indicatorMargin`
  points from the edge. Drag the pill to put it anywhere; the dragged spot
  sticks until `indicatorPosition` changes.
- The menu bar item has Copy Config Path for opening the file in an editor.
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

Logs: `~/.local/state/dictate/dictate.log` when not started from a terminal.

## Layout

- `Sources/dictate/` — the app: hotkey tap, mic capture, model wrapper, paste.
- `Vendor/TranscribeCpp/` — upstream Swift binding, vendored verbatim (Apache 2.0).
- `Vendor/TranscribeCpp.xcframework/` — prebuilt native library, not tracked; `scripts/fetch-deps.sh`.
- `Resources/Info.plist` — bundle metadata and the microphone usage string.
- `scripts/` — fetch deps, fetch model, make signing cert, build bundle, install.

## Model

[`handy-computer/cohere-transcribe-03-2026-gguf`](https://huggingface.co/handy-computer/cohere-transcribe-03-2026-gguf)
on Hugging Face, converted from Cohere's Apache-2.0 release
([`CohereLabs/cohere-transcribe-03-2026`](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026)).
`fetch-model.sh` pins the revision and verifies SHA-256 for Q8_0.
