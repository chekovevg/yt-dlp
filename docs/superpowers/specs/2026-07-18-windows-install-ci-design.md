# Windows Installation and CI Design

## Goal

Make the repository usable as a small Windows application rather than only as a collection of scripts: a user can download the repository, run one installer without administrator rights, launch the app from normal Windows shortcuts, and remove it cleanly. GitHub Actions must verify that application behavior and the installation path remain working before changes are merged.

## Chosen Approach

Use a per-user PowerShell installer and a single Windows CI job.

This is preferred over a portable-only folder because shortcuts should not break when the downloaded repository is moved or deleted. It is preferred over MSI/MSIX because those formats add packaging, signing, upgrade, and administrator-policy complexity that is disproportionate for this small PowerShell/WinForms utility.

## Installation Model

`install.cmd` is the user entry point. It launches `install.ps1` with Windows PowerShell 5.1 and an execution-policy bypass scoped to that process. `app-files.txt` is the single runtime-file allowlist shared by installation and packaging.

The installer:

- installs for the current user without elevation;
- copies an explicit allowlist of runtime files to `%LOCALAPPDATA%\Programs\YouTubeTranscriptTool`;
- creates `YouTube Transcript Tool` shortcuts on the desktop and in the current user's Start Menu;
- creates an uninstall shortcut in the Start Menu;
- supports safe repeated execution as an in-place update;
- never copies tests, development documents, worktrees, transcripts, or local user files;
- leaves `%APPDATA%\YouTubeTranscriptTool\settings.json` outside the installation directory so upgrades preserve preferences.

The installed application continues to use the existing `.cmd` launcher, WinForms script, shared module, worker, lifecycle helper, CLI scripts, and bundled `yt-dlp.exe`.

`uninstall.cmd` launches `uninstall.ps1`. Installation writes a marker containing the canonical installation path and the copied-file manifest. The uninstaller removes only marker-listed files and shortcuts that point into that exact installation directory, then removes directories only when they are empty. Unrelated files in a custom installation directory are preserved. User settings remain by default; an explicit switch may remove them.

For automated tests, the PowerShell scripts accept explicit installation, desktop-shortcut, and Start-Menu directories. Production defaults remain the current user's standard Windows folders.

## Packaging

`build-package.ps1` creates `youtube-transcript-tool-windows.zip` from the same explicit runtime allowlist used by installation. The archive contains the application plus `install.cmd`, `install.ps1`, `uninstall.cmd`, `uninstall.ps1`, and the user-facing README. A user may install from either a downloaded repository ZIP or the CI-produced application archive.

## Continuous Integration

Add `.github/workflows/windows-ci.yml` with:

- triggers for pull requests targeting `desktop-transcript-tool`, pushes to that branch, and manual dispatch;
- one `windows-latest` job with read-only repository permissions;
- concurrency cancellation for superseded runs on the same ref;
- a bounded timeout;
- PowerShell parser validation for every tracked `.ps1` and `.psm1` file;
- the GUI smoke, GUI lifecycle, module, CLI, and installer regression suites;
- package creation and archive-content validation;
- upload of the Windows ZIP as a workflow artifact.

The job remains sequential so process-lifecycle and GUI tests do not compete for the same runner desktop, and the pull request has one unambiguous required result.

## Testing

Add `tests/run-install-tests.ps1` covering:

- installation into an isolated temporary directory;
- the exact runtime allowlist;
- desktop and Start Menu shortcut targets and working directories;
- idempotent reinstall/update;
- exclusion of tests and unrelated source-tree files;
- package archive contents;
- uninstall cleanup;
- preservation of user settings by default.

All existing regression suites remain mandatory. Before merge, the workflow must complete successfully on GitHub, not only locally.

## Error Handling and Safety

- Missing runtime files fail before copying anything.
- Installation paths are canonicalized and must not be a filesystem root, user-profile root, or another broad directory.
- Uninstall validates the exact installation marker, copied-file manifest, and shortcut targets before removing files.
- File copying uses an operation-specific staging directory beside the destination, followed by replacement of known application files.
- Unrelated files already present in a chosen custom installation directory are not silently deleted during installation or uninstall.
- Failure messages identify the affected path and the corrective action.

## Non-Goals

- No system-wide installation or administrator elevation.
- No registry-based Add/Remove Programs entry.
- No MSI/MSIX, code-signing certificate, or automatic updater.
- No UI redesign.
- No automatic publishing of a GitHub Release until a versioning policy is chosen.
