**dev-setup investigation — 2026-10-01**

> Historical investigation: the findings and proposed commands below describe the repository before implementation. For current installation instructions, use [README.md](README.md); for the current handoff and verified results, see [docs/HANDOFF.md](docs/HANDOFF.md) and [docs/LAPTOP-VERIFICATION.md](docs/LAPTOP-VERIFICATION.md).

Recommendation: evolve this folder into a Windows-first `dev-setup` repository with a small bootstrap, a curated package manifest, and independent configuration modules. Keep the existing terminal workspace as its first module. Make the default operation install missing requirements and reconcile explicitly managed settings; make upgrades a separate operation.

This is an investigation and implementation proposal. The proposed commands and directory layout below do not exist yet. The current installer was not applied to the real user configuration during this investigation. Windows-first is an assumption based on the existing implementation; additional operating systems need separate acceptance criteria.

**What was inspected and tested**

Inspected every implementation file, the examples, existing tests, README, and original plan. There is no `.git` directory here: `git status` reports that the folder is not a Git repository. There is no CI workflow or license file. The README contains a history of this particular machine rather than a fresh-machine quick start.

The existing `tests/Test-Workspace.ps1` passed all 41 checks on this machine, including PowerShell 5.1 launcher compatibility, path quoting, repeat installation, settings preservation, and rollback. The host used PowerShell 7.6.6 and WinGet 1.29.380. These observations are not minimum supported versions.

`node --check claude/statusline.js` passed. Empty-object and malformed-JSON input both produced output without a crash. These are smoke checks, not exhaustive renderer validation.

Four additional probes used temporary directories with explicitly redirected installation, profile, fragment, and settings paths. Reproductions are retained in `test-results/Investigate-Portability.ps1`; observations are in `test-results/portability-findings.json`. This directory is already ignored. The probe script documents current defects rather than asserting release readiness.

| Finding | Evidence | Consequence / recommended change |
| --- | --- | --- |
| Bootstrap requires tools it should provision | `Install.ps1:1` requires PowerShell 7.2; lines 20–22 resolve `pwsh.exe`, `wt.exe`, and read existing settings | Add a Windows PowerShell 5.1-compatible bootstrap, with a handoff to PowerShell 7 |
| Terminal must already have a settings file | Missing-settings probe failed even with `-Preview` | Discover the Terminal channel and support an absent settings file |
| Display setup assumes existing customizations | Probe with no Ctrl+W binding failed; code also requires an existing Codex config and `[tui]` table | Create absent settings safely; manage each app independently |
| Reinstall changes rollback safety | A user edit survives reinstall, but subsequent uninstall silently removes it | Separate per-run rollback from original-baseline restoration; preserve unrelated edits |
| Regex edits are not scoped to JSON properties | A nested `custom.defaultProfile` changed from `keep` to the managed GUID | Use property-aware JSONC editing; add nested-key and comment fixtures |
| Claude customization is incomplete on a new machine | Installer copies the renderer but does not configure Claude's `statusLine.command`; referenced `capture-mode.js` is absent | Install and wire the integration explicitly, or omit the optional mode chip |
| Renderer has an additional runtime dependency | `claude/statusline.js` uses Node.js; `ai-doctor` does not check Node | Declare dependencies per feature, including the renderer |
| Diagnostics primarily detect presence | `Test-AiWorkspace` checks executables, paths, and fragment existence | Add supported versions, command execution, config validity, and actionable failure reasons |
| Installation can stop midway | Targets and the manifest are written sequentially; no run journal or lock | Add staged writes, per-run journal, single-run locking, and failure recovery |
| Portability is partly implemented | Empty default registry and relative runtime assets are good; installed project registry requires absolute paths | Generate local absolute paths from portable project definitions and a chosen repository root |

The rollback finding is more specific than “rollback is broken.” Direct edits after installation are detected correctly. The unsafe sequence is **install → user edit → reinstall → uninstall**: reinstall records the edited file's new installed hash while retaining the first installation's original backup. Uninstall therefore accepts the current file and restores the older baseline. The existing test itself exercises a similar sequence but expects restoration of the original bytes.

The sequential-write issue is a code-review finding; interruption, power loss, and corrupt-manifest recovery were not experimentally tested. The regex probe uses an arbitrary nested property to demonstrate replacement scope; it does not claim that Terminal normally creates that property.

**What to reuse**

The current implementation already has valuable behavior: stable Terminal profile GUIDs, fragments instead of wholesale profile replacement, a managed PowerShell block, registry validation, explicit handling of command collisions, data-only project preferences, encoded launch payloads, and isolated filesystem tests. Preserve these behaviors while separating installation concerns.

Terminal fragments are an official extension mechanism for adding profiles and color schemes. Continue using them for the three workspace profiles; treat global defaults and keybindings as separately owned settings. [Microsoft Terminal fragment documentation](https://learn.microsoft.com/en-us/windows/terminal/json-fragment-extensions).

**Tooling choices**

| Approach | Role in this project | Assessment |
| --- | --- | --- |
| Small PowerShell orchestrator + WinGet | Bootstrap, package installation, sequencing, status | Recommended initial implementation; easiest fit with existing code and explicit install-missing semantics |
| WinGet Configuration / DSC | Declarative packages and selected Windows settings | Strong candidate for a later provider or an initial isolated pilot; adds resource/schema dependencies that need validation |
| chezmoi | Portable user dotfiles and machine-specific templates | Adopt when shared home-directory configuration grows; avoid two tools managing the same file |
| WinGet export/import alone | Discovering and replaying a package inventory | Useful input, insufficient for configuration, project paths, logins, or recovery |
| Scoop | Optional packages with a reason to use its distribution model | Avoid a second default package manager; assign one owner per package |
| Homebrew Bundle | Future macOS adapter | Appropriate later; keep Windows bootstrap independent |
| Dev containers | Reproducible project-specific toolchains | Complement the workstation setup; keep project dependencies with projects |
| Full system-management framework | Large centrally managed fleets | More operational surface than this personal Windows setup currently warrants |

WinGet install supports exact package IDs, explicit sources, architecture/scope selection, and `--no-upgrade`. An illustrative package operation is `winget install --id Git.Git --exact --source winget --no-upgrade`. The provider must still inspect exit codes and verify the resulting installation. A package present at an unsupported version should be reported as incompatible, not silently counted as ready. [WinGet install reference](https://learn.microsoft.com/en-us/windows/package-manager/winget/install).

WinGet export attempts to match installed applications to configured sources; unmatched applications may be omitted with warnings. Use an export as a private discovery artifact, then curate a small manifest of tools you actually want on every new machine. [WinGet export reference](https://learn.microsoft.com/en-us/windows/package-manager/winget/export).

WinGet Configuration has `show`, `validate`, and `test` operations as well as apply. These are useful building blocks, but executing resource tests is not equivalent to a guaranteed side-effect-free text preview: configurations and resource implementations must be trusted. [Configure reference](https://learn.microsoft.com/en-us/windows/package-manager/winget/configure), [configuration trust guidance](https://learn.microsoft.com/en-us/windows/package-manager/configuration/check).

Current Microsoft documentation describes v3 configurations using DSC v3, requiring WinGet 1.11 or later. Its package resource is `Microsoft.WinGet/Package`; older configurations use `Microsoft.WinGet.DSC/WinGetPackage`. Adapted v2 resources require explicit module installation. `RunCommandOnSet` has no test capability and always reports that work is needed. Therefore, do not mix snippets from different schema generations or wrap every operation in an unconditional command resource. Pin and test the selected processor/resource versions. [WinGet v3 schema reference](https://learn.microsoft.com/en-us/windows/package-manager/configuration/create-v3).

Microsoft's `WindowsDeveloperConfig` is now a relevant reference implementation. It combines developer tools, Terminal preferences, Windows settings, and WSL/reboot handling. Its default scope includes opinionated OS changes and can reboot. Reuse selected patterns after inspection; do not make applying its entire configuration an implicit dependency of your setup. [Microsoft WindowsDeveloperConfig](https://github.com/microsoft/WindowsDeveloperConfig).

Chezmoi supports machine-specific templates and password-manager integrations, but explicitly focuses on home-directory management. Its scripts must be idempotent even when named `run_once_` or `run_onchange_`; execution history is not a substitute for checking actual machine state. For a first version, retain the small existing configuration layer. Adopt chezmoi when you have enough shared dotfiles or multiple operating systems to justify it. [Machine differences](https://www.chezmoi.io/user-guide/manage-machine-to-machine-differences/), [design boundaries](https://www.chezmoi.io/user-guide/frequently-asked-questions/design/), [script behavior](https://www.chezmoi.io/user-guide/use-scripts-to-perform-actions/), [secret integrations](https://www.chezmoi.io/user-guide/password-managers/).

Homebrew Bundle can express a macOS package set in a Brewfile, but normal bundle installation can also upgrade outdated packages. A future adapter must deliberately match this project's install/update policy. Development containers describe project environments independently of the host. [Homebrew Bundle](https://docs.brew.sh/Brew-Bundle-and-Brewfile), [Development Containers specification site](https://containers.dev/).

**Recommended operating contract**

The following is a proposed interface, not commands available today:

```powershell
# After obtaining a reviewed release:
powershell.exe -NoProfile -File .\bootstrap.ps1 -Preset developer

# Main entry point after PowerShell 7 is present:
pwsh -NoProfile -File .\Setup.ps1 -Mode Plan -Preset developer
pwsh -NoProfile -File .\Setup.ps1 -Mode Apply -Preset developer
pwsh -NoProfile -File .\Setup.ps1 -Mode Doctor
pwsh -NoProfile -File .\Setup.ps1 -Mode Update -Component git,terminal
```

Plan should report desired changes, missing dependencies, elevation, downloads, and manual steps. It must not install prerequisites to make its own preview work. The bootstrap needs its own basic plan capability because the main runner may not exist yet.

Apply should converge on declared requirements. Existing compatible tools remain; missing tools are installed; outdated incompatible tools are reported with a targeted update path; unrelated applications are untouched. Update should operate only on selected managed components. Avoid a global `winget upgrade --all` in normal setup.

Doctor should distinguish **ready**, **missing**, **incompatible**, **needs login**, **needs restart**, **conflict**, and **unsupported platform**. A successful executable lookup is not proof that the underlying application works. Reports should have both human-readable output and a machine-readable result with a meaningful process exit code.

**Getting from a clean Windows account to the runner**

1. Start in Windows PowerShell 5.1 with built-in download/extraction facilities. Git, Node, PowerShell 7, and the GitHub CLI cannot be prerequisites for obtaining the initial public bundle.
2. Check the OS, processor architecture, current user, required network endpoints, available disk space, and policy restrictions. Report unsupported conditions before changing the machine.
3. Detect WinGet and its capabilities. On fresh accounts App Installer registration may not be complete; Microsoft documents a registration path and a repair module. Prefer normal App Installer provisioning, then a documented repair path where appropriate. Do not repeatedly install competing copies. [WinGet availability and bootstrap guidance](https://learn.microsoft.com/en-us/windows/package-manager/winget/).
4. Install PowerShell 7 when missing. Resolve its installed path explicitly and pass structured arguments to a new process; the parent shell's PATH may not contain it yet.
5. Execute the selected manifest and modules in dependency order. Configuration requiring a particular application waits until that application is verified.
6. Present a final readiness report and any login/restart steps. A partially successful run must not claim the workstation is ready.

Prefer a public bootstrap repository if effortless retrieval is the priority, with private machine choices supplied locally after authentication. A private repository is viable, but obtaining it requires an initial login or authenticated download; do not hide that prerequisite.

Release bundles should refer to a specific reviewed commit/version, include checksums, and record the exact release in local state. A checksum fetched beside an archive detects corruption but is not independent proof of publisher identity. Stronger provenance can come from verified signatures or attestations. Avoid executing a moving branch directly with `irm ... | iex` as the main documented installation path.

Start normally as the intended user and elevate only the steps that require machine access. Installing user configuration from a different administrator account can target the wrong profile. Account for that identity explicitly. Do not weaken execution policy or security settings permanently to get setup working. If organizational policy blocks installation, report the restriction and supported remediation.

**Profiles and package ownership**

Use small composable presets:

| Preset / feature | Candidate scope |
| --- | --- |
| `core` | PowerShell 7, Windows Terminal, Git, GitHub CLI, workspace module |
| `developer` | Core plus selected editor, search/navigation utilities, chosen language tooling |
| `ai` | Selected agent CLIs and optional display integrations, with explicit runtime dependencies |
| `dotnet`, `node`, `python` | Language-specific tools only when selected |
| `containers` | Container tooling plus its separately tested platform prerequisites |
| `wsl` | WSL platform, distribution, Linux setup, and explicit restart handling |
| `personal` / `work` | Local choices for identity, project lists, and optional apps |

These are candidates, not a claim that you need every tool. Inventory the present machine separately and curate the list. Keep raw inventories private because they may disclose employer software or internal tooling.

Each package definition should record its identifier, provider/source, supported architectures, desired scope, version policy, dependencies, and health check. Keep data declarative: avoid arbitrary shell command strings inside project or machine preference files. A small fixed set of reviewed adapters is easier to inspect.

Use one installer/version manager as the owner of each tool. Do not install Node via several managers or the same agent CLI via multiple channels. Project runtime versions and lockfiles belong in each project; a workstation preset should install the required runtime manager or selected SDK family. Exact old installer versions are not guaranteed to remain downloadable, so distinguish a reproducible setup definition from byte-identical reconstruction of all third-party software.

**Configuration ownership and safe reruns**

Use three layers: repository defaults, a selected preset, and ignored local overrides. Resolve known paths from environment/special-folder APIs, including redirected Documents folders. Do not make a username, drive letter, or the current checkout path part of the public configuration.

Every configuration target needs an ownership policy: whole generated file, managed block, or a short list of managed properties. Whole-file replacement is appropriate for a dedicated generated fragment. Shared Terminal, editor, Git, or agent settings require narrow edits. JSONC comments and TOML structure deserve format-aware handling; regular-expression replacement of similarly named keys is insufficient.

Keep user customization in a distinct local include where practical. Preserve unrelated edits when applying. If a managed value has changed, show the difference and provide a deliberate conflict policy. Changing the declared desired value is ordinary reconciliation; overwriting a user's conflicting local choice should be visible.

Track each run with an ID, desired-definition hash, tool versions, attempted actions, before/after hashes, backups, exit codes, and completion states. Write each target through a staged file on the same volume and use a safe replacement operation. Journal pending operations before mutation, then record completion. A crash can occur between these operations, so recovery must compare actual state and handle both possibilities.

Reruns must inspect actual installed state even when a previous journal says a task succeeded: applications may have been removed or changed afterward. Prevent concurrent setup runs with a process lock. Validate that restore targets and backups belong to the expected managed roots before using the manifest.

Define rollback narrowly: undo this run's managed configuration changes only when safe. Keep an explicit, separately named original-baseline restore if wanted. Package installations, application migrations, service changes, and third-party upgrades cannot be promised as a global transaction. Do not uninstall pre-existing packages; removal of packages introduced by setup needs separate dependency and user-data handling.

**Projects, authentication, and personal configuration**

Represent a project with a repository URL, command name, display name, preset selection, and path relative to a configurable repositories directory. Generate the existing absolute-path registry locally. Reject traversal outside the selected repository root. If a destination already exists, verify its Git remote; preserve dirty worktrees and report mismatches instead of resetting or replacing them.

Clone only selected repositories. Separate public and private lists so private organization/project names need not appear in a public repository. Authentication is a prerequisite for private clones, not something to discover after dozens of failing commands.

Public content should contain templates and identifiers, never tokens, private SSH keys, environment secrets, application session databases, or copies of entire agent configuration directories. Generate a new device key or use the chosen password manager's supported workflow. Prefer interactive/device authentication over embedding credentials in command lines or URLs. Logs and diagnostics must not dump environment variables or complete config contents.

Git identity should be configurable for personal and work contexts; credentials and author identity are different concerns. Agent setup should manage an allowlist of portable preferences, with account login and machine permissions handled independently. Do not copy another machine's trusted-directory or credential state wholesale.

For VS Code, select a clear owner: either Settings Sync for personal settings/extensions, or repository-managed defaults for the categories you want reproducible. Avoid both continuously overwriting the same values. Sync requires sign-in and does not synchronize extensions to/from remote windows such as WSL. [VS Code Settings Sync](https://code.visualstudio.com/docs/configure/settings-sync).

**WSL, hardware, and “any PC”**

For the first release, claim support for a defined Windows 11 version/edition range and test x64; advertise ARM64 only after testing it. Package availability, installation scope, hardware virtualization, Store access, proxy rules, and device management can differ. “Any new PC” should mean a documented supported machine, not an unconditional promise.

Keep WSL optional unless it is part of the chosen default workflow. Its initial installation may require administrator access and a restart. Use a persistent VM for reboot/resume testing. Resume from a recorded release and manifest, not newly downloaded moving code. A manual rerun after restart is a reasonable first implementation; automatic scheduled continuation can come later. [Microsoft WSL installation](https://learn.microsoft.com/en-us/windows/wsl/install).

Do not enable broad OS tuning, remote access, telemetry changes, or cleanup scripts merely because another setup repository includes them. Each should be an explicit feature with a stated purpose. Likewise, Docker, large IDEs, and optional SDKs should be selected workloads rather than unconditional dependencies.

**Proposed repository shape**

```text
dev-setup/
  bootstrap.ps1                 # PS 5.1 entry point and prerequisite handoff
  Setup.ps1                     # plan/apply/doctor/update orchestration
  manifests/packages.json       # curated package definitions
  presets/                      # core/developer/optional feature selection
  config/                       # templates and local-override examples
  modules/
    TerminalWorkspace/          # current implementation, incrementally extracted
    Git/
    Editor/
    Projects/
    Agents/
  lib/                          # small shared process/state/file helpers
  tests/                        # unit, fixture integration, clean-machine scenarios
  docs/                         # support policy, recovery, decisions
  .github/workflows/            # validation and release checks
```

Avoid implementing a general plugin framework before a few modules establish real common needs. One small component contract—inspect, plan, apply, verify—is sufficient to start.

Rename the public project to `dev-setup`, but preserve `TerminalDevSetup` runtime paths, fragment source, managed block markers, and profile GUIDs during the first migration. Renaming those identifiers blindly can create duplicate profiles or disconnect existing backups. Migrate runtime state later with an explicit, tested migration.

**Testing and release gates**

| Layer | Required checks |
| --- | --- |
| Static CI | PowerShell parse/lint, JSON/schema validation, JS syntax, secret scanning, supported-shell bootstrap parsing |
| Unit / provider fixtures | Package absent/present/incompatible, external-command failures, reboot-required results, stale PATH, dependency failure, source/architecture mismatch |
| Isolated configuration tests | Existing 41 checks plus absent configs, comments, nested properties, multiline TOML, display integration, Unicode and redirected profile paths |
| Safety / recovery | User edit → reapply → rollback, interrupted writes, corrupt state, concurrent runs, drift after success, read-only targets |
| Clean-machine integration | Fresh standard user; no Git/PowerShell 7; missing or unregistered WinGet; Terminal never opened; selected preset installs and verifies |
| Rerun integration | Second apply changes no managed target and performs no unnecessary installs/upgrades; deliberate drift is detected and reconciled appropriately |
| Persistent VM | UAC boundaries, restart/resume, WSL, native installer behavior, real GUI/Terminal checks |
| Compatibility | Supported Windows versions, x64, ARM64 when claimed, package-manager/client versions, offline/proxy failure behavior |

GitHub-hosted Windows runners are useful for code and fixture checks but are not evidence that an empty laptop works: they come provisioned. Use disposable Windows VMs for the release gate. Windows Sandbox is useful for quick smoke tests and can map the checkout read-only with a startup command; do not expose the whole user profile or secrets. WinGet itself may need bootstrapping in Sandbox. [Sandbox configuration](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file), [WinGet in Sandbox](https://learn.microsoft.com/en-us/windows/package-manager/winget/).

Release success should mean: a fresh supported Windows account reaches the selected preset, the second run is stable, existing unrelated configuration survives, errors remain actionable, and rollback preserves user work. Authentication and restarts may remain explicit user steps. Record versions and timings from these runs before making a “ready in N minutes” claim.

Pin CI actions to full commit SHAs and use minimal token permissions. Do not run untrusted pull-request code with release credentials. Release only the allowlisted source/assets, excluding local state and inventories. [GitHub Actions secure-use reference](https://docs.github.com/en/actions/reference/security/secure-use).

**Implementation order**

1. Fix the reproduced rollback and property-editing defects; turn the four probes into regression tests with the desired outcomes. Support first-run configs and explicitly wire optional display integrations.
2. Add the minimal PS 5.1 bootstrap, curated core manifest, install-missing policy, plan mode, and doctor. Keep the current workspace behavior intact.
3. Add selected developer tools, portable project definitions, and local overrides. Establish one owner for each package/configuration category.
4. Run the clean-machine and rerun gates in a disposable VM. Pilot WinGet Configuration against the same acceptance criteria before choosing it as the package/settings backend.
5. Prepare the GitHub repository: portable README, migration notes, license decision, `.gitignore` for secrets/state/logs, secret scan, CI, reviewed first release. Move this machine's historical setup details out of the public quick start.
6. Add WSL, larger workloads, chezmoi, and other operating systems only when needed and independently tested.

The most useful next experiment is a clean Windows VM that installs **only the core preset**, verifies it, and reruns it. That directly tests the goal of being productive on a new machine and will expose more useful gaps than adding more terminal customization first.

No GitHub repository was created or renamed, no applications were installed, and no production configuration was changed during this investigation. The research report and ignored diagnostic artifacts are the only additions. End-to-end provisioning, DSC application, downloads, ARM64, restarts, and authentication flows remain untested.
