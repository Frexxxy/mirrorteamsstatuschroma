# =====================================================================================
#  TeamsPresenceChroma.ps1
#
#  Mirrors the Microsoft Teams presence status on the RGB lighting of the
#  Razer Goliathus Extended Chroma mousemat:
#     - Busy / Do not disturb  -> red, static
#     - everything else        -> white, static
#
#  Runs invisibly in the background with an icon in the notification area
#  (system tray).
#
#  IMPORTANT: This deliberately uses NO Microsoft Graph API and NO app
#  registration in Microsoft Entra ID / Azure AD - there is no cloud sign-in.
#  Instead the script reads the Teams client's debug log file locally, which
#  Teams writes every presence change to anyway, and detects the current status
#  with a text pattern. This is an unofficial mechanism not documented by
#  Microsoft (see README.md, sections "How it works" and "When detection stops
#  working").
#
#  The mousemat is controlled directly over USB (Razer HID protocol, as in
#  OpenRGB/OpenRazer) - Razer Synapse is NOT needed and must not be running,
#  because it would overwrite the lighting again.
#
#  Requirements (see README.md):
#   1. Razer Synapse quit (or not in autostart)
#   2. The "new" Microsoft Teams client (work/school) is installed and has
#      been used at least once (so a log file exists)
#   3. config.json in the same folder (the defaults usually work as is)
# =====================================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Only one instance at a time (e.g. autostart + manual start)
# ---------------------------------------------------------------------------
$createdNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, 'Local\TeamsPresenceChroma', [ref]$createdNew)
if (-not $createdNew) {
    [System.Windows.Forms.MessageBox]::Show(
        "Teams Presence Chroma is already running (see the icon in the notification area of the taskbar).",
        "TeamsPresenceChroma", 'OK', 'Information') | Out-Null
    exit 0
}

# ---------------------------------------------------------------------------
# Paths / log
# ---------------------------------------------------------------------------
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath  = Join-Path $ScriptDir 'config.json'
$DataDir     = Join-Path $env:LOCALAPPDATA 'TeamsPresenceChroma'
$LogPath     = Join-Path $DataDir 'log.txt'
$MaxLogBytes = 1MB

if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

function Write-Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    try {
        if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt $MaxLogBytes) {
            Move-Item -Path $LogPath -Destination (Join-Path $DataDir 'log.old.txt') -Force
        }
        Add-Content -Path $LogPath -Value $line
    } catch {}
}

# Don't write the same error message to the log every few seconds.
$script:LastErrorMessage = $null
function Write-ErrorOnce([string]$msg) {
    if ($msg -ne $script:LastErrorMessage) {
        Write-Log $msg
        $script:LastErrorMessage = $msg
    }
}

# ---------------------------------------------------------------------------
# Make startup errors visible: in autostart the script runs without a window,
# so an abort (e.g. a typo in config.json) would otherwise go unnoticed.
# Update-Status handles errors during normal operation itself; anything else
# (e.g. from a menu click) is only logged once the script has started.
# ---------------------------------------------------------------------------
$script:Started = $false
trap {
    if ($script:Started) {
        Write-Log "Error: $_"
        continue
    }
    Write-Log "Startup failed: $_"
    if ($notifyIcon) { $notifyIcon.Dispose() }
    [System.Windows.Forms.MessageBox]::Show(
        "Teams Presence Chroma could not be started:`n`n$_",
        "TeamsPresenceChroma", 'OK', 'Error') | Out-Null
    exit 1
}

# ---------------------------------------------------------------------------
# Load configuration
# ---------------------------------------------------------------------------
if (-not (Test-Path $ConfigPath)) {
    throw "config.json was not found in the folder:`n$ScriptDir`n`nPlease create config.json as described in README.md."
}

try {
    $Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
} catch {
    throw "config.json is not valid JSON: $($_.Exception.Message)"
}

$DefaultStatusLogPattern = 'UserPresenceAction:\s*\{[^}]*?availability:\s*"?([A-Za-z]+)'
$DefaultBusyStates       = @('Busy', 'BusyIdle', 'DoNotDisturb', 'InACall', 'InAMeeting', 'Presenting')

$PollSeconds      = if ($Config.PollSeconds) { [Math]::Max(1, [int]$Config.PollSeconds) } else { 5 }
$StatusLogPattern = if ($Config.StatusLogPattern) { $Config.StatusLogPattern } else { $DefaultStatusLogPattern }
$ColorBusyHex     = if ($Config.ColorBusyHex) { $Config.ColorBusyHex } else { 'FF0000' }
$ColorDefaultHex  = if ($Config.ColorDefaultHex) { $Config.ColorDefaultHex } else { 'FFFFFF' }

# Teams states that result in "red" - compared in lower case, without spaces.
function ConvertTo-NormalizedState([string]$state) { ($state -replace '\s', '').ToLowerInvariant() }
$BusyStates = @(@(if ($Config.BusyStates) { $Config.BusyStates } else { $DefaultBusyStates }) |
    ForEach-Object { ConvertTo-NormalizedState $_ })

try {
    $StatusRegex = [regex]::new($StatusLogPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
} catch {
    throw "StatusLogPattern in config.json is not a valid regular expression: $($_.Exception.GetBaseException().Message)"
}

# ---------------------------------------------------------------------------
# Hex color (RRGGBB, as usual) -> RGB bytes
# ---------------------------------------------------------------------------
function Convert-HexToRgb([string]$hex) {
    $hex = $hex.TrimStart('#')
    if ($hex -notmatch '^[0-9A-Fa-f]{6}$') {
        throw "Invalid color '$hex' in config.json (expected: RRGGBB, e.g. FF0000)."
    }
    return ,[byte[]]@(
        [Convert]::ToByte($hex.Substring(0,2), 16),
        [Convert]::ToByte($hex.Substring(2,2), 16),
        [Convert]::ToByte($hex.Substring(4,2), 16))
}

$ColorBusy    = Convert-HexToRgb $ColorBusyHex
$ColorDefault = Convert-HexToRgb $ColorDefaultHex

# ---------------------------------------------------------------------------
# Find the Teams log files (new Teams client preferred, classic as fallback)
# Returns: all candidates, newest first.
# ---------------------------------------------------------------------------
function Get-TeamsLogFiles {
    if (-not [string]::IsNullOrWhiteSpace($Config.TeamsLogPathOverride)) {
        if (Test-Path $Config.TeamsLogPathOverride) { return @(Get-Item $Config.TeamsLogPathOverride) }
        return @()
    }

    $candidates = @()

    $newTeamsDir = Join-Path $env:LOCALAPPDATA 'Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs'
    if (Test-Path $newTeamsDir) {
        $candidates += Get-ChildItem -Path $newTeamsDir -Filter 'MSTeams_*.log' -ErrorAction SilentlyContinue
    }

    # Fallback: classic (now retired) Teams client
    $classicLog = Join-Path $env:APPDATA 'Microsoft\Teams\logs.txt'
    if (Test-Path $classicLog) {
        $candidates += Get-Item $classicLog -ErrorAction SilentlyContinue
    }

    # With equal modification times (when rotating, Teams creates the new, empty
    # file at the same moment) the name, which contains the timestamp, decides.
    return @($candidates | Sort-Object LastWriteTime, Name -Descending)
}

# Reads a file from byte position $start (even while Teams is writing to it)
# and returns the complete lines plus the position after the last complete
# line (a half-written last line is read again next time).
function Read-LogFrom([string]$path, [long]$start) {
    $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite, Delete')
    try {
        if ($start -gt $fs.Length) { $start = 0 }   # file was truncated/recreated
        $count = [int]($fs.Length - $start)
        $bytes = New-Object byte[] $count
        $fs.Position = $start
        $read = 0
        while ($read -lt $count) {
            $n = $fs.Read($bytes, $read, $count - $read)
            if ($n -le 0) { break }
            $read += $n
        }
    } finally {
        $fs.Dispose()
    }

    $lastNewline = if ($read -gt 0) { [Array]::LastIndexOf($bytes, [byte]10, $read - 1) } else { -1 }
    if ($lastNewline -lt 0) {
        return [pscustomobject]@{ Lines = @(); NextPos = $start }
    }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes, 0, $lastNewline + 1)
    return [pscustomobject]@{
        Lines   = $text -split "\r?\n"
        NextPos = $start + $lastNewline + 1
    }
}

# Find the last status match in a set of lines (or $null).
# Search backwards: the most recent match is usually near the end.
function Find-LastStatus($lines) {
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $m = $StatusRegex.Match($lines[$i])
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Determine the current status from the Teams log files.
#
# Teams only writes a status line on a change - thousands of other lines can
# lie in between, and when the log file rotates, the status ends up in an
# older file. Therefore:
#   - the first time, search all log files (newest first) for the last
#     status entry,
#   - after that, only read the newly added lines of the current file and
#     keep the last known status - even if nothing was found the first time
#     (otherwise all logs would be read completely on every cycle).
# ---------------------------------------------------------------------------
$script:TeamsLogFile   = $null
$script:TeamsLogPos    = 0
$script:TeamsLastState = $null

function Initialize-TeamsStatus($files) {
    $script:TeamsLogFile = $files[0].FullName
    $script:TeamsLogPos  = 0
    foreach ($f in $files) {
        $chunk = Read-LogFrom $f.FullName 0
        if ($f.FullName -eq $script:TeamsLogFile) { $script:TeamsLogPos = $chunk.NextPos }
        $status = Find-LastStatus $chunk.Lines
        if ($status) {
            $script:TeamsLastState = $status
            Write-Log "Last status found in Teams log: $status ($($f.Name))"
            return
        }
    }
}

function Get-TeamsAvailability {
    # Teams not running -> the last log entry is stale.
    if (-not (Get-Process -Name 'ms-teams', 'Teams' -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Raw = 'Teams not running'; Normalized = 'offline' }
    }

    $files = Get-TeamsLogFiles
    if ($files.Count -eq 0) {
        throw "No Teams log file found. Is the new Teams client installed and has it been started at least once? See README and 'Show diagnostics' in the tray menu."
    }

    if (-not $script:TeamsLogFile) {
        Initialize-TeamsStatus $files
    } else {
        # New log file created (rotation)? -> read the rest of the old file, then switch.
        if ($files[0].FullName -ne $script:TeamsLogFile) {
            if ($script:TeamsLogFile -and (Test-Path $script:TeamsLogFile)) {
                $status = Find-LastStatus (Read-LogFrom $script:TeamsLogFile $script:TeamsLogPos).Lines
                if ($status) { $script:TeamsLastState = $status }
            }
            $script:TeamsLogFile = $files[0].FullName
            $script:TeamsLogPos  = 0
        }
        $chunk = Read-LogFrom $script:TeamsLogFile $script:TeamsLogPos
        $script:TeamsLogPos = $chunk.NextPos
        $status = Find-LastStatus $chunk.Lines
        if ($status) { $script:TeamsLastState = $status }
    }

    if (-not $script:TeamsLastState) {
        throw "No status entry found in the Teams log. Briefly change your status in Teams; if it still doesn't work, choose 'Show diagnostics' in the tray menu and adjust 'StatusLogPattern' in config.json if needed."
    }

    # Return the normalized value (for comparison) AND the original text (for display).
    return [pscustomobject]@{
        Raw        = $script:TeamsLastState
        Normalized = ConvertTo-NormalizedState $script:TeamsLastState
    }
}

# ---------------------------------------------------------------------------
# Diagnostics: show the last detected status lines from the log
# (helps adjust the pattern if Teams changes its log format)
# ---------------------------------------------------------------------------
function Show-Diagnostics {
    $files = Get-TeamsLogFiles
    if ($files.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "No Teams log file found.`n`nExpected location (new Teams client):`n$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs\MSTeams_*.log`n`nIs Teams installed and has it been started at least once?",
            "Diagnostics", 'OK', 'Warning') | Out-Null
        return
    }

    $found = @()
    foreach ($f in $files) {
        $hits = @((Read-LogFrom $f.FullName 0).Lines | Where-Object { $StatusRegex.IsMatch($_) })
        if ($hits.Count -gt 0) { $found = @($hits | Select-Object -Last 10); $hitFile = $f.FullName; break }
    }

    $matPath = [RazerHid]::FindControlPath($RazerVid, $GoliathusPid)
    $chromaInfo = if ($matPath) { "Mousemat: found ($matPath)" } else { "Mousemat: NOT found (connected via USB?)" }
    if (Get-Process -Name 'RazerAppEngine' -ErrorAction SilentlyContinue) {
        $chromaInfo += "`nWarning: Razer Synapse is running and may overwrite the lighting."
    }

    if ($found.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Log files searched: $($files.Count) (newest: $($files[0].FullName))`n`nNO lines matching the pattern were found.`nPattern: $StatusLogPattern`n`n$chromaInfo`n`nSee the README for how to adjust 'StatusLogPattern' in config.json.",
            "Diagnostics", 'OK', 'Warning') | Out-Null
    } else {
        [System.Windows.Forms.MessageBox]::Show(
            "Log file: $hitFile`n`nLast matching lines:`n`n" + ($found -join "`n") + "`n`nCurrently detected status: $($script:TeamsLastState)`nPattern: $StatusLogPattern`n`n$chromaInfo",
            "Diagnostics", 'OK', 'Information') | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Control the mousemat directly over USB (Razer HID protocol)
#
# Razer Synapse does not pass Chroma SDK commands on to this mat, and Windows
# "Dynamic Lighting" doesn't support it. So - as in OpenRGB/OpenRazer - the
# lighting effect is sent as a 90-byte feature report to the control
# interface (USB interface 0). The mat acknowledges every command with a
# status byte (0x02 = success).
# ---------------------------------------------------------------------------
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class RazerHid {
    [StructLayout(LayoutKind.Sequential)] struct SP_DEVICE_INTERFACE_DATA { public int cbSize; public Guid g; public int Flags; public IntPtr Reserved; }
    [StructLayout(LayoutKind.Sequential)] struct HIDP_CAPS { public ushort Usage; public ushort UsagePage; public ushort InputReportByteLength; public ushort OutputReportByteLength; public ushort FeatureReportByteLength; [MarshalAs(UnmanagedType.ByValArray, SizeConst=27)] public ushort[] Reserved; }
    [DllImport("hid.dll")] static extern void HidD_GetHidGuid(out Guid g);
    [DllImport("hid.dll")] static extern bool HidD_GetPreparsedData(SafeFileHandle h, out IntPtr p);
    [DllImport("hid.dll")] static extern bool HidD_FreePreparsedData(IntPtr p);
    [DllImport("hid.dll")] static extern int HidP_GetCaps(IntPtr p, out HIDP_CAPS c);
    [DllImport("hid.dll", SetLastError=true)] static extern bool HidD_SetFeature(SafeFileHandle h, byte[] b, int len);
    [DllImport("hid.dll", SetLastError=true)] static extern bool HidD_GetFeature(SafeFileHandle h, byte[] b, int len);
    [DllImport("setupapi.dll", SetLastError=true)] static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr e, IntPtr w, int f);
    [DllImport("setupapi.dll", SetLastError=true)] static extern bool SetupDiEnumDeviceInterfaces(IntPtr s, IntPtr d, ref Guid g, int i, ref SP_DEVICE_INTERFACE_DATA data);
    [DllImport("setupapi.dll", SetLastError=true, CharSet=CharSet.Auto)] static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr s, ref SP_DEVICE_INTERFACE_DATA d, IntPtr detail, int size, out int req, IntPtr info);
    [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr s);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Auto)] static extern SafeFileHandle CreateFile(string n, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr t);

    const int ReportLength = 91;   // report ID 0 + 90-byte Razer report

    static SafeFileHandle Open(string path) {
        // Mouse collections can only be opened without read/write access;
        // feature reports still work (same as hidapi).
        var h = CreateFile(path, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h.IsInvalid) h = CreateFile(path, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        return h;
    }

    // Path of the control interface (the collection with a 91-byte feature report) or null.
    public static string FindControlPath(ushort vid, ushort pid) {
        string needle = string.Format("vid_{0:x4}&pid_{1:x4}", vid, pid);
        Guid g; HidD_GetHidGuid(out g);
        IntPtr set = SetupDiGetClassDevs(ref g, IntPtr.Zero, IntPtr.Zero, 0x12);
        try {
            for (int i = 0; ; i++) {
                var d = new SP_DEVICE_INTERFACE_DATA(); d.cbSize = Marshal.SizeOf(d);
                if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref g, i, ref d)) break;
                int req; SetupDiGetDeviceInterfaceDetail(set, ref d, IntPtr.Zero, 0, out req, IntPtr.Zero);
                IntPtr buf = Marshal.AllocHGlobal(req);
                try {
                    Marshal.WriteInt32(buf, IntPtr.Size == 8 ? 8 : 6);
                    if (!SetupDiGetDeviceInterfaceDetail(set, ref d, buf, req, out req, IntPtr.Zero)) continue;
                    string path = Marshal.PtrToStringAuto(new IntPtr(buf.ToInt64() + 4));
                    if (!path.ToLowerInvariant().Contains(needle)) continue;
                    using (var h = Open(path)) {
                        if (h.IsInvalid) continue;
                        IntPtr p; if (!HidD_GetPreparsedData(h, out p)) continue;
                        HIDP_CAPS c; HidP_GetCaps(p, out c); HidD_FreePreparsedData(p);
                        if (c.FeatureReportByteLength == ReportLength) return path;
                    }
                } finally { Marshal.FreeHGlobal(buf); }
            }
        } finally { SetupDiDestroyDeviceInfoList(set); }
        return null;
    }

    // Static effect ("extended matrix"): class 0x0F, command 0x02.
    // Returns: the mat's status byte (0x02 = success).
    public static int SetStatic(string path, byte transactionId, byte r, byte g, byte b) {
        var rep = new byte[ReportLength];
        rep[2] = transactionId;
        rep[6] = 0x09;   // data length
        rep[7] = 0x0F;   // command class
        rep[8] = 0x02;   // command
        byte[] args = { 0x01, 0x00, 0x01, 0x00, 0x00, 0x01, r, g, b }; // VARSTORE, LED 0, STATIC, -, -, 1 color, RGB
        Array.Copy(args, 0, rep, 9, args.Length);
        byte crc = 0; for (int i = 3; i < 89; i++) crc ^= rep[i];
        rep[89] = crc;

        using (var h = Open(path)) {
            if (h.IsInvalid) throw new Exception("Could not open the mousemat (error " + Marshal.GetLastWin32Error() + ")");
            if (!HidD_SetFeature(h, rep, rep.Length)) throw new Exception("Sending to the mousemat failed (error " + Marshal.GetLastWin32Error() + ")");
            var resp = new byte[ReportLength];
            for (int attempt = 0; attempt < 10; attempt++) {
                System.Threading.Thread.Sleep(10);
                if (!HidD_GetFeature(h, resp, resp.Length)) throw new Exception("No response from the mousemat (error " + Marshal.GetLastWin32Error() + ")");
                if (resp[1] != 0x01) break;   // 0x01 = still busy
            }
            return resp[1];
        }
    }
}
'@

$RazerVid = 0x1532
$GoliathusPid = 0x0C02          # Razer Goliathus Extended Chroma
$RazerTransactionId = 0x3F
# Resend the color regularly - in case the mat was unplugged/replugged or
# shows its built-in rainbow effect again after standby.
$RefreshSeconds = 30

$script:MatPath = $null
$script:LastSent = [datetime]::MinValue

function Set-MousematColor([byte[]]$rgb) {
    if (-not $script:MatPath) {
        $script:MatPath = [RazerHid]::FindControlPath($RazerVid, $GoliathusPid)
        if (-not $script:MatPath) {
            throw "Razer Goliathus Extended Chroma not found. Is the mousemat connected via USB?"
        }
        Write-Log "Mousemat found: $($script:MatPath)"
    }
    try {
        $status = [RazerHid]::SetStatic($script:MatPath, $RazerTransactionId, $rgb[0], $rgb[1], $rgb[2])
    } catch {
        $script:MatPath = $null   # search again next time (e.g. replugged)
        throw
    }
    if ($status -ne 0x02) {
        throw ("The mousemat rejected the command (status 0x{0:X2})." -f $status)
    }
    $script:LastSent = Get-Date
}

# ---------------------------------------------------------------------------
# Tray icon (create the icons only once - otherwise GDI handles run out)
# ---------------------------------------------------------------------------
function New-DotIcon([System.Drawing.Color]$color) {
    $bmp = New-Object System.Drawing.Bitmap 16,16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $color
    $g.FillEllipse($brush, 1, 1, 14, 14)
    $g.DrawEllipse([System.Drawing.Pens]::DimGray, 1, 1, 14, 14)
    $brush.Dispose()
    $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $icon
}

$Icons = @{
    busy    = New-DotIcon ([System.Drawing.Color]::Red)
    default = New-DotIcon ([System.Drawing.Color]::White)
    error   = New-DotIcon ([System.Drawing.Color]::Gray)
}

# NotifyIcon.Text is limited to 63 characters.
function Set-TrayText([string]$text) {
    if ($text.Length -gt 63) { $text = $text.Substring(0, 60) + '...' }
    $notifyIcon.Text = $text
}

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = $Icons.error
$notifyIcon.Text = "Teams Presence Chroma - starting..."
$notifyIcon.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$statusItem = $menu.Items.Add("Status: unknown")
$statusItem.Enabled = $false
$menu.Items.Add("-") | Out-Null
$refreshItem = $menu.Items.Add("Refresh now")
$diagItem = $menu.Items.Add("Show diagnostics")
$logItem = $menu.Items.Add("Open log file")
$menu.Items.Add("-") | Out-Null
$exitItem = $menu.Items.Add("Exit")
$notifyIcon.ContextMenuStrip = $menu

$script:LastColorKey = $null
$script:Updating = $false

function Update-Status {
    if ($script:Updating) { return }
    $script:Updating = $true
    try {
        $availability = Get-TeamsAvailability

        if ($BusyStates -contains $availability.Normalized) {
            $targetColor = $ColorBusy
            $colorKey = 'busy'
        } else {
            $targetColor = $ColorDefault
            $colorKey = 'default'
        }

        if ($colorKey -ne $script:LastColorKey) {
            Set-MousematColor $targetColor
            Write-Log "Status: $($availability.Raw) -> $colorKey"
            $script:LastColorKey = $colorKey
        } elseif (((Get-Date) - $script:LastSent).TotalSeconds -ge $RefreshSeconds) {
            Set-MousematColor $targetColor
        }

        $script:LastErrorMessage = $null
        $notifyIcon.Icon = $Icons[$colorKey]
        Set-TrayText "Teams: $($availability.Raw)"
        $statusItem.Text = "Status: $($availability.Raw)"
    } catch {
        Write-ErrorOnce "Error while updating: $_"
        # Status unknown -> don't stay red by mistake.
        if ($script:LastColorKey -eq 'busy') {
            try { Set-MousematColor $ColorDefault } catch {}
        }
        $script:LastColorKey = $null
        Set-TrayText "Teams Presence Chroma - error, see diagnostics"
        $statusItem.Text = "Error: $_"
        $notifyIcon.Icon = $Icons.error
    } finally {
        $script:Updating = $false
    }
}

$refreshItem.Add_Click({ Update-Status })
$diagItem.Add_Click({ Show-Diagnostics })
$logItem.Add_Click({ if (Test-Path $LogPath) { Start-Process notepad.exe -ArgumentList "`"$LogPath`"" } })
$exitItem.Add_Click({
    $timer.Stop()
    $notifyIcon.Visible = $false
    # Reset to the default color on exit so the mat doesn't stay red.
    try { Set-MousematColor $ColorDefault } catch {}
    Write-Log "Exited."
    [System.Windows.Forms.Application]::Exit()
})

# ---------------------------------------------------------------------------
# Main loop via a WinForms timer (keeps the tray icon responsive)
# ---------------------------------------------------------------------------
Write-Log "Started (interval: $PollSeconds s)."
if (Get-Process -Name 'RazerAppEngine' -ErrorAction SilentlyContinue) {
    Write-Log "Note: Razer Synapse is running and may overwrite the mousemat lighting."
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $PollSeconds * 1000
$timer.Add_Tick({ Update-Status })
$timer.Start()

$script:Started = $true
Update-Status

[System.Windows.Forms.Application]::Run()

$notifyIcon.Dispose()
$script:Mutex.ReleaseMutex()
