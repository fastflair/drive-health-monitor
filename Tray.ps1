<#
.SYNOPSIS
    System tray icon for Drive Health Monitor.
    Green = healthy, amber = warning, red = critical, gray = no recent check.
    Left-click opens the dashboard; right-click shows each drive's status and actions.
    Reads data\status.json, which DriveHealth.ps1 writes after every check.
    Runs as a normal (non-admin) user process, started from the Startup folder.
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$Root       = $PSScriptRoot
$StatusPath = Join-Path $Root 'data\status.json'
$Dashboard  = Join-Path $Root 'dashboard.html'
$CheckNow   = Join-Path $Root 'CheckNow.cmd'
$StaleHours = 13          # scheduled check runs every 6 h; older than this means it isn't running

# Single instance
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\DriveHealthMonitorTray', [ref]$createdNew)
if (-not $createdNew) { return }

$Deg = [char]0x00B0
$Labels = @{ ok = 'Healthy'; warning = 'WARNING'; critical = 'CRITICAL'; unknown = 'Unknown' }

# ------------------------------------------------------------------ icons
function New-StatusIcon([string]$hex) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    # drive body (rounded rectangle)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $x = 1; $y = 7; $w = 27; $h = 18; $r = 8
    $path.AddArc($x, $y, $r, $r, 180, 90)
    $path.AddArc($x + $w - $r, $y, $r, $r, 270, 90)
    $path.AddArc($x + $w - $r, $y + $h - $r, $r, $r, 0, 90)
    $path.AddArc($x, $y + $h - $r, $r, $r, 90, 90)
    $path.CloseFigure()
    $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#454B55'))), $path)
    $g.DrawPath((New-Object System.Drawing.Pen ([System.Drawing.ColorTranslator]::FromHtml('#D5D9DF')), 1.5), $path)
    # slot
    $g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#AEB4BD'))), 5, 18, 10, 3)

    # status dot
    $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($hex))), 16, 14, 16, 16)
    $g.DrawEllipse((New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 2), 17, 15, 14, 14)
    $g.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$Icons = @{
    ok       = New-StatusIcon '#2E9E5B'
    warning  = New-StatusIcon '#E8A400'
    critical = New-StatusIcon '#D93A3A'
    unknown  = New-StatusIcon '#8A8F98'
}

# ------------------------------------------------------------------ tray objects
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $Icons.unknown
$tray.Text = 'Drive Health: loading...'
$tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$tray.ContextMenuStrip = $menu

function Open-Dashboard {
    if (Test-Path $Dashboard) { Start-Process $Dashboard }
    else { [System.Windows.Forms.MessageBox]::Show('No dashboard yet - run a check first.', 'Drive Health') | Out-Null }
}

function Format-Ago([datetime]$t) {
    $m = ((Get-Date) - $t).TotalMinutes
    if ($m -lt 1) { return 'just now' }
    if ($m -lt 60) { return '{0:N0} min ago' -f $m }
    if ($m -lt 1440) { return '{0:N0} h ago' -f ($m / 60) }
    return '{0:N0} days ago' -f ($m / 1440)
}

$script:lastWrite = [datetime]::MinValue
$script:status = $null
$script:prevOverall = $null

function Add-MenuItem([string]$text, [scriptblock]$onClick, [bool]$bold = $false, [bool]$enabled = $true) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $text
    if ($bold) { $item.Font = New-Object System.Drawing.Font($item.Font, [System.Drawing.FontStyle]::Bold) }
    $item.Enabled = $enabled
    if ($onClick) { $item.Add_Click($onClick) }
    $menu.Items.Add($item) | Out-Null
    return $item
}

function Update-Tray {
    # reload status file if it changed
    if (Test-Path $StatusPath) {
        $lw = (Get-Item $StatusPath).LastWriteTime
        if ($lw -ne $script:lastWrite) {
            try { $script:status = Get-Content $StatusPath -Raw | ConvertFrom-Json; $script:lastWrite = $lw } catch {}
        }
    }
    $s = $script:status
    $overall = 'unknown'; $ago = 'never'; $stale = $true
    if ($s) {
        $gen = [datetime]$s.generated
        $ago = Format-Ago $gen
        $stale = ((Get-Date) - $gen).TotalHours -gt $StaleHours
        $overall = if ($stale) { 'unknown' } else { [string]$s.overall }
    }
    $drives = if ($s) { @($s.drives) } else { @() }
    $bad = @($drives | Where-Object { $_.status -in @('warning', 'critical') })

    $tray.Icon = $Icons[$overall]
    $headline = if (-not $s) { 'no check yet' }
        elseif ($stale) { "last check $ago" }
        elseif ($overall -eq 'ok') { "all $($drives.Count) drives healthy" }
        else { "$($bad.Count) drive(s) $($Labels[$overall])" }
    $tip = "Drive Health: $headline"
    if ($s -and -not $stale) { $tip += "`nChecked $ago" }
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
    $tray.Text = $tip

    # balloon when things get worse while the tray is running
    if ($script:prevOverall -and $s -and -not $stale) {
        $rank = @{ ok = 0; unknown = 1; warning = 2; critical = 3 }
        if ($rank[$overall] -gt $rank[$script:prevOverall] -and $overall -in @('warning', 'critical')) {
            $tray.BalloonTipIcon = if ($overall -eq 'critical') { 'Error' } else { 'Warning' }
            $tray.BalloonTipTitle = "Drive health: $($Labels[$overall])"
            $first = $bad | Select-Object -First 1
            $tray.BalloonTipText = if ($first) { "$($first.name): $($first.topIssue)" } else { 'Open the dashboard for details.' }
            $tray.ShowBalloonTip(10000)
        }
    }
    $script:prevOverall = $overall

    # rebuild menu
    $menu.Items.Clear()
    $hdr = if ($s) { "Drive Health - $($Labels[$overall]) ($ago)" } else { 'Drive Health - no check yet' }
    Add-MenuItem $hdr $null $true $false | Out-Null
    if ($stale -and $s) { Add-MenuItem '  Scheduled check may not be running' $null $false $false | Out-Null }
    $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

    foreach ($d in $drives) {
        $letters = (@($d.letters) | ForEach-Object { "${_}:" }) -join ' '
        if (-not $letters) { $letters = '--' }
        $label = if ($d.label) { " $($d.label)" } else { '' }
        $extra = @()
        if ($null -ne $d.tempC -and $d.tempC -gt 0) { $extra += "$($d.tempC)${Deg}C" }
        if ($null -ne $d.lifeLeftPct) { $extra += "$($d.lifeLeftPct)% life" }
        $text = "$letters$label  -  $($d.name)  -  $($Labels[$d.status])"
        if ($extra) { $text += "  ($($extra -join ', '))" }
        $item = Add-MenuItem $text { Open-Dashboard } $false $true
        $item.Image = $Icons[[string]$d.status].ToBitmap()
        if ($d.topIssue) { $item.ToolTipText = [string]$d.topIssue }
    }
    if ($drives.Count) { $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null }

    Add-MenuItem 'Open dashboard' { Open-Dashboard } $true | Out-Null
    Add-MenuItem 'Check drives now' {
        Start-Process -FilePath $CheckNow -WindowStyle Hidden
        $tray.BalloonTipIcon = 'Info'; $tray.BalloonTipTitle = 'Drive Health'
        $tray.BalloonTipText = 'Checking drives... the dashboard will open when done.'
        $tray.ShowBalloonTip(4000)
    } | Out-Null
    Add-MenuItem 'Open folder' { Start-Process explorer.exe "`"$Root`"" } | Out-Null
    $menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    Add-MenuItem 'Exit tray icon' {
        $timer.Stop(); $tray.Visible = $false; $tray.Dispose()
        [System.Windows.Forms.Application]::Exit()
    } | Out-Null
}

$tray.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Open-Dashboard }
})
$tray.Add_BalloonTipClicked({ Open-Dashboard })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 30000
$timer.Add_Tick({ try { Update-Tray } catch {} })

Update-Tray
$timer.Start()
[System.Windows.Forms.Application]::Run()

$tray.Visible = $false
$mutex.ReleaseMutex()
