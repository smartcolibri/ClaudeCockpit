# SCALE — Moving Cockpit for Claude to an industrial, collaborative workflow

Status: **proposal** (2026-10-10, rewritten from the Walkman Sports version of 2026-10-07). Nothing below has been applied on GitHub yet; it waits for the decisions in section 2.

Context: the app is becoming **Cockpit for Claude**, a free Mac App Store product of **Smart Colibri** (proprietary license). The repository moved to the `smartcolibri` organization on the **GitHub Team** plan on 2026-10-09. The product plan itself (rebrand, sandbox, App Store) lives in `PLAN.md` phases 9-13; this document covers *how the work is organised*, not *what* is built.

## 1. Current state (checked 2026-10-10)

| Area | Today |
|---|---|
| Code | `smartcolibri/ClaudeCockpit`, **public** until the 1.2.0 bridge release has reached installed copies, then **private**. One collaborator: Vincent |
| Plan | GitHub **Team** → branch protection, rulesets, required reviews, CODEOWNERS, org-level Projects and private Pages are all available |
| Workflow | 24 PRs, topic branches, conventional commits, squash merges by habit — but merge commits and rebase merges are still allowed, and merged branches are **not** auto-deleted |
| `main` | **Not protected**, no ruleset |
| Task tracking | `TODOS.md` + `PLAN.md` (git-ignored). **0 issues**, default labels only, no milestones, no Projects board |
| Project memory | `MEMORY.md`, `CHANGES.md`, `PLAN.md`, `TODOS.md`, `COMMANDS.md` — git-ignored, visible to Vincent only |
| Specs / plans | Tracked in `docs/superpowers/specs` |
| Conventions | Repo `CLAUDE.md` and `CONTRIBUTING.md` are tracked (good). `CONTRIBUTING.md` now says outside contributions are not accepted — to reword once Smart Colibri has collaborators |
| Tests / build | 320 tests (`swift test` in `CockpitCore`) + `xcodebuild`, run only on Vincent's Mac. No `.github/` folder, no CI |
| Releases | `Scripts/release.sh` run locally: Developer ID signing, notarization, DMG, Sparkle EdDSA signature, appcast. Tags `v1.0.0`…`v1.1.5` + GitHub Releases. The DMG line ends with 1.2.0; the App Store pipeline does not exist yet (`PLAN.md` phase 12) |
| Landing page | GitHub Pages from `docs/` in the same repo (published on merge to `main`). Copies on `lauriat.fr` (manual FTP upload) and `vincentlauriat.github.io` (manual PR) |
| Apple | **Individual** Apple Developer account, team `KFLACS69T9`. Two identical "Developer ID Application" certificates in Vincent's keychain (Jan 2026 and Oct 7 2026) make `codesign` ambiguous; `release.sh` now needs `SIGNING_IDENTITY=<SHA-1>` |
| Secrets | All on Vincent's Mac: Sparkle EdDSA private key (keychain + backup), notarytool profile `AppliMacVincentGithub`, signing certificates |

## 2. Decisions needed first

### 2.1 Protecting `main` — now possible, but sized for one person

The Team plan removes the blocker the Walkman Sports version hit (no protection on a private Free repo). The trap is the opposite one: **a rule requiring one approving review blocks a solo developer**, since GitHub does not let you approve your own PR.

- **Recommended now**: ruleset on `main` — PR required, linear history, green CI required, **0 required approvals**, no force push, no deletion; organization admins may bypass in an emergency.
- **When a second person joins**: raise to 1 approval + CODEOWNERS review.

### 2.2 Who the collaborators are (humans, agents, or both)

- **Agents** (Claude Code sessions, CI bots): need the conventions in the repo (`CLAUDE.md` / `AGENTS.md`) and a CI that checks their PRs — nothing else.
- **Humans**: Smart Colibri employees, freelancers, or occasional testers. This drives three follow-up questions:
  - **IP assignment** — the product is proprietary and owned by Smart Colibri: any human contributor needs a written agreement assigning their work to Smart Colibri *before* their first commit. Not needed for agents working on Vincent's behalf.
  - **Apple access** — anyone who must sign, run the sandboxed build on their own Mac with Vincent's team, or touch App Store Connect needs access to the Apple account. An individual account is limited here (to verify on developer.apple.com for the current rules); an **Organization** account (D-U-N-S for Smart Colibri) is the clean answer and also puts the company, not Vincent, as the App Store seller.
  - **Seats** — each human member of `smartcolibri` is a paid Team seat; outside collaborators on a single private repo are an alternative for occasional help.

### 2.3 Exception to the local-docs rule

The workspace rule (`~/DevApps/CLAUDE.md`, mirrored in `~/Documents/GitHub/CLAUDE.md`) keeps COMMANDS / MEMORY / CHANGES / TODOS / PLAN out of git. With collaborators, the shared part has to move to GitHub (section 3). Either an explicit exception for this project, or an edit to both mirrors.

### 2.4 CI runner

macOS minutes on a private repo are billed at a multiplier over Linux minutes and eat into the Team plan's included minutes quickly (check the current numbers at https://github.com/pricing). Options:
- **GitHub-hosted macOS runner** — zero maintenance; keep the job lean (`swift test` + one `xcodebuild`), cache SwiftPM.
- **Self-hosted runner on Vincent's Mac** — free and has the right Xcode, but CI stops when the Mac is off, and a self-hosted runner must never be attached to a public repo (wait until the repo is private).
- **Split** — Linux can't build this app, so there is no cheap half; pick one of the two above.

## 3. Mapping local files to GitHub

| Local file | GitHub equivalent |
|---|---|
| `TODOS.md` | **Issues** with area labels (`area:usage`, `area:sessions`, `area:quotas`, `area:rtk`, `area:skills`, `area:sandbox`, `area:app-store`, `area:landing`, `area:release`), a `needs-device-test` label for checks on a clean Mac account, **milestones** per version (`1.2.0 bridge`, `2.0 App Store`), and an **org-level Projects board** in `smartcolibri` (To do / In progress / In review / Done) that can later span several products. The board needs `gh auth refresh -s project` first. |
| `PLAN.md` | One epic issue per phase (9 rebrand, 10 bridge, 11 sandbox, 12 App Store readiness, 13 launch) with sub-issues; detailed specs stay tracked in `docs/superpowers/specs`. |
| `CHANGES.md` | Tracked `CHANGELOG.md`, `vX.Y.Z` tags and **GitHub Releases** with notes generated from PR labels (`.github/release.yml`). App Store "What's New" text derived from the same notes. |
| `MEMORY.md` | Split: lasting decisions → `docs/decisions/` (one record each: proprietary license, App Store-only distribution, Quotas removal, Pages-hosted feed…) or `ARCHITECTURE*.md`; live status → the Projects board. |
| `COMMANDS.md` | Stays local — personal log. |

## 4. Files to add to the repo

- **Issue forms**: bug (macOS version, app version, App Store or DMG build, which source: usage / sessions / RTK / skills), feature request, sandbox/permission problem, device test.
- **PR template**: what, why, screenshots for UI changes, tests run, "touches `~/.claude` writes?" checkbox (SkillsKit is the only writer and must back up first).
- **`CODEOWNERS`**: everything → Vincent; `Scripts/`, `project.yml`, entitlements and `*.xcconfig` always reviewed by Vincent.
- **`CONTRIBUTING.md`**: reword for internal contributors (Xcode version, xcodegen, `Local.xcconfig`, commit and PR conventions, IP agreement reminder).
- **`AGENTS.md`**: the project-relevant workspace rules, so collaborators' agents follow the same conventions (repo `CLAUDE.md` can point to it).
- **`Local.xcconfig`** (git-ignored, with a tracked `Local.xcconfig.example`): per-person `DEVELOPMENT_TEAM` and signing overrides.
- **`.github/dependabot.yml`**: SwiftPM updates (SQLite.swift, and Sparkle while the DMG line exists).

## 5. Automation (GitHub Actions)

1. **Build + tests on every PR** — `xcodegen generate`, `xcodebuild` Debug with `CODE_SIGNING_ALLOWED=NO`, `swift test` in `CockpitCore`. Pin the Xcode version explicitly and use a stable (non-beta) Xcode: the same rule as for releases. Required status check in the ruleset (2.1).
2. **Landing page** — nothing to automate in the repo: Pages already publishes `docs/` on merge. Automate the two copies instead (lauriat.fr FTP upload, `vincentlauriat.github.io` row), or retire them in favour of a single Smart Colibri site.
3. **App Store / TestFlight upload (phase 12)** — a `v*` tag archives, exports and uploads with an **App Store Connect API key** stored as an organization secret. No Developer ID, notarization or Sparkle steps: the App Store build doesn't use them.
4. **Secrets hygiene** — the Sparkle EdDSA private key is needed only until the final informational appcast item is published (phase 13); never put it in CI. The Developer ID certificates stay on Vincent's Mac. Remove the duplicate certificate from the keychain (Vincent's call) so `release.sh` works again without `SIGNING_IDENTITY`.

## 6. Repository settings

- Auto-delete branches after merge (today: off).
- Squash merge only (today: merge commits and rebase merges are also allowed), PR title in conventional-commit format → linear `main` history.
- Ruleset on `main` as in 2.1.
- Disable the wiki (unused); keep issues and projects on.
- Topics: replace `sparkle` once the DMG line ends; add `mac-app-store`.
- Organization defaults (Team plan): members can't create public repos, 2FA required for members (currently off), default repository permission `read`.

## 7. Proposed order

0. **Finish phase 10**: publish the 1.2.0 bridge release (GitHub Release + appcasts + DMG under `docs/downloads/`), verify the Sparkle update end to end from 1.1.5, update `lauriat.fr`, then switch the repo to **private**. Merge PR #23 (rebrand) after that.
1. Make the decisions in section 2.
2. Repo and organization settings (section 6), labels, milestones, Projects board; convert `TODOS.md` items and `PLAN.md` phases 11-13 into issues.
3. `.github/` files (forms, PR template, `CODEOWNERS`, `dependabot.yml`), `AGENTS.md`, reworded `CONTRIBUTING.md`, `Local.xcconfig.example`.
4. CI: build + tests on PRs, made a required check.
5. App Store upload workflow (with phase 12).
6. First collaborator only once the IP agreement and the Apple access question (2.2) are settled.

Once the decisions are made, the detailed implementation plan goes into `PLAN.md`.
