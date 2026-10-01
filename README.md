# dev-setup

Install the missing essentials on a Windows development machine, then configure a reusable PowerShell and Windows Terminal workspace.

**Preview status:** Windows 11 x64 is the initial target. Configuration and package-provider fixtures pass locally; a fresh Windows VM provisioning run is still pending. This is not yet a verified unattended laptop rebuild.

The `core` preset includes PowerShell 7.2+, Windows Terminal, Git, GitHub CLI, and the workspace module. The `developer` preset adds Codex, Claude Code, VS Code, Node.js LTS, Python 3.14, .NET SDK 10, Docker Desktop, WSL with Ubuntu, Chrome, Brave, 7-Zip, PowerToys, Everything, uv, and ripgrep. It excludes Go, Visual Studio, SSMS, and pgAdmin. Existing compatible packages are preserved. Apply does not upgrade packages or reboot Windows.

**Start from a new PC**

Open Windows PowerShell on Windows 11 and paste this one command:

```powershell
irm https://raw.githubusercontent.com/aneskurtovic/dev-setup/v0.3.0-preview/quickstart.ps1 | iex
```

It downloads the tagged public release, starts the full `developer` preset, and installs missing tools. Git and PowerShell 7 are installed as part of setup. You may see installer/UAC prompts. When GitHub CLI is ready, setup asks you to sign in and choose repositories from your personal account and accessible organizations. Enter numbers/ranges, `none`, or `all`. The selection is saved locally in `%LOCALAPPDATA%\DevSetup\repositories.json`; reruns reuse it. Clones go to `%USERPROFILE%\source\repos\<owner>\<repo>`. Existing matching clones and uncommitted work are preserved. If WSL requests a restart, restart Windows and paste the **same command** again to finish.

The command executes [quickstart.ps1](quickstart.ps1) from a pinned release tag. Review that script and the release source before running it. Organizational execution policies may still apply.

Apply requires WinGet/App Installer. If unavailable, install/update Microsoft's App Installer, or explicitly select the documented Microsoft repair-module route:

```powershell
powershell.exe -NoProfile -File .\bootstrap.ps1 -Mode Apply -RepairWinGet
```

Repair downloads `Microsoft.WinGet.Client` from PowerShell Gallery into the current user's module directory. Apply accepts the selected packages' and source's installation agreements; installers may request UAC elevation. Run as your intended account, not a different administrator account.

After installation, open a fresh PowerShell session:

```powershell
pwsh -NoProfile -File .\Setup.ps1 -Mode Doctor
ai-workspace -Preview
ai-workspace
```

The workspace opens Claude, Codex, and shell panes. `ai-workspace` starts new sessions; `ai-workspace-resume` opens each agent's saved-session picker; `ai-workspace-agents` opens each CLI's agents browser. The `developer` preset installs the agent CLIs and display configuration, but first sign-in to each service remains interactive. Missing agent CLIs in `core` produce a diagnostic in their panes; the shell remains available.

**Inspect, apply, update**

```powershell
pwsh -NoProfile -File .\Setup.ps1 -Mode Plan -Json
pwsh -NoProfile -File .\Setup.ps1 -Mode Apply
pwsh -NoProfile -File .\Setup.ps1 -Mode Doctor -Json
pwsh -NoProfile -File .\Setup.ps1 -Mode Update -Component git
```

Plan is the default and makes no persistent changes. It reports missing tools and configuration differences. Doctor exits nonzero unless the selected preset is ready. Update requires explicit package names and never upgrades all installed applications. For multiple names, invoke `./Setup.ps1 -Mode Update -Preset developer -Component git,github` directly within PowerShell.

Apply/Update reports are stored under `%LOCALAPPDATA%\DevSetup\runs`. Reports may contain local paths; review before sharing. A restart-required result stops package processing and requests a manual restart/rerun. Setup failures do not imply that native installer changes have been rolled back.

**Projects and terminal customization**

Without a project registry, `ai-workspace` uses the current Git root or current directory. To register named shortcuts, create an ignored `projects.local.json` from `config/projects.example.json`:

```json
{
  "schemaVersion": 1,
  "projects": [
    {
      "command": "demo",
      "displayName": "Demo",
      "path": "C:\\dev\\demo",
      "enabled": true,
      "replaceNavigation": false,
      "aliases": []
    }
  ]
}
```

On first installation pass `Setup.ps1 -Mode Apply -ProjectsFile .\projects.local.json`. Open a new shell, then use `demo`, `demo terminal`, `demo codex`, `demo claude`, `demo ai-workspace`, `demo ai-workspace-resume`, or `demo ai-workspace-agents`. `democc` opens the same full-window Claude profile as `demo claude`; `democx` does the same for Codex. The developer preset creates these project commands automatically for selected clones, using a sanitized `<owner>-<repo>` as the command name. Registry changes after installation must be applied through `-ProjectsFile`; direct edits to managed runtime files are reported as conflicts.

Runtime files remain in `%LOCALAPPDATA%\TerminalDevSetup` to preserve compatibility. The three stable profile GUIDs and Terminal fragment source are unchanged. The installer sets the PowerShell workspace profile as Terminal's default, adds a managed block to user PowerShell profiles, and installs the compact shell prompt.

Optional display configuration is separate from core:

```powershell
pwsh -NoProfile -File .\Install.ps1 -ConfigureDisplay -Preview
pwsh -NoProfile -File .\Install.ps1 -ConfigureDisplay
```

This requires Node on PATH and is enabled automatically by the developer preset. It sets Ctrl+W to close the pane, creates or updates the conventional Codex `[tui]` status-line setting, and installs/wires the Claude renderer. Codex's built-in footer shows rate-limit percentages but currently does not expose a reset countdown field; use the [usage dashboard](https://learn.chatgpt.com/docs/pricing) for reset times and `/status` for remaining limits. Claude's renderer shows countdowns when its input includes reset timestamps. Existing unconventional TOML syntax may require manual reconciliation. The optional Claude mode chip appears only when an independently configured capture hook supplies it; this repository does not install that hook. Other user preferences and credentials are not copied between machines. See [Codex status-line configuration](https://learn.chatgpt.com/docs/config-file/config-reference) and [Claude status lines](https://code.claude.com/docs/en/statusline).

**Preservation and rollback**

JSONC edits preserve comments and unrelated properties. Files are staged before replacement. Install and rollback share a lock. The installer records original backups and installed hashes, and refuses to overwrite drift in a target it would manage.

```powershell
pwsh -NoProfile -File "$env:LOCALAPPDATA\TerminalDevSetup\Uninstall.ps1" -Preview
pwsh -NoProfile -File "$env:LOCALAPPDATA\TerminalDevSetup\Uninstall.ps1"
```

Rollback restores the original configuration baseline, not a package snapshot. It refuses subsequent edits or incomplete installation records and leaves backups available for manual recovery. Reinstall cannot silently bless user edits against an older backup. Packages installed by core are not removed.

Known limitations: Terminal's own settings serialization can cause conservative reinstall conflicts; there is no automatic merge/recovery for drift or interrupted installs. Stable packaged Windows Terminal is the default target; the low-level installer accepts `-TerminalSettingsPath` for another channel/location. ARM64 and non-Windows platforms are unverified. A fresh machine may need a new shell after package installation for PATH/application registration to settle.

**Validation and roadmap**

```powershell
pwsh -NoProfile -File .\tests\Invoke-Tests.ps1
```

Tests require Windows, PowerShell 7.2+, Git, Node, and Windows PowerShell 5.1. They use temporary configuration directories and mocked package installation. CI uses a resolution-only Terminal fixture when Terminal is absent; it does not install packages or prove clean-machine provisioning.

See the [fresh Windows VM procedure](docs/CLEAN-MACHINE-TEST.md) and [investigation](DEV-SETUP-INVESTIGATION.md). The latter records the original findings and broader design, including work beyond the implemented core preset. Keep tokens, private keys, machine inventories, and private project lists out of commits.
