# Advanced setup and maintenance

The [README](../README.md) has the one-command path for a new Windows 11 PC. This page covers local customization and maintenance.

Commands below that use `./Setup.ps1`, `./Install.ps1`, or `./tests` must run **from a checkout of this repository**. The one-command installer downloads a temporary release archive; it does not place those scripts in your current directory. On a machine with Git installed, get a checkout with:

```powershell
git clone https://github.com/aneskurtovic/dev-setup.git
cd dev-setup
```

## Inspect or rerun setup

The default `Setup.ps1` mode is `Plan`, which makes no persistent changes. Use `-Preset developer` for the full app list; `core` only includes PowerShell 7, Windows Terminal, Git, GitHub CLI, and the workspace.

```powershell
pwsh -NoProfile -File ./Setup.ps1 -Mode Plan -Preset developer -Json
pwsh -NoProfile -File ./Setup.ps1 -Mode Apply -Preset developer
pwsh -NoProfile -File ./Setup.ps1 -Mode Doctor -Preset developer -Json
```

`Doctor` exits nonzero until the preset is ready. Apply installs missing packages, but it does not upgrade installed packages automatically. To install or update specific components, name them explicitly:

```powershell
./Setup.ps1 -Mode Update -Preset developer -Component git,github
```

Apply and Update write reports to `%LOCALAPPDATA%\DevSetup\runs`. Those reports may contain local paths; review them before sharing. A restart-required result stops package processing so you can restart and rerun. Setup does not roll back changes made by native installers.

## Change the repository selection

The first developer Apply asks you to sign in to GitHub and select repositories from your personal account and accessible organizations. Enter several numbers or ranges (for example, `1,3-5`), `all`, or `none`. The selection is saved in `%LOCALAPPDATA%\DevSetup\repositories.json` and reused on later runs.

From a checkout, ask again with:

```powershell
pwsh -NoProfile -File ./Setup.ps1 -Mode Apply -Preset developer -ChooseRepositories
```

For an automated selection, use `-RepositoriesFile` with a JSON file containing `{"schemaVersion":1,"repositories":["owner/repo"]}`. The file is checked against repositories visible to the signed-in account. Clones use `%USERPROFILE%\source\repos\<owner>\<repo>` by default; `-ProjectRoot` changes that root. Existing matching clones, including dirty ones, are preserved. A destination with a different `origin` is reported as a conflict, not overwritten.

## Customize project commands

Developer setup registers selected clones automatically. It derives a command like `owner-repo` for each one; run `ai-projects` to see the exact names. Without a project registry, `ai-workspace` uses the current Git root or directory.

To add your own project, copy `config/projects.example.json` to an ignored `projects.local.json` and edit it. For example:

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

Apply it from the checkout and open a new shell:

```powershell
pwsh -NoProfile -File ./Setup.ps1 -Mode Apply -Preset developer -ProjectsFile ./projects.local.json
```

`demo` changes the current shell to that project. `demo terminal`, `demo codex`, and `demo claude` open single windows; `democc` and `democx` are full-window Claude and Codex shortcuts, and each alias gets the same `cc`/`cx` pair. `demo ai-workspace`, `demo ai-workspace-resume`, and `demo ai-workspace-agents` open project workspaces. Add `-Preview` to a workspace command to inspect its launch without opening a window. Registry changes after installation must go through `-ProjectsFile`; editing managed runtime files directly can produce a conflict.

Runtime files remain under `%LOCALAPPDATA%\TerminalDevSetup`. The installer adds a managed block to user PowerShell profiles, sets the workspace profile as Windows Terminal's default, and installs the compact shell prompt.

## Display configuration

The developer preset enables display configuration automatically. To preview or apply it separately:

```powershell
pwsh -NoProfile -File ./Install.ps1 -ConfigureDisplay -Preview
pwsh -NoProfile -File ./Install.ps1 -ConfigureDisplay
```

This requires Node on PATH. It sets Ctrl+W to close the pane, updates the conventional Codex `[tui]` status-line setting, and installs the Claude status renderer. Codex's built-in footer displays rate-limit percentages but does not currently expose reset countdowns; use the [usage dashboard](https://learn.chatgpt.com/docs/pricing) for reset times and `/status` for remaining limits. Claude's renderer displays countdowns when its input includes reset timestamps. Existing unconventional TOML syntax can require manual reconciliation. The optional Claude mode chip appears only if a separately configured capture hook supplies it; this repository does not install that hook. See [Codex status-line configuration](https://learn.chatgpt.com/docs/config-file/config-reference) and [Claude status lines](https://code.claude.com/docs/en/statusline).

## Repair WinGet

Apply requires WinGet/App Installer. If it is unavailable, install or update Microsoft's App Installer. Alternatively, opt into the Microsoft repair-module route from this checkout:

```powershell
powershell.exe -NoProfile -File ./bootstrap.ps1 -Mode Apply -Preset developer -RepairWinGet
```

Repair downloads `Microsoft.WinGet.Client` from PowerShell Gallery to the current user's module directory. Apply accepts the selected package and source agreements; native installers may request elevation. Run under your intended Windows account.

## Roll back workspace configuration

The low-level installer stages files before replacing them, preserves unrelated JSONC settings and comments, and records original backups and installed hashes. It refuses to overwrite managed targets that changed since installation. Preview rollback before applying it:

```powershell
pwsh -NoProfile -File "$env:LOCALAPPDATA\TerminalDevSetup\Uninstall.ps1" -Preview
pwsh -NoProfile -File "$env:LOCALAPPDATA\TerminalDevSetup\Uninstall.ps1"
```

Rollback restores the original workspace configuration baseline; it does not uninstall packages or restore a package snapshot. It refuses subsequent edits or incomplete installation records and leaves backups for manual recovery. Windows Terminal may reserialize its settings, which can cause a conservative reinstall conflict. ARM64 and non-Windows platforms are unverified.

## Validate a checkout

```powershell
pwsh -NoProfile -File ./tests/Invoke-Tests.ps1
```

Tests require Windows, PowerShell 7.2+, Git, Node, and Windows PowerShell 5.1. They use temporary configuration directories and mocked package installation. CI can use a Terminal executable-resolution fixture when Terminal is absent; it does not install packages or prove clean-machine provisioning. See the [fresh Windows VM procedure](CLEAN-MACHINE-TEST.md) and [investigation notes](../DEV-SETUP-INVESTIGATION.md).
