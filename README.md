# Teams Presence Chroma

Mirrors your Microsoft Teams presence on the RGB lighting of your **Razer Goliathus
Extended Chroma** mousemat:

| Teams status                      | Mousemat              |
|-----------------------------------|------------------------|
| Busy / Do not disturb             | **Red**, static        |
| Available, Away, Offline, ...     | **White**, static      |

Runs as an invisible PowerShell script in the background with a small icon in the
notification area (system tray). No extra software, no Razer Synapse, no Microsoft 365 /
Graph sign-in and no app registration in Entra ID — everything runs locally.

Contents:
- `TeamsPresenceChroma.ps1` – the program itself (including diagnostics in the tray menu)
- `config.json` – your settings (colors, interval, states, detection pattern)
- `Install-Autostart.ps1` – enables autostart (`-Uninstall` disables it again)

---

## How it works

The new Microsoft Teams client writes every presence change to its debug log file:

```
%LOCALAPPDATA%\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs\MSTeams_*.log
```

Such a line looks like this:

```
... UserDataCrossCloudModule: Received Action: UserPresenceAction: {cloud_context: https://teams.microsoft.com, availability: DoNotDisturb}
```

On startup the script looks for the most recently written `availability` value (including
older, rotated log files) and then reads only the new lines every few seconds. If Teams is
not running, the status counts as "Offline" (white).

This is **not a method supported by Microsoft**: a Teams update can change the log format
at any time (see "When detection stops working").

The mousemat is controlled directly over USB (Razer HID protocol, as used by OpenRGB and
OpenRazer). Synapse does not work with this mat — it accepts Chroma commands but does not
pass them on to the mat — and Windows 11 "Dynamic Lighting" does not support it.

## 1. Quit Razer Synapse

If Synapse is running, it immediately overwrites the color again. Quit Synapse and disable
it in autostart (Windows Settings → Apps → Startup). Without any software the mat shows its
built-in rainbow effect until the script is running.

## 2. config.json (optional)

```json
{
  "PollSeconds": 5,
  "ColorBusyHex": "FF0000",
  "ColorDefaultHex": "FFFFFF",
  "BusyStates": ["Busy", "BusyIdle", "DoNotDisturb", "InACall", "InAMeeting", "Presenting"],
  "StatusLogPattern": "...",
  "TeamsLogPathOverride": ""
}
```

- `PollSeconds`: how often (in seconds) the status is checked.
- `ColorBusyHex` / `ColorDefaultHex`: RGB hex colors (`RRGGBB`).
- `BusyStates`: which Teams states result in `ColorBusyHex` (case and spaces don't matter).
  All others result in `ColorDefaultHex`.
- `StatusLogPattern`: regular expression that detects the status in the log line. Only
  change it if detection stops working.
- `TeamsLogPathOverride`: normally leave empty; forces a fixed log file path.

Changes take effect after restarting the program. If `config.json` is invalid (invalid
JSON, wrong color, invalid pattern), the program reports this on startup.

## 3. Start and verify

Right-click `TeamsPresenceChroma.ps1` → **"Run with PowerShell"** (if the execution policy
blocks this, start it via the autostart shortcut from step 4).

A dot appears in the tray (gray = loading/error, red/white = current status). Right-click
shows the status, "Refresh now", "Show diagnostics", "Open log file" and "Exit". Only one
instance runs at a time.

To verify, briefly switch to "Do not disturb" in Teams and back — the mat should turn red
and then white again. If not: **"Show diagnostics"** shows the log file, the last
detected status lines, the pattern and whether the mousemat was found.

## 4. Set up autostart

Right-click `Install-Autostart.ps1` → "Run with PowerShell". From the next sign-in on, the
program starts invisibly (no console window). To undo:

```
powershell -ExecutionPolicy Bypass -File .\Install-Autostart.ps1 -Uninstall
```

This only removes the autostart; quit a running instance via the tray menu ("Exit").

## Troubleshooting

Log: `%LOCALAPPDATA%\TeamsPresenceChroma\log.txt` (or tray menu → "Open log file").

- **Mat reverts to a Synapse profile:** Synapse is running again — quit it (step 1). The
  diagnostics point this out as well.
- **Tray icon gray, mat white:** An error occurred (e.g. Teams log not readable); the mat
  is then set to the default color so it doesn't stay red by mistake. The cause is in the
  log or the diagnostics.
- **"Razer Goliathus Extended Chroma not found":** Connect the mat via
  USB; the program looks for it again on every cycle.
- **Mat briefly shows the rainbow after standby:** normal, the color is resent every 30
  seconds.

### When detection stops working (e.g. after a Teams update)

1. Briefly change your status in Teams, then choose "Show diagnostics" in the tray menu.
2. If no matches are found: open the current log file (path shown in the diagnostics) in
   a text editor and look for the new status line (e.g. search for "Busy" or "Available").
3. Adjust `StatusLogPattern` in `config.json` to match that line (the group `(...)` must
   capture exactly the status value).
4. Quit the program via the tray menu and start it again.

If this becomes too much maintenance in the long run: the official Teams "third-party app
API" (Settings → Privacy) only provides meeting state, not "Busy"/"Do not disturb";
[PresenceLight](https://github.com/isaacrlevin/presencelight) covers everything but
requires a Microsoft Graph sign-in.
