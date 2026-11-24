<#
.SYNOPSIS
    Installs the Drive Health Monitor:
      - optionally installs smartmontools (smartctl) via winget
      - registers a scheduled task that runs elevated at logon and every 6 hours
      - adds Start menu shortcuts ("Drive Health Dashboard", "Check Drives Now")
      - runs a first check and opens the dashboard
    Re-running it is safe; it updates the existing task.
#>
param([switch]$SkipSmartmontools)

$ErrorActionPreference = 'Stop'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host 'Requesting administrator rights - look for the Windows UAC prompt (it may be behind other windows on the taskbar)...' -ForegroundColor Yellow
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($SkipSmartmontools) { $argList += ' -SkipSmartmontools' }
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -ErrorAction Stop
        Write-Host 'Setup continues in the new administrator window.' -ForegroundColor Green
    } catch {
        Write-Host "Administrator rights were not granted, so nothing was installed. ($($_.Exception.Message))" -ForegroundColor Red
        Write-Host 'Run this again and click Yes on the UAC prompt, or right-click Install.ps1 > Run as administrator.'
    }
    return
}

$Root     = $PSScriptRoot
New-Item -ItemType Directory -Force -Path (Join-Path $Root 'data') | Out-Null
Start-Transcript -Path (Join-Path $Root 'data\install.log') -Force | Out-Null
trap {
    Write-Host "`nSETUP FAILED: $_" -ForegroundColor Red
    Write-Host "Details saved to $(Join-Path $Root 'data\install.log')"
    Stop-Transcript | Out-Null
    Read-Host 'Press Enter to close'
    exit 1
}
$Script   = Join-Path $Root 'DriveHealth.ps1'
$TaskName = 'Drive Health Monitor'
$User     = "$env:USERDOMAIN\$env:USERNAME"

Write-Host "`n=== Drive Health Monitor setup ===`n" -ForegroundColor Cyan

# Files downloaded from the internet are marked as blocked; clear that so the task and tray can run them
Get-ChildItem -Path $Root -File | Unblock-File -ErrorAction SilentlyContinue

# 1. smartmontools
$smartctl = "$env:ProgramFiles\smartmontools\bin\smartctl.exe"
if (-not (Test-Path $smartctl) -and -not $SkipSmartmontools) {
    Write-Host 'smartmontools (free, open-source SMART tool) is not installed.'
    Write-Host 'Without it only Windows'' basic health status is checked; with it you get'
    Write-Host 'reallocated/pending sector counts, self-test results and NVMe health logs.'
    $ans = Read-Host 'Install smartmontools now with winget? [Y/n]'
    if ($ans -notmatch '^[nN]') {
        & winget install --id smartmontools.smartmontools -e --source winget --accept-package-agreements --accept-source-agreements
        if (Test-Path $smartctl) { Write-Host 'smartmontools installed.' -ForegroundColor Green }
        else { Write-Host 'smartmontools did not install; continuing with Windows-only checks.' -ForegroundColor Yellow }
    }
} elseif (Test-Path $smartctl) {
    Write-Host "smartmontools found: $smartctl" -ForegroundColor Green
}

# 2. scheduled task
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script`"" `
    -WorkingDirectory $Root
$tLogon = New-ScheduledTaskTrigger -AtLogOn -User $User
$tLogon.Delay = 'PT1M'    # give the desktop a minute to settle
$tRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddHours((Get-Date).Hour + 1) `
    -RepetitionInterval (New-TimeSpan -Hours 6)
$principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($tLogon, $tRepeat) -Principal $principal `
    -Settings $settings -Description 'Checks SMART health of all drives and alerts on early signs of failure.' -Force | Out-Null
Write-Host "Scheduled task '$TaskName' registered (at logon + every 6 hours, elevated)." -ForegroundColor Green

# 3. Start menu shortcuts
$menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Drive Health Monitor'
New-Item -ItemType Directory -Force -Path $menu | Out-Null
$ws = New-Object -ComObject WScript.Shell
$s1 = $ws.CreateShortcut((Join-Path $menu 'Drive Health Dashboard.lnk'))
$s1.TargetPath = Join-Path $Root 'dashboard.html'
$s1.IconLocation = "$env:WINDIR\System32\imageres.dll,30"
$s1.Save()
$s2 = $ws.CreateShortcut((Join-Path $menu 'Check Drives Now.lnk'))
$s2.TargetPath = Join-Path $Root 'CheckNow.cmd'
$s2.WorkingDirectory = $Root
$s2.WindowStyle = 7
$s2.IconLocation = "$env:WINDIR\System32\imageres.dll,30"
$s2.Save()
Write-Host "Start menu shortcuts added: $menu" -ForegroundColor Green

# 3b. tray icon, started at logon from the Startup folder (runs as a normal user, not elevated)
$trayLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Drive Health Tray.lnk'
$s3 = $ws.CreateShortcut($trayLnk)
$s3.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$s3.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$(Join-Path $Root 'Tray.ps1')`""
$s3.WorkingDirectory = $Root
$s3.WindowStyle = 7
$s3.IconLocation = "$env:WINDIR\System32\imageres.dll,30"
$s3.Description = 'Drive Health Monitor tray icon'
$s3.Save()
Copy-Item $trayLnk (Join-Path $menu 'Drive Health Tray Icon.lnk') -Force
Write-Host 'Tray icon added to Startup.' -ForegroundColor Green

# 4. first run
Write-Host "`nRunning the first check..."
& $Script -Show
# explorer.exe launches the tray as the normal (non-elevated) user
Start-Process -FilePath "$env:WINDIR\explorer.exe" -ArgumentList "`"$trayLnk`""
Write-Host "`nDone. Dashboard: $(Join-Path $Root 'dashboard.html')" -ForegroundColor Cyan
Stop-Transcript | Out-Null
Read-Host 'Press Enter to close'
