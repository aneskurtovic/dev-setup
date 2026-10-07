# dev-setup

Set up a Windows 11 development PC with one PowerShell command. It installs your tools, lets you choose which GitHub repositories to clone, and adds project-aware Codex, Claude, and terminal commands.

## Set up a new PC

Open **Windows PowerShell as Administrator** under your usual Windows account, then paste this command:

```powershell
irm https://raw.githubusercontent.com/aneskurtovic/dev-setup/v0.3.2-preview/quickstart.ps1 | iex
```

The command downloads the [tagged release](https://github.com/aneskurtovic/dev-setup/releases/tag/v0.3.2-preview) and starts the full developer setup. You do not need to install Git or PowerShell 7 first.

> **Preview release:** Windows 11 x64 is the current target. Automated tests pass, but a complete install on a fresh PC has not yet been verified. Expect to handle installer prompts and possibly restart once.

The published command completed successfully on an existing Windows 11 laptop, including WSL 2, a real Docker container, and PowerShell profiles and project shortcuts. See the [verified results and remaining limits](docs/LAPTOP-VERIFICATION.md).

Follow the prompts as setup runs:

1. Approve any Windows installer prompts. Setup installs missing apps and leaves compatible installed versions alone.
2. If asked to restart, restart Windows and **paste the same command again**. After Ubuntu is first installed, open it once and create your Linux username and password, even if no restart was needed. Setup continues with what is still missing.
3. Sign in to GitHub when prompted. Choose repositories by entering numbers such as `1,3-5`, or enter `all` or `none`. The list includes your personal repositories and accessible organizations.
4. Open a **new** PowerShell or Windows Terminal window when setup finishes. Sign in to Codex and Claude the first time you use them.

Your choices are saved on this PC, so a rerun does not ask you to select repositories again. New clones go under `~/source/repos/<owner>/<repo>`. Matching existing clones there or directly under `~/source/repos/<repo>` are marked as existing and reused, including their uncommitted changes. To change your selection later, see [Managing an existing setup](docs/ADVANCED.md#change-the-repository-selection).

## What gets installed

| Area | Apps and tools |
| --- | --- |
| Terminal and source control | PowerShell 7, Windows Terminal, Git, GitHub CLI |
| AI coding | Codex, Claude Code |
| Development | VS Code, Node.js LTS, Python 3.14, .NET SDK 10, uv, ripgrep |
| Containers | WSL with Ubuntu, Docker Desktop |
| Everyday apps | Chrome, Brave, 7-Zip, PowerToys, Everything |

Visual Studio, Go, SSMS, and pgAdmin are not included. The installer does not copy credentials, automatically upgrade every app, or reboot Windows for you.

## Use your workspace

After setup, open a new PowerShell window and try:

```powershell
ai-doctor                 # Check the workspace
ai-projects               # Show commands for cloned projects
ai-workspace              # Open Codex, Claude, and a shell for this folder
```

| Command | Opens |
| --- | --- |
| `ai-workspace` | New Codex and Claude sessions beside a shell |
| `ai-workspace-resume` | Each agent's saved-session picker |
| `ai-workspace-agents` | Each agent's agents view |
| `<project>` | Change this shell to a selected project |
| `<project>cc` / `<project>cx` | Full-window Claude / Codex for that project |
| `<project> ai-workspace` | Three-pane workspace for that project |

`ai-projects` shows the actual `<project>` command names. For a selected repository named `owner/repo`, the generated command is normally `owner-repo`. Project window titles start with the project name.

Both PowerShell 7 and Windows PowerShell 5.1 user profiles load the workspace commands and Git-aware prompt. Existing terminal sessions need a new window or a [profile reload](docs/ADVANCED.md#powershell-profiles-and-shortcuts).

## If setup stops

- **Restart requested:** Save your work, restart Windows, launch Ubuntu once if prompted, and run the same command again.
- **WinGet missing:** Install or update Microsoft's App Installer, then rerun. An explicit repair option is documented in [Advanced setup](docs/ADVANCED.md#repair-winget).
- **Older incompatible app or configuration conflict:** Follow the recovery command shown in the terminal and review the report under `%LOCALAPPDATA%\DevSetup\runs`. Setup preserves existing installations and edited configuration.
- **Command not found after installation:** Open a new PowerShell window to load the installed profile and commands. Setup refreshes its own PATH before checking packages, so rerunning setup from an older shell also sees newly installed tools.

Failures retain completed changes and produce a nonzero exit status. Independent package checks continue; dependencies and workspace configuration are blocked until their prerequisites pass. Quickstart prints concise recovery guidance and leaves your interactive shell open. Restart instructions appear only when an installer reports a restart requirement.

The [quickstart script](quickstart.ps1) is short and available to review before running the command. For planning without making changes, package updates, project customization, rollback, and tests, see [Advanced setup](docs/ADVANCED.md). Setup currently has [fresh-machine testing limits](docs/CLEAN-MACHINE-TEST.md).
