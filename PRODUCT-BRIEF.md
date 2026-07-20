# Product brief: MagSafe-first Codex and Claude Code hardware indicator

## User outcome

One quiet hardware LED should show Codex or Claude Code state without trapping the user in Caps Lock. A connected MagSafe 3 has priority; otherwise the built-in Caps Lock LED is the fallback. The non-selected device remains under normal macOS control.

## Output selection

- `MagSafe connected + SMC helper available`: use only MagSafe; Caps Lock is a completely normal key and is not an acknowledgement control.
- `MagSafe disconnected`: restore MagSafe to `system` and use only the raw Caps Lock LED.
- `MagSafe helper unavailable`: fail visibly in status and retain the Caps Lock fallback.
- Generic USB-C external power never counts as a MagSafe connection.

## State model

- `working`: use MagSafe firmware slow blink or blink Caps Lock every 0.5 seconds.
- `waiting`: steady light until the requested approval or answer is handled.
- `done / unread`: steady light until acknowledged.
- `off / read`: restore MagSafe to system charging indication and Caps Lock to its real logical state.

The earliest unread completion has priority over waiting and working sessions. Each acknowledgement removes only that first completion, then exposes the next completion or the current state of remaining sessions.

## Acknowledgement paths

1. **Physical key, Caps Lock output only:** a Caps Lock state transition while `done` acknowledges the first completed session. If the transition enabled real Caps Lock, the daemon immediately returns it to `off`. This path is disabled while MagSafe is selected.
2. **Viewed in Codex:** when the first completion belongs to Codex and Codex is frontmost for one second after at least two seconds of visibility, it is acknowledged automatically. Terminal focus is not used for Claude Code.
3. **Explicit command:** `codex-capslock-indicator ack` provides a deterministic fallback for scripts and troubleshooting.

The `waiting` state is deliberately not dismissible because it represents outstanding user action rather than a passive notification.

## Constraints and anti-goals

- Never capture text or install a global keyboard event tap.
- Never require Accessibility or Input Monitoring permission.
- Never change real Caps Lock during blinking, waiting, focus acknowledgement, shutdown, or normal LED restoration.
- Never treat Caps Lock as acknowledgement input while MagSafe is selected.
- Restore `ACLC` to system mode on disconnect, shutdown, demo/self-test completion, helper termination, and uninstall.
- Keep the root helper local, fixed-command, active-console-user authenticated, and network-free.
- Do not add windows, menu-bar rendering, animations, network requests, analytics, or GPU work.
- Preserve foreign Codex and Claude Code hooks, settings, and the user's existing `notify` configuration.

## Success checks

- A physical Caps Lock acknowledgement ends with both the notification LED and real Caps Lock off.
- Connected MagSafe selects only MagSafe; unplugging selects only Caps Lock within the one-second detection interval.
- While MagSafe is selected, a Caps Lock press changes normal logical Caps Lock and does not acknowledge either agent.
- Foreground acknowledgement clears only the first Codex completion and never clears waiting work or a Claude Code completion.
- New work after an acknowledgement starts blinking normally.
- The user daemon stays below 0.5% average CPU in a representative 12-second sample, below 25 MB physical footprint, and uses no GPU process; the C helper blocks without polling.
- Hook latency stays within the 250 ms scheduler interval.
- Hooks do not spawn duplicate daemons while the singleton lock is held.
- Unit tests, release build, hardware self-test, lifecycle smoke test, installation, and GitHub CI all pass.
