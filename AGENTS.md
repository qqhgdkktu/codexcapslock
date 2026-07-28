# Agent guide for Codex Caps Lock Indicator

This file is the operational contract for AI agents working with this repository. User-facing documentation is in [README.md](README.md) and [docs/USAGE.md](docs/USAGE.md).

## Purpose and supported environment

This is a native macOS SwiftPM project that maps Codex and Claude Code lifecycle state to one hardware indicator at a time: a connected MagSafe 3 LED has priority, otherwise the built-in MacBook Caps Lock LED is used. It is supported on macOS 14 or newer and requires a built-in keyboard with a physical Caps Lock LED for fallback.

The Caps Lock indicator controls raw HID LED output separately from logical Caps Lock. Preserve that invariant. When MagSafe is selected, Caps Lock must be entirely normal and must not be used as acknowledgement input.

## When asked to install or use it

1. Confirm the host is macOS, `swift` and `python3` are available, and at least one of `codex` or `claude` is available.
2. Run the repository installer; do not manually rewrite `~/.codex/hooks.json` or `~/.claude/settings.json`:

   ```bash
   python3 scripts/install.py
   ```

3. Verify the installed process and keyboard:

   ```bash
   ~/.local/bin/codex-capslock-indicator --version
   ~/.local/bin/codex-capslock-indicator status
   ~/.local/bin/codex-capslock-indicator self-test
   ~/.local/bin/codex-capslock-indicator inspect-magsafe
   ```

4. Report the installed version, selected output, MagSafe connection/control state, daemon PID, keyboard name, self-test result, helper hash when installed, and backup path printed by the installer.

The installer modifies user Codex and Claude Code configuration and briefly exercises hardware. On a Mac with MagSafe 3, it also installs a root-owned C helper and LaunchDaemon after a protected macOS administrator dialog. Run it only when installation or live hardware verification is in scope. It preserves foreign hooks, settings, and the existing `notify` setting.

## User controls agents should know

```bash
# Read-only state
~/.local/bin/codex-capslock-indicator status
~/.local/bin/codex-capslock-indicator inspect-led
~/.local/bin/codex-capslock-indicator inspect-magsafe

# Acknowledge completed work only
~/.local/bin/codex-capslock-indicator ack

# Visible but self-restoring hardware checks
~/.local/bin/codex-capslock-indicator self-test
~/.local/bin/codex-capslock-indicator demo
```

Do not use `hook`, `led`, `raw-led`, or `magsafe` as normal user commands. They are lifecycle internals or low-level diagnostics.

## State contract

Priority is the earliest `done` session, then `waiting`, then `working`, then `off`. Acknowledgement removes one completion at a time in completion order.

| State | Selected LED contract |
| --- | --- |
| `working` | MagSafe firmware slow blink, or Caps Lock 0.5 seconds on / 0.5 seconds off |
| `waiting` | Steady on until the user actually responds or approves |
| `done` | Steady on until acknowledged |
| `off` | Restore MagSafe to system mode and Caps Lock to the real logical state |

Output priority is strict: connected and controllable MagSafe, otherwise Caps Lock. MagSafe presence requires a physical type-17 port with `ConnectionActive` and current external power; generic USB-C charging must not count.

Acknowledgement removes only the earliest completed session. It must never hide `working` or `waiting` sessions; after acknowledgement, expose the next completion or remaining actionable state.

For `done` on the Caps Lock output, acknowledgement can come from the `ack` command, a physical Caps Lock transition, or Codex remaining frontmost when the first completion belongs to Codex. If the key transition enabled logical Caps Lock, the daemon must immediately return logical Caps Lock to off and reconcile the physical LED. On MagSafe output, Caps Lock remains normal; Claude Code completion requires `ack` or activity resuming in that session because terminal focus is deliberately not monitored.

## Safety invariants

- Never implement blinking with synthetic Caps Lock key presses.
- Never let notification state alter the user's typing case.
- Never add a global keyboard event tap, keystroke logging, Accessibility permission, or Input Monitoring permission.
- Never persist prompt text, assistant text, tool arguments, commands, or transcript paths in the indicator journal.
- Never replace or delete foreign Codex or Claude Code hooks, settings, or the user's `notify` configuration.
- Never add windows, animations, network calls, analytics, or GPU work for this indicator.
- On shutdown, installation failure, demo completion, or self-test completion, restore the LED to the actual logical Caps Lock state.
- Always restore MagSafe to `system` on output change, shutdown, helper termination, demo completion, self-test completion, and uninstall.
- Keep the privileged helper command set fixed, authenticate the peer as root or the active console user, and never add arbitrary file, shell, or network operations.

## Repository map

- `Sources/CodexCapsLockIndicator/IndicatorDaemon.swift`: scheduler, lifecycle aggregation, acknowledgement, LED application, shutdown.
- `Sources/CodexCapsLockIndicator/ActivityTracker.swift`: causal lifecycle reducer, active generations, immutable completion queue.
- `Sources/CodexCapsLockIndicator/DaemonControl.swift`: private user control socket and single-owner maintenance routing.
- `Sources/CodexCapsLockIndicator/StateStore.swift`: atomic durable reducer snapshot and v1 journal migration.
- `Sources/CodexCapsLockIndicator/MagSafeConnectionDetector.swift`: physical type-17 MagSafe detection with external-power corroboration.
- `Sources/CodexCapsLockIndicator/MagSafeLEDController.swift`: bounded local UNIX-socket client.
- `Sources/CodexCapsLockMagSafeHelper/main.c` and `Sources/MagSafeSMC`: root helper and SMC `ACLC` access.
- `Sources/CodexCapsLockIndicator/ActivityTracker.swift`: multi-session state and priority.
- `Sources/CodexCapsLockIndicator/CompletionAcknowledgementPolicy.swift`: pure acknowledgement timing and Caps Lock transition policy.
- `Sources/CodexCapsLockIndicator/RawHIDCapsLockController.swift`: raw HID output access.
- `Sources/CodexCapsLockIndicator/CapsLockModifierController.swift`: logical Caps Lock reset used only for physical acknowledgement.
- `Sources/CodexCapsLockIndicator/HookJournal.swift`: bounded privacy-limited hook transport and offline spool.
- `Sources/CodexCapsLockIndicator/TranscriptMonitor.swift` and `CodexLogWatcher.swift`: legacy compatibility parsers retained for tests; the daemon does not use them by default.
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
- real Codex and Claude Code lifecycles produce source-tagged `working` and `done` hook records, with Claude session IDs namespaced away from Codex IDs;
- CPU and physical footprint have not materially regressed;
- connected MagSafe selects only MagSafe; unplugging restores system MagSafe and selects only Caps Lock;
- the root helper blocks in `accept`, has no polling loop, and rejects a non-console peer.

If a usable Claude Code account is unavailable, `MultiAgentLifecycleTests` is the required fallback: it replays official Claude hook JSON through the real journal writer/reader and verifies first-completion priority alongside a Codex session. Also run `python3 -m unittest discover -s scripts/tests` to validate idempotent, foreign-setting-preserving hook installation. State clearly that a live Claude `Stop` event remains unverified.

Do not claim the task complete while required tests, GitHub Actions, or an explicitly requested push are pending.
