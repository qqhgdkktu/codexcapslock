# Agent guide for Codex Caps Lock Indicator

This file is the operational contract for AI agents working with this repository. User-facing documentation is in [README.md](README.md) and [docs/USAGE.md](docs/USAGE.md).

## Purpose and supported environment

This is a native macOS SwiftPM executable that maps Codex lifecycle state to the built-in MacBook Caps Lock LED. It is supported on macOS 14 or newer and requires a built-in keyboard with a physical Caps Lock LED.

The indicator controls the raw HID LED output separately from logical Caps Lock. Preserve that invariant in every change.

## When asked to install or use it

1. Confirm the host is macOS and `codex`, `swift`, and `python3` are available.
2. Run the repository installer; do not manually rewrite `~/.codex/hooks.json`:

   ```bash
   python3 scripts/install.py
   ```

3. Verify the installed process and keyboard:

   ```bash
   ~/.local/bin/codex-capslock-indicator --version
   ~/.local/bin/codex-capslock-indicator status
   ~/.local/bin/codex-capslock-indicator self-test
   ```

4. Report the installed version, daemon PID, keyboard name, self-test result, and backup path printed by the installer.

The installer modifies user Codex configuration and briefly exercises hardware. Run it only when installation or live hardware verification is in scope. It preserves foreign hooks and the existing `notify` setting.

## User controls agents should know

```bash
# Read-only state
~/.local/bin/codex-capslock-indicator status
~/.local/bin/codex-capslock-indicator inspect-led

# Acknowledge completed work only
~/.local/bin/codex-capslock-indicator ack

# Visible but self-restoring hardware checks
~/.local/bin/codex-capslock-indicator self-test
~/.local/bin/codex-capslock-indicator demo
```

Do not use `hook`, `led`, or `raw-led` as normal user commands. They are lifecycle internals or low-level diagnostics.

## State contract

Priority is `working` over `waiting` over `done` over `off`.

| State | LED contract |
| --- | --- |
| `working` | 0.5 seconds on, 0.5 seconds off |
| `waiting` | Steady on until the user actually responds or approves |
| `done` | Steady on until acknowledged |
| `off` | Restore LED to the real logical Caps Lock state |

Acknowledgement removes only completed sessions. It must never hide `working` or `waiting` sessions.

For `done`, acknowledgement can come from Codex remaining frontmost, the `ack` command, or a physical Caps Lock transition. If that transition enabled logical Caps Lock, the daemon must immediately return logical Caps Lock to off and reconcile the physical LED.

## Safety invariants

- Never implement blinking with synthetic Caps Lock key presses.
- Never let notification state alter the user's typing case.
- Never add a global keyboard event tap, keystroke logging, Accessibility permission, or Input Monitoring permission.
- Never persist prompt text, assistant text, tool arguments, commands, or transcript paths in the indicator journal.
- Never replace or delete foreign Codex hooks or the user's `notify` configuration.
- Never add windows, animations, network calls, analytics, or GPU work for this indicator.
- On shutdown, installation failure, demo completion, or self-test completion, restore the LED to the actual logical Caps Lock state.

## Repository map

- `Sources/CodexCapsLockIndicator/IndicatorDaemon.swift`: scheduler, lifecycle aggregation, acknowledgement, LED application, shutdown.
- `Sources/CodexCapsLockIndicator/ActivityTracker.swift`: multi-session state and priority.
- `Sources/CodexCapsLockIndicator/CompletionAcknowledgementPolicy.swift`: pure acknowledgement timing and Caps Lock transition policy.
- `Sources/CodexCapsLockIndicator/RawHIDCapsLockController.swift`: raw HID output access.
- `Sources/CodexCapsLockIndicator/CapsLockModifierController.swift`: logical Caps Lock reset used only for physical acknowledgement.
- `Sources/CodexCapsLockIndicator/HookJournal.swift`: privacy-limited hook metadata transport.
- `Sources/CodexCapsLockIndicator/TranscriptMonitor.swift` and `CodexLogWatcher.swift`: fallback lifecycle sources.
- `scripts/install.py`: build, hardware verification, hook merge/trust, backup, installation.
- `scripts/uninstall.py`: scoped removal of this project's installation.

## Required verification for changes

For every code change:

```bash
swift test
swift build -c release
git diff --check
```

For lifecycle changes, add or update tests for state priority, stale turns, waiting behavior, acknowledgement, and journal privacy as applicable.

For changes to HID, acknowledgement, installation, or daemon lifecycle, and only when live hardware verification is authorized:

```bash
python3 scripts/install.py
~/.local/bin/codex-capslock-indicator self-test
~/.local/bin/codex-capslock-indicator status
```

Also verify:

- exactly one installed daemon remains;
- the release and installed binary hashes match;
- raw LED changes do not change logical Caps Lock;
- SIGTERM or app exit restores the normal LED;
- a real Codex lifecycle produces `working` and `done` hook records;
- CPU and physical footprint have not materially regressed.

Do not claim the task complete while required tests, GitHub Actions, or an explicitly requested push are pending.
