# Agent rules

- `swift test` runs the text-rule, audio-gate and chunking tables in
  `Tests/dictateTests`. Add a case for each behavior you change or fix.
- After each change is verified (it builds, `swift test` passes, and the
  behavior is checked), run `scripts/install.sh` so the running daemon and
  the `dictate` CLI use it, then commit it. No need to ask first.
- One commit per change. Keep unrelated work already in the tree in its own
  commit rather than folding it in.
- Commit messages follow the log: `feat:` or `fix:`, then one line saying
  what changed for the user and why.
