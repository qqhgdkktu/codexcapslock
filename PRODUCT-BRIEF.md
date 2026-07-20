# Product brief: acknowledgement for completed Codex work

## User outcome

The Caps Lock LED should work like a quiet hardware notification, not like a keyboard mode that can become stuck. A user can see that Codex finished, inspect the result, dismiss the notification, and continue in another app without accidental uppercase input.

## State model

- `working`: blink every 0.5 seconds.
- `waiting`: steady light until the requested approval or answer is handled.
- `done / unread`: steady light until acknowledged.
- `off / read`: restore the LED to the real Caps Lock state.

Working has priority over waiting, waiting has priority over completed work, and acknowledgement removes only completed sessions.

## Acknowledgement paths

1. **Physical key:** a Caps Lock state transition while `done` acknowledges all completed sessions. If the transition enabled real Caps Lock, the daemon immediately returns it to `off`. The first press dismisses; later presses retain normal behavior.
2. **Viewed in Codex:** when Codex is frontmost for one second and the completion was visible for at least two seconds, it is acknowledged automatically.
3. **Explicit command:** `codex-capslock-indicator ack` provides a deterministic fallback for scripts and troubleshooting.

The `waiting` state is deliberately not dismissible because it represents outstanding user action rather than a passive notification.

## Constraints and anti-goals

- Never capture text or install a global keyboard event tap.
- Never require Accessibility or Input Monitoring permission.
- Never change real Caps Lock during blinking, waiting, focus acknowledgement, shutdown, or normal LED restoration.
- Do not add windows, menu-bar rendering, animations, network requests, analytics, or GPU work.
- Preserve foreign Codex hooks and the user's existing `notify` configuration.

## Success checks

- A physical Caps Lock acknowledgement ends with both the notification LED and real Caps Lock off.
- Foreground acknowledgement clears completed work but never clears waiting work.
- New work after an acknowledgement starts blinking normally.
- The daemon stays below 0.5% average CPU in a representative 12-second sample, below 25 MB physical footprint, and uses no GPU process.
- Hook latency stays within the 250 ms scheduler interval.
- Hooks do not spawn duplicate daemons while the singleton lock is held.
- Unit tests, release build, hardware self-test, lifecycle smoke test, installation, and GitHub CI all pass.
