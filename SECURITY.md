# Security policy

## Supported versions

Security fixes are provided for the current `2.x` release line. Older source
installations should be upgraded before troubleshooting.

## Reporting a vulnerability

GitHub private vulnerability reporting is not currently enabled for this
repository. Until it is enabled, open a minimal public issue requesting a
private contact channel, without vulnerability details. Do not include
credentials, prompts, transcripts, private source code, exploit details, or
other user data in a public issue.

Repository maintainers should enable GitHub private vulnerability reporting
before publishing a hardened binary release. Once enabled, use the
**Security** tab, choose **Advisories**, then **Report a vulnerability**.

Include the affected version or commit, macOS and hardware model, the smallest
safe reproduction, and the observed impact. Reports involving the privileged
MagSafe helper, hook configuration ownership, runtime-file permissions, or
logical Caps Lock changes are treated as security-sensitive.

## Security boundaries

The project has no network client, analytics, Accessibility permission, Input
Monitoring permission, global keyboard event tap, or arbitrary privileged
command API. The root helper accepts only the versioned, allowlisted MagSafe
LED protocol from root or the active console user. Hook payloads are reduced to
bounded lifecycle metadata before durable storage.
