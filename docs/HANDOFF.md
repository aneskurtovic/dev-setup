# Handoff - 2026-10-07

## Current state

- Latest published release: [v0.3.2-preview](https://github.com/aneskurtovic/dev-setup/releases/tag/v0.3.2-preview), pinned by both the README command and `quickstart.ps1`. Its implementation commit is `069eebd9cbd39541e0b0ac6e413a061aecdf862c`; later documentation-only commits can exist on `main` without moving this tag.
- The real public quickstart completed on the Windows 11 laptop with exit code 0: all 19 packages ready, selected repositories ready, workspace ready, and no pending workspace changes.
- Eight selected existing clones were preserved at their original paths. No repositories were cloned or moved. Selection is saved under `%LOCALAPPDATA%\DevSetup`.
- Ubuntu runs under WSL 2; the user completed its personal account setup. Docker Desktop runs, and a real `hello-world` container succeeded.
- [Main CI](https://github.com/aneskurtovic/dev-setup/actions/runs/37687732340) and [release-tag CI](https://github.com/aneskurtovic/dev-setup/actions/runs/37687883165) passed for the release commit. The complete local regression suite passed; orchestration checks were repeated after the final PATH refresh fix.
- Fresh PowerShell 7 and Windows PowerShell 5.1 profiles automatically loaded the workspace commands and Git prompt. Navigation and Claude/Codex/workspace launch previews passed for all eight projects. Full interactive agent operation was not checked in every project.

See [LAPTOP-VERIFICATION.md](LAPTOP-VERIFICATION.md) for evidence and its limits, [README.md](../README.md) for installation and daily commands, and [ADVANCED.md](ADVANCED.md) for customization and recovery.

## Implemented fixes

- Select a single executable consistently when PATH contains multiple WSL, PowerShell, WinGet, Git, or GitHub CLI matches.
- Refresh process PATH before every setup check and find standalone ripgrep behind bundled copies.
- Reuse matching existing clones in either supported directory layout; generated shortcuts use their verified paths.
- Retain package failures and installer diagnostics in structured reports, continue independent checks, block dependencies, and show usable recovery commands.
- Keep inline quickstart failures concise without closing the user's shell. Report restart requirements only when an installer returns one.
- Accept known Terminal serialization and generated registrations while protecting unrelated edits and retaining original backups.

Project command names are generated as `owner-repo`, with `cc`/`cx` suffixes. The published preview leaves aliases empty; current checkout setup adds collision-checked repository-name aliases and preserves established custom names. Runtime files and original backups remain under `%LOCALAPPDATA%\TerminalDevSetup`.

## Changes after v0.3.2-preview

The working checkout fixes targeted Update dependency checks, adds bounded WSL/Linux-user and Docker-engine probes to developer Doctor, and separates repository/workspace/display prerequisite gates. It also generates repository-name aliases. These changes are not included in the published preview command until a new implementation release is published. See [ADVANCED.md](ADVANCED.md) for the checkout behavior.

Local validation passed the existing 60 workspace and 38 provider/setup checks, 31 final orchestration checks, 17 runtime health checks, 8 alias checks, and repository/quickstart regressions. Local developer Apply and Doctor both returned ready with all 19 packages and all three feature gates ready. Doctor verified Ubuntu under WSL 2 with UID 1000 and Docker engine 29.8.2 connectivity. All eight installed repository-name aliases passed navigation and both agent launch previews in fresh PowerShell 7 and Windows PowerShell 5.1 sessions. These are existing-machine results; fresh-machine/reboot acceptance remains open.

Workspace startup was subsequently optimized and installed locally. Registration now snapshots imported shell commands once and scans each PATH directory once for executable/script conflicts, instead of looking up each generated name separately. With eight projects and their aliases, measured module import fell from 3929 ms to 648 ms; a fresh PowerShell process explicitly loading the user profile fell from 5292 ms to 1898 ms. These single-run timings exclude Terminal rendering and interactive PSReadLine startup; the no-profile process baseline measured 1094 ms. All 60 existing workspace checks and 8 new startup conflict/discovery checks passed, and the installed aliases were reverified in both PowerShell versions.

## Remaining acceptance work

The fresh-machine and restart/resume gate in [CLEAN-MACHINE-TEST.md](CLEAN-MACHINE-TEST.md) remains unrun. Existing-laptop success and fixture CI do not replace it. ARM64, other operating systems, and enterprise-managed installation remain unverified.

On a host supporting Windows Sandbox, `tests/sandbox/Start-Sandbox.ps1` exercises steps 1-5 of the core gate against the release pinned by quickstart. Enable the Sandbox feature on that host if needed, then run:

```powershell
powershell -NoProfile -File .\tests\sandbox\Start-Sandbox.ps1
```

Inspect `test-results/sandbox/out/DONE`, `summary.json`, `run.log`, `doctor.json`, and `plan-after.json`. Sandbox is discarded on restart; use a persistent disposable VM with snapshots for WSL/restart testing and the remaining developer-preset interactions.

## Release maintenance

New implementation releases must update both the README command and quickstart archive pin, pass CI, and verify the published command. Keep completed local, CI, publication, and acceptance gates distinct. Preserve existing release tags. `DEV-SETUP-INVESTIGATION.md` is a historical proposal, not current installation guidance.
