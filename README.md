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
scripts/fetch-deps.sh          # transcribe.cpp v0.4.1 xcframework into Vendor/, SHA-256 checked
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
defaults delete cc.stanleywang.dictate                                  # microphone, style and mute picks, pill position
tccutil reset Accessibility cc.stanleywang.dictate
tccutil reset Microphone cc.stanleywang.dictate
security delete-identity -c dictate-dev                                 # if you ran make-cert.sh
```

## Use

- Hotkey (default Control+Space) starts recording; the menu bar dot turns red.
- Same hotkey stops, transcribes, and pastes. The next recording can start
  while the last is still decoding; transcripts land in the order their
  recordings stopped, pasted wherever the cursor is then, even mid-recording.
- Or hold the hotkey to talk: held past `holdToTalkAfterSeconds` (default
  0.4), letting go stops. A quicker tap toggles as above; 0 turns holding off.
  A lone-modifier toggle key (below) only taps.
- While another app has secure input on (a password field, Terminal's
  Secure Keyboard Entry), macOS hides every key from the hotkey tap. The
  idle dot dims, its tooltip says so, and the log names the app holding it.
- Escape while recording cancels and never reaches the frontmost app. Past
  `cancelConfirmAfterSeconds` (default 10) the first Escape only arms (dot
  turns yellow); a second within 2 s cancels. Set 0 for single-press.
- Long recordings are transcribed in pieces of at most `chunkSeconds`
  (default 30), cut at the quietest moment near the end of each piece. The
  model drifts and repeats itself on a single pass much past half a minute.
  The limit counts the audio after long pauses are shortened (see
  `maxPauseSeconds`), so a piece with long pauses in it covers more of the
  recording and there are fewer cuts: the model tends to end a sentence at
  each one.
  Pieces are decoded while you are still talking, so stopping leaves only the
  last one: the wait after stop stays about a second however long you talk.
  Set 0 to disable. A piece the model loops on (one phrase over and over
  until its token cap) is decoded again in halves; a piece that still fails
  shows as `[…]` and the rest of the recording is kept.
- A piece with no speech in it (silence, room noise, key clicks) is not
  decoded; on those the model makes up "Thank you." and the like. When a
  whole recording has none, nothing is pasted: the `nothing` sound plays,
  the pill's dot turns grey for a moment, and the log gets a line with the
  recording's loudness and input, to tell a dead mic from quiet speech.
- `maximumSeconds` (default 600) stops and transcribes a recording left
  running. `maximumWarnSeconds` (default 30) before that, the `warn` sound
  plays and the indicator turns purple; 0 turns the warning off.
- The last `keepRecordings` (default 5) recordings are kept in
  `~/.local/state/dictate/recordings/` as `<time>.wav` with a `.txt` beside
  it, owner-readable only; cancelled ones and one cut short by quitting
  included. `last.wav` and `last.txt` link to the newest. While recording,
  the audio and text so far are saved after each piece decodes, so a crash
  or forced quit keeps all but the last piece (about half a minute of
  speech); the next launch logs it.
  Menu bar > Copy Last Transcript copies the text again; Transcribe Last
  Recording decodes the audio again and copies the result; Recent Recordings
  copies an older one's text (hold Option to decode it again). 0 keeps none.
- Pauses longer than `maxPauseSeconds` (default 0.6) are shortened to it before
  decoding, since the model spends as long on silence as on speech. The log
  line shows how much audio was left. Set 0 to keep every pause.
- `mode: "hold"` records only while the key is held. `holdHotkey` adds a
  second key that is always push-to-talk, e.g. `"right_command"` or `"fn"`,
  alongside the toggle key.
- A single modifier as the hotkey (`"fn"`, `"right_command"`) counts only
  when pressed on its own, so Right-Command+C still copies. As a toggle key
  it acts on release, after a quick tap (under 0.5 s) with no other key or
  click in between. As a hold key it starts recording on press, so nothing is
  lost waiting; if another key or a click follows within 1 s, it was a
  shortcut and that recording is dropped without a sound or a saved copy.
  After 1 s of holding, a stray key is ignored and the recording goes on.
- `modifiers` maps a modifier held while the transcript is delivered to an
  action: `paste`, `copy` (clipboard only) or `send` (paste, then Return).
  Default `{"shift": "copy", "option": "send"}`; `command` is also accepted.
  Hold the modifier while pressing the stop key, or any time before the text
  lands; the hotkey still matches with a delivery modifier held.
  If a different app is frontmost when the text is ready than when the
  recording stopped, it is copied instead of pasted (or sent) and the `copied`
  sound plays; focus is not moved back. Paste it where you meant with Cmd-V.
  `restoreClipboard: false` leaves the transcript on the clipboard after
  pasting; with it on, `restoreClipboardAfterSeconds` (0.25) is how long the
  transcript stays there first, so a clipboard history manager can catch it.
  Anything copied during that wait is left in place.
  `casing` is `model` (as transcribed), `lower` (everything lowercase;
  dictionary terms keep their casing) or `sentence` (first letter uppercased).
  `endPeriod: false` drops the period that ends the transcript; periods inside
  it, `?`, `!` and `...` stay. Menu bar > Style picks a preset over both:
  Formal (as transcribed), Casual (no end period) or Very Casual (lowercase,
  no end period). The pick is stored in app defaults and overrides the config
  file.
- `cursorContext` (default true) reads the text just before the cursor
  through Accessibility before pasting. Right after a word, a digit or
  punctuation (`,` `.` `?` `!` `;` `:` or a closing quote or bracket) the
  transcript gets a leading space, unless it starts with punctuation itself.
  In the middle of a sentence (the last mark before the cursor is not `.`,
  `?`, `!`, a new line or the start of the field) its first word is
  lowercased, except "I", acronyms and mixed case ("API", "JavaScript"),
  dictionary terms, and code. Apps that do not expose the text (many
  terminals, Electron apps) get the transcript as it is. A first word is
  only lowercased when the spelling checker knows the lowercase form, so
  "Paris" and "Monday" keep their capital; names that are also words ("Bob",
  "Sam") do not, unless they are in `dictionary`.
- `muteSpeakersWhileRecording: true` mutes the speakers for the recording so
  music or a call does not reach the mic, and restores them after.
- `indicatorPosition` anchors the waveform pill: `bottom` (default), `top`,
  `top-left`, `top-right`, `bottom-left` or `bottom-right`, `indicatorMargin`
  points from the edge. Drag the pill to put it anywhere; the dragged spot
  sticks until `indicatorPosition` changes.
- The menu bar item has Copy Config Path for opening the file in an editor.
- `sounds: false` silences everything, as does menu bar > Mute Sounds (stored
  in app defaults); `soundPack` names a sound per event
  (`start`, `stop`, `cancel`, `arm`, `warn`, `copied`, `nothing`), each a name from /System/Library/Sounds
  or a file path; `null` skips that one.
- A floating pill above the Dock shows a live waveform while recording
  (`indicator: false` hides it).
- Microphone: menu bar > Microphone. The pick is stored in app defaults;
  `microphone` in config is the fallback when nothing is picked.
  `preferBuiltInMic: true` records from the built-in mic instead of a
  Bluetooth headset that is also playing the sound, so music or a call in
  the headset does not drop to call quality while the mic is open. A pick in
  the menu or `microphone` still wins.
- If the input goes dead mid-recording (exact digital silence for 0.5 s
  after sound, or 3 s from the start), it is reopened up to 3 times; after
  that, or at once if the device was unplugged, the recording carries on
  from the system default input, then the built-in mic, keeping what was
  already recorded. The log names each switch. A muted input is left alone.
- The model loads on first use (about 1 s) and unloads after `unloadAfterSeconds`
  idle, so the resident process is a few MB between sessions.
- `dictionary` is a list of correct spellings (names, tools, jargon). Each
  is matched fuzzily against the transcript after recognition, ignoring
  case, spaces and punctuation, so `"Neovim"` fixes "neo vim" and "Neo-Vim",
  and `"GGUF"` fixes "G G U F". `dictionaryThreshold` (default 0.8) is the
  minimum similarity; near misses are logged. The model itself cannot be
  biased (transcribe.cpp takes no prompt or vocabulary for Cohere), so this is a
  post-pass.
- `replacements` run after the dictionary: whole-word, case-insensitive,
  in order; set `"regex": true` on an entry to use a regular expression.
  Use these for rewrites that are not spelling fixes, e.g. "pie" -> "Pi".
- `codeNotation` (default true) writes spoken code talk as typed, after the
  replacements. Big-O: "O of n" -> `O(n)`, "O n log n" -> `O(n log n)`,
  "O of n squared" -> `O(n^2)`, "2 to the n" -> `2^n`, also `plus`, `times`,
  `factorial`, `square root of`; the phrase ends at the first word that is not
  math, so "big O notation" stays, and a spelled "one" alone only counts at
  the end of a clause or before a word like "time" or "lookups" ("oh of one
  thing" stays). Arithmetic: "4 minus 52" -> `4 - 52`, "i mod n" ->
  `i % n`, "x plus y times 2" -> `x + y * 2`, "x squared" -> `x^2` in a
  sum, "negative 48" -> `-48`; an operator needs an operand on each side, so
  "5 plus years" and "C plus plus" stay. Variables: a letter right after a type word
  ("the string s", "pointers i and j", "target k") is put in backticks, and
  so is every later standalone use of it. Letters never introduced that way
  ("plan B", "C") are left alone.
  Comparisons: "is less than" -> `<`, "is greater than or equal to" -> `>=`,
  "equals" / "is equal to" -> `==`, "is not equal to" / "does not equal" ->
  `!=`, "is at most" / "is at least" -> `<=` / `>=` (not after a number, so
  "5 at least" stays), "is set to" -> `=`; an undeclared capital letter does
  not compare ("Plan B is at least 2 hours" stays). Indexing, for a declared
  variable: "s of i" / "s at i" -> `s[i]`, "s of i plus 1" -> `s[i + 1]`.
  An expression that uses a declared variable is put in backticks whole:
  "s of i equals s of j" -> `` `s[i] == s[j]` ``. `codeSpans: true` puts
  every expression in backticks (`` `4 - 52` ``, `` `O(n)` ``), for Markdown.
  Identifiers: "camel case max depth" -> `` `maxDepth` ``, also "pascal
  case", "snake case", "kebab case" and "screaming snake case" / "constant
  case". The name runs to punctuation, a small word ("to", "and", "is", "the"
  ...) or four words, so "camel case max depth grows" takes "grows" too: pause
  with a comma, or end the name with "to", "and" and the like. A later "max
  depth" is written `` `maxDepth` `` as well. After "the", "a" or "in" the
  style is being talked about ("the camel case style", "I prefer snake case
  names") and nothing changes. A spoken identifier is not yet an operand:
  "camel case max depth equals 2" gives `` `maxDepth` equals 2``.
  Symbols: "x arrow y" -> `x -> y`, "x fat arrow x plus 1" -> `x => x + 1`
  (between operands, so "follow the arrow" and "an arrow function" stay);
  "std double colon vector" -> `std::vector` between two names (not after
  "a", "use" and the like); "dot dot dot" or the model's ". . ." -> `...`;
  "open paren a plus b close paren times c" -> `(a + b) * c`, "b open
  bracket i close bracket" -> `b[i]`, and around any words, "open paren in
  dollars close paren" -> `(in dollars)` (also "brace"), when the close
  follows within 16 words and "the", "a", "missing" do not come before.
- `layout` (default true) turns spoken layout into lines, after
  `codeNotation`. "bullet sort, next bullet scan" -> `- Sort` and `- Scan`
  on their own lines ("bullet", "new bullet", "next bullet", "bullet
  point"); "number 1 sort, number 2 scan" -> `1. Sort`, `2. Scan`; "new
  line" and "new paragraph" break the line once or twice. A list needs two
  items or more, numbered from 1, and ends at "new paragraph" or the end;
  text before it gets a colon, items drop their period and, unless `casing`
  is "lower", start with a capital. A word before or after that makes the
  trigger a noun leaves it alone: "the next bullet in the list", "bullet
  points are", "the number one reason", "a new line", "new line character",
  "the trailing newline".
- Menu bar > Dictionary (Cmd-D while the menu is open) edits `dictionary`
  in a window, one term per line; Save writes the config file (keys come
  out sorted and pretty-printed, a symlinked file stays a link).
- Menu bar > Cheat Sheet lists the plain replacements, then each phrase in
  `cheatSheet` with what the replacements turn it into now; picking a row
  copies the result. Handy for a spoken grammar built from regex rules,
  such as emoticons: `"cheatSheet": ["smile face", "wink tongue face"]`
  shows `:)` and `;P` beside them.
- Config keys that are missing take their defaults, so `{}` is valid.
  The file is watched: edits apply within about 2 s without a restart, and
  hotkey changes rebind. A recording in progress is never interrupted.

Commands:

```sh
dictate                    # daemon (what launchd runs)
dictate transcribe f.wav   # offline check without the mic (--live: play it in at real time)
dictate listen             # record until you stop talking, print the text
dictate fix "neo vim"      # apply dictionary + replacements to text
dictate mics               # list input devices
dictate config             # config path and effective values
```

`dictate listen` is for other programs (Recall's spoken review): it records
from the same microphone as the daemon, stops after speech and then
`--silence-ms` (2000) of quiet (speech is sound well above the room's own
noise, measured as it records, so a fan or air conditioner does not keep it
open; `--levels` prints each 100 ms block's level and the threshold to stderr), gives up after `--nothing-ms` (8000) with
nothing heard, and stops at `--limit-ms` (60000) regardless. Quiet is
anything under the speech threshold. SIGUSR1, or a headset's mute gesture
(an AirPods press, macOS 14's input mute handler; `--levels` prints `muted`), stops it and
transcribes what was recorded, like the hotkey's second press. It writes `ready`
to stderr once the mic is live, `stopped` once it is released (before
transcribing) and the transcript to stdout (empty when
nothing was said). SIGTERM or SIGINT stops it at once with no output (exit
143 or 130); errors are one line on stderr with exit 1. No sounds, pill, or
paste, and it runs alongside the daemon.

Logs: `~/.local/state/dictate/dictate.log` when not started from a terminal.

## Layout

- `Sources/dictate/` — the app: hotkey tap, mic capture, model wrapper, paste.
- `Tests/dictateTests/` — `swift test`: tables for the text rules (code
  notation, emoticon replacements), the speech gate, chunking and loop cuts.
- `Vendor/TranscribeCpp/` — upstream Swift binding, vendored verbatim (Apache 2.0).
- `Vendor/TranscribeCpp.xcframework/` — prebuilt native library, not tracked; `scripts/fetch-deps.sh`.
- `Resources/Info.plist` — bundle metadata and the microphone usage string.
- `scripts/` — fetch deps, fetch model, make signing cert, build bundle, install.

## Model

[`handy-computer/cohere-transcribe-03-2026-gguf`](https://huggingface.co/handy-computer/cohere-transcribe-03-2026-gguf)
on Hugging Face, converted from Cohere's Apache-2.0 release
([`CohereLabs/cohere-transcribe-03-2026`](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026)).
`fetch-model.sh` pins the revision and verifies SHA-256 for Q8_0.

## License

MIT, see [`LICENSE`](LICENSE). The vendored `Vendor/TranscribeCpp/` binding
keeps its own Apache 2.0 license.
