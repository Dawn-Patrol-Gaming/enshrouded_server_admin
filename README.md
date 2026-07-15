# Enshrouded Server Restart

A small Windows console utility (Delphi) that **gracefully restarts an [Enshrouded](https://store.steampowered.com/app/1203620/Enshrouded/) dedicated server** on a schedule. It sends a real `Ctrl+C` to the running server so it writes a fresh world save and exits cleanly, waits for it to exit, zips the savegame folder and the `enshrouded_server.json` settings file, optionally runs a SteamCMD update, and relaunches the server — all driven by a simple `.ini` file.

Designed to be run from **Windows Task Scheduler** for unattended daily restarts.

Sibling project to [SCUM Server Restart](https://github.com/Dawn-Patrol-Gaming/scum_server_admin) — same architecture, adapted for Enshrouded.

---

## Why this exists

Enshrouded's dedicated server has **no RCON** and no remote shutdown command. Killing `enshrouded_server.exe` via Task Manager (or `Stop-Process -Force`) skips the shutdown save and is the leading cause of corrupted or rolled-back worlds — the server only writes a rolling world save every ~10 minutes and **on clean shutdown**. The developer-documented way to stop it is pressing **`Ctrl+C`** in its console window, which triggers its save-and-exit handler.

Doing that reliably from a separate process is fiddly (console attachment, integrity levels, sessions), so this tool packages the working approach into one scheduled executable.

---

## Features

- **Graceful shutdown** via `AttachConsole` + `GenerateConsoleCtrlEvent(CTRL_C_EVENT)` — the same thing as pressing Ctrl+C in the server window.
- **Waits for a clean exit** (configurable timeout) before continuing — save time scales with world size / player count.
- **Timestamped savegame backup** — zips the entire `savegame` folder to `yyyy_mm_dd_hh_nn_ss.zip` while the server is stopped (so files are flushed and unlocked).
- **Separate settings backup** — zips `enshrouded_server.json` (top-level `*.json` in the install root) to its own `settings_<timestamp>.zip`.
- **Optional SteamCMD update** — toggle in the `.ini`; SteamCMD's output is captured line-by-line into the log.
- **Live backups while the server runs** (`/autoarchive`) — waits for the save rotation to go quiet (`-index` matching the newest rotation slot), copies the savegame folder to staging, re-verifies nothing changed, then zips it. Schedule it hourly alongside the nightly restart.
- **Automatic restart** — relaunches the server with the correct working directory (Enshrouded reads `enshrouded_server.json` from there; no command-line arguments needed).
- **All settings in an `.ini` file** — no recompilation to change paths, arguments, or timings.
- **Date-stamped logging** — every action is written to both the console and `logs\EnshroudedServerRestart\EnshroudedServerRestart_yyyy-mm-dd.log`. Each utility logs to its own subfolder, so the SCUM/Valheim/Enshrouded tools can all run from one folder without mixing logs.
- **Self-documenting first run** — if no `.ini` exists, it writes one with default values and exits so you can edit it.

---

## Requirements

- Windows (the Enshrouded dedicated server is Windows-only; tested on Windows Server 2019 / Windows 11).
- An Enshrouded dedicated server installed locally (SteamCMD app id **2278520** — note the *game* is 1203620; the *server* is 2278520).
- **Delphi** (the project targets Delphi 12+/13; uses only the standard RTL — no third-party packages) to build from source, **or** just grab a prebuilt `EnshroudedServerRestart.exe`.

---

## Building

1. Open `EnshroudedServerRestart\EnshroudedServerRestart.dpr` in Delphi (this generates the `.dproj` automatically — the repo deliberately doesn't ship one).
2. In **Project → Options → Application → Manifest**, set **Execution Level** (`AppExecutionLevel`) to **`requireAdministrator`** — see [Elevation](#elevation-required) below.
3. Build the **Release / Win32** (or Win64) configuration.

> **Debugging:** because the manifest requests elevation, the IDE must also be elevated to launch it under the debugger. Either run the Delphi IDE **as administrator**, or temporarily set the Debug config's execution level to *As invoker* (note: without elevation it cannot attach to an elevated server's console).

> **Prefer Free Pascal / Lazarus?** The code is Delphi-first, but it's plain Win32 + RTL and can be ported with a couple of small changes — see [docs/Building-with-Lazarus.md](docs/Building-with-Lazarus.md).

---

## Configuration

On first run, the tool looks for an `.ini` next to the executable (same base name, e.g. `EnshroudedServerRestart.ini`). If it's missing, a default one is created and the program exits so you can edit it.

> The config is **self-healing**: when you upgrade to a build that adds new options, any keys missing from your existing `.ini` are appended with their defaults on the next run — so new sections show up automatically. Review them before relying on them.

```ini
[Server]
; Executable name exactly as it appears in Task Manager
ExeName=enshrouded_server.exe
; Full path to the server executable
ExePath=C:\SteamCMD\enshrouded_server\enshrouded_server.exe
; Working directory for the server process (blank = folder of ExePath).
; IMPORTANT for Enshrouded: the server reads enshrouded_server.json from here.
WorkDir=C:\SteamCMD\enshrouded_server\
; Command-line arguments passed on restart. Enshrouded is configured entirely
; via enshrouded_server.json, so this is blank by default.
Args=

[Restart]
; Seconds to wait for the server to shut down cleanly before giving up
ShutdownTimeoutSec=120
; Seconds to wait after shutdown before relaunching
RestartDelaySec=10

[Backup]
; Savegame folder to back up (zipped recursively). Blank = skip backup.
; Default is <install>\savegame; if you changed "saveDirectory" in
; enshrouded_server.json, point this at that folder instead.
SaveDir=C:\SteamCMD\enshrouded_server\savegame
; Folder where the timestamped backup zips are written.
; Keep this OUTSIDE the server install folder so a Steam update can't wipe it.
BackupDir=C:\Enshrouded_Backups
; Savegame backup file name = <prefix><timestamp><suffix>.zip. Both may be blank.
SaveBackupPrefix=
SaveBackupSuffix=
; Folder holding enshrouded_server.json; top-level files matching SettingsMask
; are zipped (NON-recursive, since this is usually the install root). Blank = skip.
SettingsDir=C:\SteamCMD\enshrouded_server
SettingsMask=*.json
; Settings backup file name = <prefix><timestamp><suffix>.zip. Both may be blank.
SettingsBackupPrefix=settings_
SettingsBackupSuffix=

[Cleanup]
; Enshrouded server log folder, purged (all files deleted) only after a successful
; backup. Blank = skip (the default). If you set "logDirectory" in
; enshrouded_server.json (commonly "./logs"), you can point this there.
ServerLogDir=

[AutoArchive]
; Settings for the /autoarchive mode (live backup without stopping the server).
; [AutoArchive] + /autoarchive is the standard naming for this mode across the
; Dawn Patrol Gaming server tools.
; Destination folder for auto-archive zips. Same rule as BackupDir: keep it
; OUTSIDE the server install folder.
ArchiveDir=C:\Enshrouded_Backups\auto
; Auto-archive file name = <prefix><timestamp><suffix>.zip. Both may be blank.
ArchivePrefix=auto_
ArchiveSuffix=
; Base name of the save set (e.g. 3ad85aea). Blank = auto-detect every
; *-index file in SaveDir (normally there is exactly one).
SaveId=
; A flush counts as complete when <SaveId>-index and the NEWEST rotation slot
; (<SaveId>, <SaveId>-1..-n) have timestamps within this many seconds...
PairToleranceSec=2
; ...and the newer of the two is at least this many seconds old.
MinAgeSec=10
; How long to keep waiting for a consistent pair before giving up (exit code 5).
WaitTimeoutSec=120

[Update]
; Set to 1 to run a SteamCMD update (after backup, before restart). 0 = skip.
EnableUpdate=0
; Full path to steamcmd.exe
SteamCmdPath=C:\SteamCMD\steamcmd.exe
; Steam app id for the Enshrouded DEDICATED SERVER (not the game, which is 1203620)
SteamAppId=2278520
; Server install root passed to SteamCMD's +force_install_dir
InstallDir=C:\SteamCMD\enshrouded_server
```

> [!WARNING]
> **Put `BackupDir` on a different drive or path than the server install.** This matters even more for Enshrouded than for most games: the savegame folder lives **inside the install directory**, and a SteamCMD `validate`/update can delete and recreate the entire install folder. If your backups live under it (e.g. `...\enshrouded_server\Backups`), they get wiped right when you'd need them. Use somewhere like `C:\Enshrouded_Backups` instead.

### Settings reference

| Section | Key | Meaning |
|---|---|---|
| `Server` | `ExeName` | Process image name used to find the running server. **Required.** |
| `Server` | `ExePath` | Full path used to relaunch the server. **Required.** |
| `Server` | `WorkDir` | Working directory for the new process. Defaults to `ExePath`'s folder if blank. **The server reads `enshrouded_server.json` from here.** |
| `Server` | `Args` | Launch arguments on restart. Normally blank — Enshrouded is configured via its JSON file, not the command line. |
| `Restart` | `ShutdownTimeoutSec` | How long to wait for a clean exit before reporting failure. |
| `Restart` | `RestartDelaySec` | Pause between shutdown and relaunch. |
| `Backup` | `SaveDir` | Savegame folder zipped into the backup (recursive). Blank disables backup. |
| `Backup` | `BackupDir` | Destination folder for the zips (created if missing). **Point this *outside* the server install folder.** |
| `Backup` | `SaveBackupPrefix` / `SaveBackupSuffix` | Optional text before/after the timestamp in the savegame backup file name (`<prefix><timestamp><suffix>.zip`). Either may be blank. |
| `Backup` | `SettingsDir` | Folder whose top-level files matching `SettingsMask` are zipped to a separate settings backup (non-recursive). Blank disables. |
| `Backup` | `SettingsMask` | File mask for the settings backup. Default `*.json` picks up `enshrouded_server.json`. |
| `Backup` | `SettingsBackupPrefix` / `SettingsBackupSuffix` | Optional text before/after the timestamp in the settings backup file name. Either may be blank. |
| `Cleanup` | `ServerLogDir` | Folder whose files are deleted after a successful backup. Blank (default) disables purge. |
| `AutoArchive` | `ArchiveDir` | Destination folder for `/autoarchive` zips (created if missing). Keep it **outside** the server install folder. |
| `AutoArchive` | `ArchivePrefix` / `ArchiveSuffix` | Optional text before/after the timestamp in the auto-archive file name. Either may be blank. |
| `AutoArchive` | `SaveId` | Base name of the save set. Blank (default) auto-detects every `*-index` file in `SaveDir`. |
| `AutoArchive` | `PairToleranceSec` | Max seconds between `-index` and the newest rotation slot to count as one completed flush. |
| `AutoArchive` | `MinAgeSec` | The newest save files must be at least this old (seconds) — guards against catching a flush mid-write. |
| `AutoArchive` | `WaitTimeoutSec` | How long `/autoarchive` waits for a consistent pair before giving up with exit code `5`. |
| `Update` | `EnableUpdate` | `1` = run a SteamCMD update before restart; `0` = skip. |
| `Update` | `SteamCmdPath` | Full path to `steamcmd.exe`. |
| `Update` | `SteamAppId` | Steam app id of the Enshrouded dedicated server (`2278520`; configurable in case it ever changes). |
| `Update` | `InstallDir` | Server install root, passed to SteamCMD's `+force_install_dir`. |

---

## What it does, step by step

1. **Load config** and verify `ExePath` and `WorkDir` exist (errors out if not).
2. **Find** the running `enshrouded_server.exe`.
3. **Shut down gracefully** — attach to the server's console and send `Ctrl+C`, then wait up to `ShutdownTimeoutSec` for it to exit. The server writes a fresh world save as part of its Ctrl+C handling.
4. **Back up the savegame** — zip all of `SaveDir` to `BackupDir\yyyy_mm_dd_hh_nn_ss.zip`.
5. **Purge logs** — delete everything in `ServerLogDir` (if configured), **only if the savegame backup succeeded**.
6. **Back up settings** — zip top-level `*.json` under `SettingsDir` (i.e. `enshrouded_server.json`) to `BackupDir\settings_<timestamp>.zip`.
7. **Update** — if `EnableUpdate=1`, run SteamCMD (`+force_install_dir … +login anonymous +app_update 2278520 validate +quit`) and wait for it to finish. SteamCMD's output is captured line-by-line into the log file.
8. **Wait** `RestartDelaySec`, then **relaunch** the server from `WorkDir`.

A failed/skipped backup is logged but **does not** stop the restart. A failed log purge is logged per-file and is never fatal. A failed/disabled SteamCMD update is logged and the restart still proceeds.

---

## Live backups while the server runs (`/autoarchive`)

```
EnshroudedServerRestart.exe /autoarchive
```

> `/autoarchive` is the standard switch name across the Dawn Patrol Gaming server tools for "back up while the server keeps running" modes.

This mode **never touches the server** — no shutdown, no restart, no console attachment. It exists because a nightly restart backup alone leaves up to a day of progress unprotected, while naively zipping a live savegame folder risks a **torn snapshot** (files from two different save flushes mixed in one backup).

How it stays consistent:

1. Enshrouded saves in a **rotation**: each flush (roughly every 5–10 minutes and on shutdown) writes the world into the next slot file — `<SaveId>`, `<SaveId>-1` … `<SaveId>-n`, wrapping around — and rewrites `<SaveId>-index` to point at the slot just written. So the `-index` file always carries the timestamp of the latest flush, while the base `<SaveId>` file is usually several rotations old. When `-index` and the **newest** slot share a timestamp, the flush is complete and nothing is being written.
2. `/autoarchive` waits (up to `WaitTimeoutSec`) until `-index` and the newest slot match within `PairToleranceSec` **and** are at least `MinAgeSec` old.
3. It then **copies** the whole savegame folder to a staging folder (copying is fast; zipping is slow), and **re-checks the pair's timestamps**. If a new flush started mid-copy, the staging snapshot is discarded and it goes back to waiting.
4. Only a verified-unchanged snapshot is zipped to `ArchiveDir\<prefix><timestamp><suffix>.zip`. The zip includes the whole rotation, so each backup carries several fallback points; when restoring, the slot `-index` points at is the newest.

Two things a live backup can't do: it only captures what the server has *flushed to disk* (up to ~10 minutes of play still lives in server memory — only a Ctrl+C shutdown forces a save of the current instant), and it can time out with exit code `5` if no quiet window appears — the next scheduled run simply tries again.

Schedule it with the included [`Enshrouded Archive Autobackups.sample.xml`](Enshrouded%20Archive%20Autobackups.sample.xml) (hourly by default, offset to `:15` to stay clear of an on-the-hour restart task). This mode doesn't need to run in the server's session, but the exe's `requireAdministrator` manifest still requires *Run with highest privileges*.

---

## Scheduling with Task Scheduler

> [!IMPORTANT]
> ### Elevation required
> The server typically runs **elevated**, and you can only attach to an elevated process's console if you are **also elevated**. The exe ships with a `requireAdministrator` manifest; in Task Scheduler also tick **Run with highest privileges**.
>
> ### Must run in the same session
> `AttachConsole` only works within the **same Windows session** as the server. The scheduled task must use **"Run only when user is logged on"** (`InteractiveToken`) as the **same account** the server runs under. The "Run whether user is logged on or not" option (`Password`) runs in session 0 and fails with *Access is denied*. Keep that account logged in (disconnect RDP rather than logging off).

### Option A — import the sample (fastest)

A ready-to-edit [`Enshrouded Server Restart.sample.xml`](Enshrouded%20Server%20Restart.sample.xml) is included. It already has the two required options (`InteractiveToken` + `HighestAvailable`) set correctly.

1. Open the file in a text editor and change the two placeholders:
   - `<UserId>COMPUTERNAME\YourUser</UserId>` → the account the server runs under (or its SID).
   - `<Command>C:\SteamCMD\enshrouded_server\EnshroudedServerRestart.exe</Command>` → the path to your built exe.
   - Optionally adjust `<StartBoundary>` for your preferred restart time.
2. In **Task Scheduler → Action → Import Task…**, select the file.
3. When prompted, confirm the account and enter credentials if asked.

> The sample is saved as **UTF-16 with a BOM** — the only encoding Task Scheduler's importer accepts. If you recreate it in another editor, preserve that encoding or the import fails with *"one root element"*.

### Option B — create it by hand in the GUI

- **General:** Run only when user is logged on · Run with highest privileges.
- **Triggers:** Daily, at your chosen restart time.
- **Actions:** Start a program → `C:\SteamCMD\enshrouded_server\EnshroudedServerRestart.exe`.
- **Settings:** *Stop the task if it runs longer than 1 hour* (safety net).

### Starting the server at boot

If the server isn't running, this tool starts it — so you can also use it to bring the server up after a reboot. The key is that it must run **in the same interactive session** the server should live in (so later restarts can attach to its console). Suggested approach: set the box to **auto-log-on** the server account, and trigger the start **at log on** of that account (a logon-triggered task, or a login batch that calls `schtasks /run /tn "Enshrouded Server Restart"`) — not an "At startup" trigger, which runs in the isolated session 0.

---

## Logging

Every run appends to a date-stamped file alongside the executable, inside a per-app subfolder:

```
logs\EnshroudedServerRestart\EnshroudedServerRestart_2026-07-06.log
```

The subfolder is named after the exe, so when several of these restart utilities (SCUM / Valheim / Enshrouded) run side by side from one folder, each keeps its own logs. (Their `.ini` files are also named after each exe, so a shared folder just works.)

Each line is timestamped. The same output is echoed to the console when run interactively. `/autoarchive` runs log explicitly how many files were found to back up (or an `ERROR` if none were), so the log alone tells you whether a backup actually happened.

---

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success. |
| `2` | Server did not shut down cleanly within the timeout (restart aborted). |
| `3` | Configuration problem (missing/invalid `.ini`, a default was just written, or an unknown command-line parameter). |
| `4` | Server executable or working directory not found. |
| `5` | `/autoarchive` failed — no consistent save pair within `WaitTimeoutSec`, or the zip could not be written. |

Task Scheduler can be configured to alert on non-zero exit codes.

---

## Troubleshooting

| Symptom (in the log) | Cause / Fix |
|---|---|
| `AttachConsole(...) failed: Access is denied` | Not elevated, **or** running in a different session than the server. Use highest privileges + "Run only when user is logged on" as the server's account. |
| `session=0` (server `session=1`) | Task is running non-interactively (`Password`). Switch to `InteractiveToken`. |
| `Server did not exit within Ns` | Increase `ShutdownTimeoutSec`; large worlds / many players take longer to save. |
| `Backup skipped: ... not set` / `folder not found` | Check `SaveDir` / `BackupDir` paths in the `.ini`. If you customised `saveDirectory` in `enshrouded_server.json`, mirror that in `SaveDir`. |
| Server restarts but nobody can join / wrong config | The server was launched with the wrong working directory, so it created a fresh `enshrouded_server.json`. Make sure `WorkDir` is the folder containing your real JSON. |

---

## Notes

- Enshrouded keeps **rolling world saves** (a new copy roughly every 10 minutes and one on shutdown, overwriting the oldest). This tool's zip backup captures the whole `savegame` folder, so all rolling copies land in each backup.
- The graceful-shutdown behavior (Ctrl+C → save and exit) is the developer-documented stop method as of mid-2026; a future server build could change it. If restarts start corrupting saves after a game update, re-verify the Ctrl+C behavior.
- The Enshrouded dedicated server is **Windows-only** (Linux hosts run it under Wine/Proton); this tool targets the native Windows server.

---

## License

MIT — see [LICENSE](LICENSE).
