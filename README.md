# EVE Layout Copier

`EVE Layout Copier` is a small local Windows utility for copying EVE Online UI settings from one character to other characters in the same settings folder.

It scans your EVE settings directory, resolves character names from the `core_char_*` files through ESI, and lets you choose:

- one source character
- one or more recipient characters
- whether to copy `core_char`, `core_user`, or both

The app creates backups before overwriting files.

## What It Copies

EVE stores settings across two different file types:

- `core_char_*.dat`
  Per-character settings such as UI layout and window state.

- `core_user_*.dat`
  Shared or user-level settings such as certain shortcuts and related preferences.

The app treats these separately, so you can copy either one or both.

## Included Files

- `EveLayoutManager.exe`
  Windows launcher for the tool.

- `EveLayoutManager.ps1`
  Main PowerShell GUI script used by the launcher.

- `EveLayoutManagerLauncher.go`
  Source for the small launcher executable.

- `esi-name-cache.json`
  Local cache of character names resolved from ESI, if present.

## Requirements

- Windows
- PowerShell
- Access to your local EVE settings folder
- Internet access for ESI name lookup

If ESI is unavailable, the app can still scan files, but unresolved characters may appear as `Unknown [id]`.

## Supported Folder Discovery

The app searches under:

- `C:\Users\<YourUser>\AppData\Local\CCP\EVE`

It looks recursively for EVE settings folders such as:

- `...\g_eve_tq_tranquility\settings_Default`
- `...\d_steamlibrary_steamapps_common_eve_online_sharedcache_tq_tranquility\settings_Default`

You can also browse manually to a folder if it is not auto-detected.

## How To Use

1. Launch `EveLayoutManager.exe`.
2. Confirm the selected settings folder at the top of the window.
3. Click `Refresh` if needed.
4. Select the source pilot in the left panel.
5. Select one or more recipients in the right panel.
6. Choose whether to copy:
   `core_char`
   `core_user`
   or both.
7. Click `Copy To Selected`.
8. Confirm the overwrite prompt.

## Backups

Before any file is overwritten, the app creates a backup in a `backups` folder beside the original settings files.

Backups are grouped by timestamp so older copies can be restored manually if needed.

## Name Resolution

Character names are resolved using the EVE Swagger Interface endpoint:

- `POST https://esi.evetech.net/latest/universe/names/`

Only the character IDs discovered from `core_char_*` filenames are used for name lookup.

The README intentionally does not include any local IDs or account-specific data.

## Notes

- The currently selected source character is hidden from the recipient list.
- The app is meant for local personal use.
- The launcher `.exe` expects `EveLayoutManager.ps1` to stay in the same folder.

## Rebuilding The EXE

If you want to rebuild the launcher and have Go installed:

```powershell
$env:GOTELEMETRY='off'
go build -ldflags='-H=windowsgui' -o .\EveLayoutManager.exe .\EveLayoutManagerLauncher.go
```

## Building A Standalone Package From The `.ps1` And `.ini`

If you want to ship this as a single Windows app folder without requiring the user to launch the `.ps1` manually, use `PS2EXE` to compile the PowerShell GUI into an `.exe`, then place `prefs.ini` beside it.

### What "standalone" means here

- `EveLayoutManager.ps1` becomes `EveLayoutManager.exe`
- `prefs.ini` stays as a normal config file next to the `.exe`
- the result is a distributable folder, not a mathematically single-file binary

That is the most reliable option for PowerShell GUI apps. If you truly need one physical file, the next step would be updating the script to embed default INI content and read it from inside the executable at runtime.

### One-time setup

Install `PS2EXE` in PowerShell:

```powershell
Install-Module -Name ps2exe -Scope CurrentUser
```

### Build command

This repo now includes a helper script:

```powershell
.\Build-Standalone.ps1
```

That script will:

- compile `EveLayoutManager.ps1` into `dist\standalone\EveLayoutManager.exe`
- copy `prefs.ini` into the same output folder
- copy `esi-name-cache.json` too, if it exists

If you want to rebuild from a clean output folder:

```powershell
.\Build-Standalone.ps1 -Clean
```

### Output

After the build, distribute the contents of:

```text
dist\standalone
```

At minimum that folder will contain:

- `EveLayoutManager.exe`
- `prefs.ini`

### Important note

Right now `prefs.ini` is not read by `EveLayoutManager.ps1`, so it is packaged as a sidecar file for future compatibility or other tooling rather than because the current GUI script depends on it.

## Safety

- Review recipients carefully before copying settings.
- Keep backups if you are testing different layouts.
- If you only want window/layout changes, copy `core_char` only.
- If you also want shared shortcut-style settings, include `core_user`.
