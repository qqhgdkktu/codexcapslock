# GitHub Community Growth Design

**Date:** 2026-07-23
**Owner:** Mikita (`@qqhgdkktu`)
**Primary audience:** International macOS, AI-agent, CLI, Swift, and hardware-hacking enthusiasts
**Flagship repository:** `qqhgdkktu/codexcapslock`

## 1. Goal

Turn the GitHub profile and `codexcapslock` repository into a clear, credible, and shareable open-source showcase that encourages the right visitors to:

1. understand the project within a few seconds;
2. watch it work on real hardware;
3. install it safely;
4. star the repository if it is useful or interesting;
5. follow the author for future macOS and AI-agent tools.

The work will optimize for genuine community interest. It will not use bought stars, fake accounts, automated starring, engagement exchanges, unsolicited bulk messages, misleading claims, or other inauthentic activity.

## 2. Baseline

At the time of design:

- the account has two public repositories and no profile README;
- the public profile has no bio beyond the company and website fields;
- `codexcapslock` has one star, no repository description, no topics, no homepage, no release, and no custom social preview;
- its README accurately documents the implementation but leads with mechanics rather than the immediate user benefit;
- the available 14-day GitHub traffic window shows 10 unique views and 19 unique clones;
- the only reported external referrer is Threads, with three unique visitors.

This baseline is a snapshot, not a permanent metric. Traffic and engagement must be read again after publication.

## 3. Positioning

### Core promise

> Turn your MacBook's MagSafe and Caps Lock LEDs into a physical status light for Codex and Claude Code.

### Supporting story

The project makes invisible AI-agent state visible without opening another window:

- blinking means the agent is working;
- steady green means it needs attention or has finished;
- MagSafe 3 is preferred when connected;
- Caps Lock is the automatic fallback;
- typing state, prompts, commands, and responses remain untouched.

### Proof points

Claims used in public copy must be directly supported by the repository and current verification:

- native macOS Swift implementation;
- support for Codex and Claude Code lifecycle hooks;
- automatic MagSafe-to-Caps-Lock fallback;
- no cloud service, analytics, UI, Accessibility permission, Input Monitoring permission, or global keyboard event tap;
- multi-session completion ordering;
- installer that preserves unrelated hooks and settings;
- automated tests and a passing GitHub Actions workflow.

The undocumented MagSafe SMC interface must remain disclosed. It must not be presented as an official Apple API or guaranteed to work forever.

## 4. Conversion Funnel

The public experience will follow one deliberate path:

**shared link → social preview → README hero → real demo → compatibility check → install → successful first run → star/follow/contribute**

Each surface has one job:

- **Social preview:** earn the click with a distinctive physical-LED visual.
- **README hero:** explain the value in one sentence and show the result immediately.
- **Demo:** prove that the project works on real hardware.
- **Quick start:** remove uncertainty around installation.
- **Safety and compatibility:** answer the objections that could prevent installation.
- **Technical details:** reward deeper inspection without blocking the initial decision.
- **Community CTA:** invite a star, issue, discussion, or contribution without pressure.
- **Profile README:** turn project interest into interest in the author.

## 5. Repository Package

### 5.1 Repository metadata

Set an English description that includes both the visible result and supported tools:

> Physical MagSafe and Caps Lock status LEDs for Codex and Claude Code on macOS.

Add a focused set of discoverability topics:

- `macos`
- `swift`
- `codex`
- `claude-code`
- `magsafe`
- `caps-lock`
- `hardware`
- `developer-tools`
- `ai-agents`
- `menu-bar-alternative`

Do not add unrelated high-volume topics merely to appear in more searches.

### 5.2 README information order

Rewrite the primary README in English with this order:

1. project name and one-sentence promise;
2. CI, release, macOS, Swift, and license badges only when accurate;
3. real hardware demo video or compact GIF;
4. three short benefit bullets;
5. a visible but non-coercive “Star this repo” CTA;
6. compatibility table;
7. 30-second quick start;
8. state table;
9. acknowledgement behavior;
10. privacy and safety guarantees;
11. architecture overview;
12. troubleshooting and diagnostics links;
13. update and uninstall commands;
14. limitations and third-party attribution;
15. contribution invitation.

The first screen must avoid a wall of text. Detailed lifecycle and implementation behavior will remain available below the quick start and in `docs/USAGE.md`.

### 5.3 Demo asset

Record or create a short real-hardware demonstration, ideally 8–15 seconds:

1. show a Codex or Claude Code task running;
2. show the MagSafe LED blinking;
3. show the steady completion state;
4. optionally unplug MagSafe and show Caps Lock fallback;
5. end on the project name and GitHub URL.

The demo must not reveal prompts, private repository content, usernames, notifications, tokens, or unrelated screen data. It must not simulate hardware behavior that was not recorded or verified.

Use an optimized GIF only as a lightweight README fallback. Prefer a linked MP4 for clarity and file size, with a representative poster image stored in the repository.

### 5.4 Social preview

Create a 1280×640 image with:

- a dark macOS-oriented background;
- a close view of a green MagSafe LED and Caps Lock LED;
- the short title “Physical status lights for AI coding agents”;
- smaller labels for Codex, Claude Code, and macOS;
- high contrast and safe margins for link-card cropping.

Upload it through repository settings after visual inspection. Do not imply endorsement by Apple, OpenAI, or Anthropic, and do not use third-party logos in a way that suggests partnership.

### 5.5 Release and trust files

Prepare a first semantic release only after the current install and test path is verified. The release notes should explain:

- what the tool does;
- supported macOS and hardware;
- supported agents;
- installation and uninstall commands;
- the privileged MagSafe helper boundary;
- known limitations;
- the exact source commit.

Add or improve:

- an explicit open-source license compatible with existing third-party notices;
- `CONTRIBUTING.md`;
- issue templates for bug reports and feature requests;
- a security policy that gives a private reporting route if one is available;
- repository Discussions only if the owner intends to monitor and answer them.

License selection requires an explicit owner decision before publication because it changes the legal permissions granted to others.

## 6. GitHub Profile Package

Create the public profile repository `qqhgdkktu/qqhgdkktu` with a concise English README:

1. a one-line identity focused on useful macOS and AI-agent tools;
2. the flagship `codexcapslock` project with a demo image and benefit-led description;
3. a short “What I build” list;
4. links to GitHub projects and `chota.by`;
5. a “Follow for more” CTA.

Avoid decorative badge walls, inflated skill lists, auto-generated activity clutter, and claims that cannot be verified.

Pin `codexcapslock` first. Pin `codex-skillpack` only after it has a clear English description, audience, license, and README. With only two public repositories, quality matters more than filling all six pin slots.

Update public account metadata with a short English bio aligned to the profile README. Location, public email, and additional social accounts remain optional and require an explicit privacy decision.

## 7. Secondary Repository

`codex-skillpack` will receive a bounded packaging pass:

- concise English description;
- relevant topics;
- clear explanation of what is original versus bundled or adapted;
- installation and compatibility instructions;
- license clarity;
- link back to the author profile.

It will not share the flagship launch window unless its value proposition and installation path are independently ready. The indicator project remains the single launch focus.

## 8. Distribution Plan

Prepare platform-native launch material rather than posting the same advertisement everywhere.

### Show HN

Lead with the build and technical novelty:

> Show HN: I turned my MacBook's MagSafe LED into a status light for coding agents

The body should disclose the undocumented SMC interface, explain the Caps Lock fallback, and invite technical feedback.

### Reddit

Target only communities where self-promotion is permitted and the project is directly relevant. The post should show the demo first, explain how it was built, disclose author affiliation, and ask for feedback rather than stars.

### X and Threads

Use a short demo-led post with one clear hook, the repository link, and a brief technical detail. Avoid repeated tagging, mass mentions, engagement bait, and automated reposting.

### Relevant developer communities

Share only where the author already participates or where project sharing is explicitly allowed. Answer questions, publish fixes prompted by feedback, and return with meaningful updates rather than reposting the same launch.

### Launch sequence

1. finish repository packaging;
2. verify install from a clean checkout or representative fresh setup;
3. publish the release;
4. upload the social preview;
5. publish one primary launch post;
6. respond to early questions and fix genuine blockers;
7. adapt the strongest proof or explanation for the next community;
8. publish a substantive follow-up only after a meaningful update.

Exact subreddit and community selection must be checked against current rules immediately before posting.

## 9. Measurement

Record a baseline immediately before launch and compare it after 24 hours, 7 days, and 14 days:

- repository views and unique visitors;
- clones and unique cloners;
- stars;
- watchers;
- forks;
- followers;
- release downloads, if release assets exist;
- referrers and popular paths;
- install-related issues;
- successful installation confirmations;
- contributions or substantive technical feedback.

Use ratios to distinguish packaging problems from traffic problems:

- social click-through when platform analytics are available;
- stars per unique repository visitor;
- unique clones per unique visitor;
- reported successful installs per unique clone;
- issue rate per reported install.

GitHub's traffic API retains a limited rolling window, so snapshots should be saved locally or in an approved private reporting location. Public README badges must not expose private analytics or invent install counts.

No fixed star count is a completion criterion because external engagement cannot be guaranteed. Success means the launch surfaces are complete, technically accurate, visibly compelling, distributed to relevant communities, and producing measurable organic traffic.

## 10. Implementation Boundaries

### Authorized after plan approval

- edit repository documentation and community files;
- create non-sensitive visual assets;
- update repository descriptions and topics;
- create the public profile repository and README;
- create focused commits and push them;
- create a GitHub release after required verification;
- prepare launch posts as drafts;
- inspect public pages and repository traffic.

### Requires separate confirmation

- selecting and publishing a new software license;
- posting externally to Hacker News, Reddit, X, Threads, Slack, Discord, or other communities;
- exposing an email address, location, personal biography, or additional social accounts;
- enabling a community channel that creates an ongoing moderation obligation;
- changing repository visibility, ownership, name, or default branch;
- spending money on promotion;
- creating paid assets or using third-party copyrighted branding.

### Prohibited

- fake, purchased, automated, exchanged, or incentivized stars;
- sock-puppet accounts;
- bulk unsolicited messages;
- misleading compatibility or privacy claims;
- fake demo footage, fabricated metrics, or undisclosed affiliation;
- irrelevant issues, pull requests, comments, follows, or stars used for visibility.

## 11. Verification

Before repository changes are described as complete:

1. run the project-required checks:
   - `swift test`
   - `swift build -c release`
   - `git diff --check`
2. render and inspect the English README on GitHub;
3. verify every internal and external link;
4. check README readability on desktop and mobile widths;
5. verify the demo and social preview contain no sensitive information;
6. confirm repository description, topics, badges, and pinned items on the public pages;
7. verify the release commit and assets;
8. verify a fresh installation path when live hardware installation is in scope;
9. confirm all pushed commits and required GitHub Actions runs reach a terminal successful state;
10. capture the pre-launch traffic baseline.

After launch, measurement may show that positioning or distribution needs iteration. Any follow-up should change one major variable at a time—hook, demo, channel, or install friction—so the effect can be interpreted.
