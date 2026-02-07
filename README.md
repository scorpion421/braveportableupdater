<p align="center">
  <img src="https://brave.com/static-assets/images/brave-logo-sans-text.svg" width="80" alt="Brave Logo"/>
</p>

<h1 align="center">Brave Portable Updater</h1>

<p align="center">
  A zero-dependency PowerShell updater with native Windows UI for
  <a href="https://github.com/portapps/brave-portable">Brave Portable (Portapps)</a>.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-Windows-0078D4?logo=windows&logoColor=white" alt="Windows"/>
  <img src="https://img.shields.io/badge/shell-PowerShell%205.1%2B-5391FE?logo=powershell&logoColor=white" alt="PowerShell"/>
  <img src="https://img.shields.io/badge/UI-WPF-6a1b9a" alt="WPF"/>
  <img src="https://img.shields.io/badge/dependencies-none-44CF6C" alt="Zero dependencies"/>
  <img src="https://img.shields.io/badge/license-see%20LICENSE.md-A0A1B2" alt="License"/>
</p>

---

## Why?

Brave Portable via [Portapps](https://github.com/portapps/brave-portable) doesn't ship with an auto-updater. This tool fills that gap: check for new releases, pick your channel, download, extract, install — all from a single script with a clean desktop UI. No installers, no admin rights, no runtime dependencies beyond what Windows already provides.

---

## Features

| | |
|---|---|
| **Channel switching** | Freely move between Stable, Beta, and Nightly. The updater tracks which channel is installed and treats channel changes as valid updates — even when the target version number is lower. |
| **Live progress** | Download speed, transferred bytes, and a four-stage progress indicator (`Download > Extract > Install > Done`) update in real time without freezing the UI. |
| **Non-blocking updates** | The entire download/extract/install pipeline runs in a background runspace. The WPF window stays fully responsive throughout. |
| **Smart version detection** | Reads the Portapps `app/<chromium>.<major>.<minor>.<patch>` folder structure to determine the installed Brave version automatically. |
| **Skip & remember** | Skip a specific release and the updater won't nag about it again (until a newer one appears or you change channels). |
| **Auto-check on launch** | Optionally checks for updates every time the script starts. Configurable in `braveupdater.json`. |
| **Launch helper** | Start Brave Portable directly from the updater after installing. Detects `brave-portable*.exe` or falls back to `brave.exe` inside the version folder. |
| **Zero dependencies** | No 7-Zip, no curl, no external modules. Uses `Expand-Archive`, `HttpWebRequest`, and built-in .NET/WPF assemblies. |

---

## Screenshots

<!-- Replace with actual screenshots after first release -->
<!-- ![Updater main window](docs/screenshot-main.png) -->
<!-- ![Update in progress](docs/screenshot-progress.png) -->

*Screenshots will be added after the first public release.*

---

## Folder Layout

Place the script in the root of your Brave Portable directory:

```
Brave/
├── braveportableupdater.ps1    ← the updater
├── braveupdater.json           ← created automatically on first run
├── app/
│   └── 136.1.78.102/           ← version folder (chromium.brave)
│       └── brave.exe
├── data/
└── brave-portable*.exe         ← Portapps launcher (optional)
```

> The updater manages versioned subfolders under `app/`. Non-version directories like `Dictionaries/` are left untouched during updates.

---

## Quick Start

**Option A** — Right-click `braveportableupdater.ps1` → *Run with PowerShell*.

**Option B** — From a PowerShell prompt:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\braveportableupdater.ps1
```

Then in the UI:

1. Select a channel (Stable / Beta / Nightly).
2. Click **Manual Check** (or let auto-check do its thing).
3. Click **Update** when an update is available.
4. Click **Start Brave** when done.

---

## Configuration

Settings are stored in `braveupdater.json` next to the script. The file is created automatically with sensible defaults on first run.

| Key | Default | Description |
|-----|---------|-------------|
| `Channel` | `"Stable"` | Last selected update channel. |
| `InstalledChannel` | `""` | Channel of the currently installed version. Enables cross-channel switching. |
| `SkippedVersion` | `""` | Version string the user chose to skip. Cleared on channel switch or successful update. |
| `LastCheckUtc` | `""` | ISO 8601 timestamp of the last update check. |
| `AutoCheckOnStart` | `true` | Whether to check for updates automatically when the UI opens. |

If the file becomes corrupted or a key is missing, the updater merges defaults in silently.

---

## How It Works

### Architecture

```
┌─────────────────────────────────────┐
│         WPF Window (UI Thread)      │
│                                     │
│  ┌──────────┐  ┌─────────────────┐  │
│  │ Controls │  │ DispatcherTimer │  │
│  │ & Events │  │  (150ms poll)   │  │
│  └──────────┘  └───────┬─────────┘  │
│                        │ reads      │
│              ┌─────────▼──────────┐ │
│              │  Synchronized{}    │ │
│              │  (shared state)    │ │
│              └─────────▲──────────┘ │
└────────────────────────┼────────────┘
                         │ writes
              ┌──────────┴───────────┐
              │  Background Runspace │
              │                      │
              │  1. HttpWebRequest   │
              │     (download)       │
              │  2. Expand-Archive   │
              │     (extract)        │
              │  3. Copy-Item        │
              │     (install)        │
              └──────────────────────┘
```

The UI thread never performs blocking I/O. A background PowerShell runspace handles the full update pipeline and communicates progress through a `[hashtable]::Synchronized()` object. A `DispatcherTimer` on the UI thread polls this shared state every 150ms to update the progress bar, step indicators, and status text.

### Release Detection

The updater queries the [Brave Browser GitHub Releases API](https://api.github.com/repos/brave/brave-browser/releases) and filters by:

- **Channel keywords** in the release name (`Release` / `Beta` / `Nightly`)
- **Prerelease flag** (Stable requires `prerelease: false`)
- **Asset name** matching `brave-v<VERSION>-win32-x64.zip` (excludes debug symbol archives)

### Version Comparison

Installed version is derived from the folder name in `app/`:

```
136.1.78.102  →  Chromium 136, Brave 1.78.102
```

When comparing against the latest release:

- **Same channel**: standard semver comparison — newer version triggers an update.
- **Different channel**: always offered as an update, regardless of version direction (downgrade from Nightly to Stable is valid).
- **Skipped version**: shown but not auto-suggested, unless the channel changed.

---

## Requirements

- **OS**: Windows 10 / 11 (or Server 2016+)
- **PowerShell**: 5.1 or later (ships with Windows)
- **Network access** to:
  - `api.github.com` (release metadata)
  - `github.com` / `objects.githubusercontent.com` (asset downloads)
- **Write access** to the portable directory

No elevated permissions required unless the directory itself is restricted.

---

## Troubleshooting

**"No release found"** — Check your internet connection. Verify that the selected channel actually has a `win32-x64.zip` asset on the [releases page](https://github.com/brave/brave-browser/releases).

**"Remote name could not be resolved"** — TLS issue or DNS problem. The script forces TLS 1.2/1.3 at startup, but corporate proxies or restrictive firewalls may interfere. Try accessing `https://api.github.com` in a browser first.

**"Launch failed"** — No `brave-portable*.exe` found in the script directory, and no `brave.exe` in the version folder. Verify the Portapps layout is intact.

**Update failed mid-process** — Make sure Brave is fully closed before updating. The updater needs to delete and replace files in the `app/` directory. Retry if endpoint security quarantined extracted files.

**UI freezes during download** — Should not happen with the background runspace architecture. If it does, check for third-party PowerShell profile scripts that might interfere with runspace creation.

---

## Security

This updater downloads release metadata and archives exclusively from [Brave's official GitHub repository](https://github.com/brave/brave-browser/releases). No third-party sources, no telemetry, no network calls beyond what's needed for the update check and download.

Always review software before running it, and verify downloads against your own security requirements.

---

## Acknowledgements

This project exists because of the work done by the [Portapps](https://portapps.io/) team. Full credit for the portable Brave distribution concept goes to:

- **[Portapps Brave Portable](https://github.com/portapps/brave-portable)** by [CrazyMax](https://github.com/crazy-max)

This updater is a companion tool that extends the portable distribution with automated update capabilities.

---

## License

See [`LICENSE.md`](LICENSE.md) for full terms.
