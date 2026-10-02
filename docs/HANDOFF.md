# Handoff — 2026-10-02

## Current state

- **Repository:** this public repo is the only one. The private archive was deleted; its history was not carried over. Public history starts at `84be880` (initial public release).
- **Latest release:** `v0.3.1-preview` (pre-release). The README's one-line command and `quickstart.ps1`'s `ArchiveUri` both point at it.
- **CI:** `Validate` passes on `main`. `actions/checkout` v7.0.1 and `actions/setup-node` v7.0.0 are pinned by commit SHA and run on Node 24.
- **Tests:** `pwsh -NoProfile -File .\tests\Invoke-Tests.ps1` passes from native PowerShell. From Git Bash, it fails on the Unicode fixture path because the temp path gets forward slashes. That's an environment problem, not a code problem.

## Changed in this session

- **Alias shortcuts** (`f6d74d7`): each project alias now gets its own `cc`/`cx` pair, not only the main command. These names are validated for collisions and replace legacy profile functions when `replaceNavigation` is true. Covered by three new assertions in `tests/Test-Workspace.ps1`.
- **CI actions** (`d449e70`): moved off the Node 20 actions.
- **Release** (`d669376`): `v0.3.1-preview`.
- **Sandbox runner**: `tests/sandbox/Start-Sandbox.ps1` and `tests/sandbox/run-in-sandbox.ps1` (see below).

## Next: clean-machine test in Windows Sandbox

The fresh-machine gate in [CLEAN-MACHINE-TEST.md](CLEAN-MACHINE-TEST.md) has still never been run, and the release notes say so.

1. Once, as administrator: `Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All`, then restart.
2. As your normal user: `powershell -NoProfile -File .\tests\sandbox\Start-Sandbox.ps1`
3. Wait for `test-results\sandbox\out\DONE`, then read `summary.json` (per-step status), `run.log` (full transcript), `doctor.json` and `plan-after.json`.

The runner covers steps 1–5 of the core preset unattended:
- Downloads the release ZIP, so Git isn't needed.
- Plan, with a check that it creates nothing.
- Apply with `-RepairWinGet`, because the sandbox has no winget.
- Doctor, then a second Plan that must be clean.
- `ai-doctor` and `ai-workspace -Preview`.

**Not covered by the sandbox:**
- The developer preset's GitHub sign-in and repository picker. These are interactive; run the README command by hand inside the same sandbox.
- Anything that needs a reboot (WSL, Docker). The sandbox is wiped on restart, so these still need a Hyper-V VM with checkpoints.

## Other open items

- **Release pins:** a new release must bump both the README command and `quickstart.ps1`'s `ArchiveUri`. The sandbox runner reads the latter automatically.
- **Known limitation:** Terminal re-serialises `settings.json`, which can make a reinstall report a conservative drift conflict. See README "Known limitations".
