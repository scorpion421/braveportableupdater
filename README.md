# Brave Portable Updater

A standalone PowerShell updater for **Brave Portable (Portapps-style layout)** with a native Windows desktop UI.

This project provides a one-click way to check for updates, download official Brave release archives from GitHub, install the selected channel, and launch Brave—without external package managers or additional runtime dependencies.

This updater exists specifically for the Portapps portable ecosystem and is intended to complement the upstream Brave Portable work from Portapps.

---

## Highlights

- **Native desktop interface (WPF)** with clear update status and progress visualization.
- **Channel-aware updates** for:
  - Stable
  - Beta
  - Nightly
- **Smart release detection** using the Brave GitHub Releases API.
- **Safe update workflow** with staged progress:
  1. Download
  2. Extract
  3. Install
  4. Complete
- **Configuration persistence** in local JSON (channel choice, skipped version, last check, auto-check behavior).
- **Launch helper** to start Brave Portable directly after updating.
- **No external dependencies** beyond built-in Windows PowerShell/.NET components.

---

## What This Tool Does

When you start the updater, it can automatically check for a newer release (depending on settings). On update:

1. Queries Brave releases from GitHub.
2. Selects the correct Windows 64-bit archive asset.
3. Downloads the archive to a temporary folder.
4. Extracts files.
5. Replaces the current version folder inside the local `app` directory.
6. Cleans up temporary data.
7. Updates local state and allows immediate launch.

It also handles channel switching (for example, Stable → Beta) as a valid install operation.

---

## Expected Folder Layout

Place the updater script in the root of your Brave Portable directory structure.

Example layout:

```text
braveportableupdater/
├─ bravepudater.ps1
├─ braveupdater.json          (created automatically)
├─ app/
│  └─ <version>/
│     └─ brave.exe
├─ data/
└─ brave-portable*.exe        (optional launcher detection)
```

> The updater is designed around this portable layout and manages versioned subfolders under `app`.

---

## Requirements

- Windows with PowerShell support for WPF.
- Network access to:
  - `api.github.com`
  - Brave release asset download endpoints
- Write permissions in the portable directory.

---

## Usage

1. Open PowerShell in the project directory.
2. Run:

```powershell
.\bravepudater.ps1
```

3. In the UI:
   - Choose update channel.
   - Click **Check for updates**.
   - Click **Update now** when available.
   - Optionally click **Launch Brave** when done.

---

## Configuration

The updater stores settings in `braveupdater.json` in the same directory as the script.

Typical values include:

- Selected channel
- Installed channel tracking
- Skipped version
- Last check timestamp
- Auto-check on startup flag

If the config is missing or invalid, defaults are restored automatically.

---

## Operational Notes

- Uses modern TLS protocol settings for release checks and downloads.
- Performs download/extract/install in a background runspace to keep UI responsive.
- Progress and status are reported in near real time.
- Existing version directories are removed before copying the new version into `app`.

---

## Troubleshooting

### No update found
- Verify internet connectivity.
- Confirm the selected channel has a matching Windows x64 ZIP release available.

### Launch failed
- Ensure a valid Brave executable exists in the expected portable structure.
- Ensure files were not quarantined or blocked by endpoint security.

### Update failed mid-process
- Retry with administrative rights if filesystem permissions are restricted.
- Make sure Brave is not running while replacing files.

---

## Security & Trust

This updater only pulls release metadata and archives from Brave’s official GitHub release sources. Always review downloaded artifacts and run software in accordance with your own security standards.

---

## License

See [`LICENSE.md`](LICENSE.md) for full terms.

---

## Acknowledgements

Special thanks and full credit to the upstream project:

- **Portapps Brave Portable**: https://github.com/portapps/brave-portable

This project depends on and extends that portable distribution concept. Without that foundation, this updater would not exist.
