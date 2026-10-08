# =====================================================================================
#  Install-Autostart.ps1
#
#  Creates a shortcut in the Windows startup folder so that
#  TeamsPresenceChroma.ps1 starts automatically (invisibly, without a console
#  window) in the background at every sign-in.
#
#  Just run it once:  right-click -> "Run with PowerShell"
#  No administrator rights needed.
#
#  To remove it again:  .\Install-Autostart.ps1 -Uninstall
#  (does NOT stop an instance that is already running - use "Exit" in the
#  tray icon menu for that)
# =====================================================================================

param(
    # Start immediately without asking (e.g. for automated setup)
    [switch]$StartNow,
    # Remove the autostart shortcut again
    [switch]$Uninstall
)

$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$TargetPs1    = Join-Path $ScriptDir 'TeamsPresenceChroma.ps1'
$StartupDir   = [Environment]::GetFolderPath('Startup')
$ShortcutPath = Join-Path $StartupDir 'TeamsPresenceChroma.lnk'

if ($Uninstall) {
    if (Test-Path $ShortcutPath) {
        Remove-Item $ShortcutPath -Force
        Write-Host "Autostart shortcut removed: $ShortcutPath"
    } else {
        Write-Host "No autostart shortcut found (already removed?)."
    }
    exit 0
}

if (-not (Test-Path $TargetPs1)) {
    Write-Host "Error: TeamsPresenceChroma.ps1 was not found in the same folder." -ForegroundColor Red
    exit 1
}

# "conhost --headless" starts PowerShell without any console window. With
# "-WindowStyle Hidden" alone, a window briefly flashes up at sign-in.
$Launcher   = Join-Path $env:WINDIR 'System32\conhost.exe'
$LaunchArgs = "--headless powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$TargetPs1`""

$wsh = New-Object -ComObject WScript.Shell
$shortcut = $wsh.CreateShortcut($ShortcutPath)
$shortcut.TargetPath = $Launcher
$shortcut.Arguments  = $LaunchArgs
$shortcut.WorkingDirectory = $ScriptDir
$shortcut.WindowStyle = 7   # minimized
$shortcut.Description = "Teams Presence -> Razer Chroma Mousemat"
$shortcut.Save()

Write-Host "Autostart set up: $ShortcutPath"
Write-Host "From the next sign-in on, the script starts automatically in the background."
if (-not $StartNow) {
    Write-Host "Start it now to test? (y/n)" -NoNewline
    $StartNow = (Read-Host " ") -eq 'y'
}
if ($StartNow) {
    Start-Process $Launcher -ArgumentList $LaunchArgs
}
