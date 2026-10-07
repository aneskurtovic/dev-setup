# Existing-laptop verification - 2026-10-07

The developer preset was applied to an existing Windows 11 25H2 x64 laptop using Windows PowerShell 5.1 and PowerShell 7.6.6. This is an existing-machine acceptance check; the fresh-machine and reboot gates in [CLEAN-MACHINE-TEST.md](CLEAN-MACHINE-TEST.md) still apply.

The original v0.3.1-preview run failed when multiple WSL executables on PATH were joined into one filename. It also found 7-Zip 23.01 below the declared minimum. Verification exposed two further issues: a bundled ripgrep executable hid the standalone installation, and Windows Terminal serialization caused a reinstall conflict immediately after setup.

The repaired Apply completed with `ready: true`, all 19 packages `Ready`, repositories `Ready`, workspace `Ready`, and no pending workspace changes or recovery steps. Eight selected existing clones were reused at their original paths; no repositories were cloned or moved.

The published `v0.3.2-preview` command was then run through Windows PowerShell 5.1: `irm https://raw.githubusercontent.com/aneskurtovic/dev-setup/v0.3.2-preview/quickstart.ps1 | iex`. It downloaded the tagged archive and completed Apply with exit code 0 and the same ready state. The release points to commit `069eebd9cbd39541e0b0ac6e413a061aecdf862c`; [main CI](https://github.com/aneskurtovic/dev-setup/actions/runs/37687732340) and [release-tag CI](https://github.com/aneskurtovic/dev-setup/actions/runs/37687883165) both passed.

Native installation checks:

- 7-Zip upgraded to 26.04 through the explicit Update operation.
- Ubuntu installed on the existing WSL 2.7.10 platform without a restart. `wsl --list --verbose` reported Ubuntu running under WSL 2, and a Linux command exited successfully.
- Docker Desktop installed and started; the engine reported 29.8.2. `docker run --rm hello-world` pulled and ran a real Linux container successfully.
- Fresh-shell `ai-doctor` checks passed, and `ai-workspace -Preview` produced the expected three-pane launch using one PowerShell executable path.

Separate fresh PowerShell 7.6.6 and Windows PowerShell 5.1 sessions automatically loaded their configured profiles and custom prompt. All eight project navigation functions were executed successfully; all sixteen Claude/Codex shortcut previews and eight project workspace previews passed in each shell. Generic new-session, resume, and agents workspace previews also passed. Terminal's three workspace profiles, default PowerShell profile, and Ctrl+W close-pane binding were confirmed. These checks verified launch previews, not interactive sign-in and agent operation in every project.

The complete isolated regression suite passed: 60 workspace checks, 38 setup/provider checks, 18 orchestration checks, repository preservation checks, quickstart success/failure checks, and JavaScript syntax validation. Failure checks cover native installer errors, retained run reports, independent package checks, blocked dependencies, explicit incompatible-version recovery, restart-required exits, failed downloads, and keeping an interactive Windows PowerShell session open after inline quickstart failure.

Terminal comparisons accept formatting, reordering of actions with unique IDs and shortcuts with unique chords, and exact generated workspace/Ubuntu registrations. Tests continue to reject unrelated preferences, duplicate shortcuts, and custom commands in generated profiles. Original configuration backups remain intact.

Ubuntu's personal Linux username/password was completed by the user in its first-run window. A subsequent Linux command confirmed the default account uses UID 1000. Setup does not create or store that password. Other installer prompts, architectures, and clean-machine restart/resume behavior remain outside this acceptance check.
