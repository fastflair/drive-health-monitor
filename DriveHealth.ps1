<#
.SYNOPSIS
    Drive Health Monitor - reads SMART data from every drive, flags early signs of
    failure, writes an HTML dashboard and pops up a Windows notification on problems.

.DESCRIPTION
    Data sources (best available is used):
      1. smartctl (smartmontools)   - full SMART attributes, NVMe health log, self-test log
      2. Windows storage counters   - Get-PhysicalDisk health + Get-StorageReliabilityCounter
      3. Windows System event log   - bad block / controller / paging / NTFS corruption events
    Needs to run elevated (admin) to read SMART data. Install.ps1 registers a scheduled
    task that does this at logon and every 6 hours without a UAC prompt.

.PARAMETER Show
    Always open the dashboard, even when every drive is healthy.
.PARAMETER NotifyWhenHealthy
    Show a notification even when every drive is healthy.
.PARAMETER NoNotify
    Never show notifications or open the dashboard (just update files).
#>
[CmdletBinding()]
param(
    [switch]$Show,
    [switch]$NotifyWhenHealthy,
    [switch]$NoNotify,
    [int]$EventLogDays = 7
)

$ErrorActionPreference = 'Continue'
$Root          = $PSScriptRoot
$DataDir       = Join-Path $Root 'data'
$DashboardPath = Join-Path $Root 'dashboard.html'
$TemplatePath  = Join-Path $Root 'dashboard-template.html'
$HistoryPath   = Join-Path $DataDir 'history.json'
$LogPath       = Join-Path $DataDir 'monitor.log'
$ShowFlag      = Join-Path $DataDir 'show.flag'
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# ---------------------------------------------------------------- thresholds
$T = @{
    TempHDD      = @(50, 60)    # warn, critical (Celsius)
    TempSATASSD  = @(65, 75)
    TempNVMe     = @(70, 80)
    LifeLeftWarn = 20           # % SSD endurance remaining
    LifeLeftCrit = 10
    ReallocCrit  = 100          # reallocated sectors -> critical
    HistoryKeep  = 500          # snapshots kept (~4 months at 4/day)
}

# Counters compared run-to-run. Any increase raises a warning.
$TrendLabels = [ordered]@{
    reallocated          = 'Reallocated sectors'
    pending              = 'Pending (unreadable) sectors'
    offlineUncorrectable = 'Offline uncorrectable sectors'
    reportedUncorrect    = 'Reported uncorrectable errors'
    endToEnd             = 'End-to-end errors'
    crcErrors            = 'Interface CRC errors'
    mediaErrors          = 'NVMe media/data-integrity errors'
    errorLogCount        = 'Drive error log entries'
    readErrorsUncorrected= 'Uncorrected read errors'
}

function Write-Log([string]$msg) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
    Write-Verbose $line
}

# Trim the log so it never grows unbounded
if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 1MB) {
    $keep = Get-Content $LogPath -Tail 2000
    Set-Content -Path $LogPath -Value $keep -Encoding UTF8
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Log "---- run start (admin=$isAdmin)"

$LevelRank = @{ ok = 0; unknown = 1; warning = 2; critical = 3 }

function Add-Issue($drive, [string]$level, [string]$key, [string]$text) {
    $drive.issues.Add([ordered]@{ level = $level; key = $key; text = $text }) | Out-Null
    if ($level -ne 'info' -and $LevelRank[$level] -gt $LevelRank[$drive.status]) { $drive.status = $level }
}

function Normalize-Serial([string]$s) {
    if (-not $s) { return '' }
    return ($s -replace '[^A-Za-z0-9]', '').ToUpperInvariant()
}

function Get-Prop($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    $p = $obj.PSObject.Properties[$name]
    if ($p) { return $p.Value } else { return $null }
}

# ---------------------------------------------------------------- Windows disk inventory
$drives = New-Object System.Collections.Generic.List[object]
$pdisks = @(Get-PhysicalDisk | Sort-Object { [int]$_.DeviceId })

foreach ($pd in $pdisks) {
    $d = [ordered]@{
        key          = ''
        diskNumber   = [string]$pd.DeviceId
        name         = $pd.FriendlyName
        model        = $pd.Model
        serial       = ([string]$pd.SerialNumber).Trim()
        firmware     = $pd.FirmwareVersion
        bus          = [string]$pd.BusType
        media        = [string]$pd.MediaType
        sizeBytes    = [int64]$pd.Size
        winHealth    = [string]$pd.HealthStatus
        winOperational = ($pd.OperationalStatus -join ', ')
        source       = 'Windows'
        smartPassed  = $null
        status       = 'ok'
        issues       = New-Object System.Collections.Generic.List[object]
        tempC        = $null
        powerOnHours = $null
        lifeLeftPct  = $null
        tbWritten    = $null
        counters     = [ordered]@{}
        attributes   = @()
        nvme         = $null
        selfTest     = $null
        events       = @()
        trend        = @()
        winCounters  = $null
        smartDevice  = $null
        firstSeen    = $null
        history      = @()
        volumes      = @()
    }
    # Drive letters / volumes on this disk
    try {
        $d.volumes = @(Get-Partition -DiskNumber $pd.DeviceId -ErrorAction Stop | Where-Object { $_.DriveLetter } | Sort-Object DriveLetter | ForEach-Object {
            $v = Get-Volume -Partition $_ -ErrorAction SilentlyContinue
            [ordered]@{
                letter    = [string]$_.DriveLetter
                label     = if ($v) { [string]$v.FileSystemLabel } else { '' }
                sizeBytes = if ($v) { [int64]$v.Size } else { [int64]$_.Size }
                freeBytes = if ($v) { [int64]$v.SizeRemaining } else { $null }
            }
        })
    } catch {}
    $d.key = if ($d.serial) { Normalize-Serial $d.serial } else { "DISK$($d.diskNumber)" }

    switch ($d.winHealth) {
        'Warning'   { Add-Issue $d 'warning'  'win-health' 'Windows reports this drive''s health as WARNING.' }
        'Unhealthy' { Add-Issue $d 'critical' 'win-health' 'Windows reports this drive as UNHEALTHY. Back it up immediately.' }
    }
    if ($d.winOperational -and $d.winOperational -notmatch '^OK') {
        Add-Issue $d 'warning' 'win-opstatus' "Windows operational status: $($d.winOperational)."
    }

    # Windows reliability counters (admin only)
    if ($isAdmin) {
        try {
            $rc = $pd | Get-StorageReliabilityCounter -ErrorAction Stop
            $d.winCounters = [ordered]@{
                Temperature           = $rc.Temperature
                TemperatureMax        = $rc.TemperatureMax
                Wear                  = $rc.Wear
                PowerOnHours          = $rc.PowerOnHours
                ReadErrorsUncorrected = $rc.ReadErrorsUncorrected
                ReadErrorsCorrected   = $rc.ReadErrorsCorrected
                WriteErrorsUncorrected= $rc.WriteErrorsUncorrected
                StartStopCycleCount   = $rc.StartStopCycleCount
            }
        } catch { $d.winCounters = $null }
    }
    $drives.Add($d) | Out-Null
}

# ---------------------------------------------------------------- smartctl
$smartctl = $null
$cands = @(
    (Get-Command smartctl.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source),
    "$env:ProgramFiles\smartmontools\bin\smartctl.exe",
    "${env:ProgramFiles(x86)}\smartmontools\bin\smartctl.exe"
)
foreach ($c in $cands) { if ($c -and (Test-Path $c)) { $smartctl = $c; break } }

$smartMode = 'none'
if ($smartctl -and $isAdmin) {
    $smartMode = 'smartctl'
    Write-Log "Using smartctl: $smartctl"
    $scan = $null
    try { $scan = (& $smartctl --scan-open -j 2>$null | Out-String) | ConvertFrom-Json } catch {}
    $devs = @()
    if ($scan) { $devs = @($scan.devices) }

    foreach ($dev in $devs) {
        $j = $null
        try {
            $j = (& $smartctl -a -j -d $dev.type $dev.name 2>$null | Out-String) | ConvertFrom-Json
        } catch { Write-Log "smartctl failed on $($dev.name): $_"; continue }
        if (-not $j) { continue }

        $serial = Get-Prop $j 'serial_number'
        $nser   = Normalize-Serial $serial

        # Match to a Windows disk: by serial, else /dev/sdX -> PhysicalDriveN
        $d = $null
        if ($nser) {
            # already handled under another device name (smartctl can list a drive twice)
            if ($drives | Where-Object { $_.source -eq 'smartctl' -and (Normalize-Serial $_.serial) -eq $nser }) { continue }
            $d = $drives | Where-Object { $_.key -eq $nser } | Select-Object -First 1
            if (-not $d) {
                $d = $drives | Where-Object { $_.key -and $nser -and ($_.key.Contains($nser) -or $nser.Contains($_.key)) } | Select-Object -First 1
            }
        }
        if (-not $d -and $dev.name -match '^/dev/sd([a-z]+)$') {
            $letters = $Matches[1]; $n = 0
            foreach ($ch in $letters.ToCharArray()) { $n = $n * 26 + ([int]$ch - 96) }
            $num = [string]($n - 1)
            $d = $drives | Where-Object { $_.diskNumber -eq $num } | Select-Object -First 1
        }
        if (-not $d) {
            Write-Log "smartctl device $($dev.name) ($serial) did not match a Windows disk; skipping"
            continue
        }
        if ($d.source -eq 'smartctl') { continue }   # same disk reported twice

        $smartSupport = Get-Prop $j 'smart_support'
        $ss = Get-Prop $j 'smart_status'
        $protocol = Get-Prop (Get-Prop $j 'device') 'protocol'
        if (-not $ss -and -not (Get-Prop $j 'ata_smart_attributes') -and -not (Get-Prop $j 'nvme_smart_health_information_log')) {
            continue   # no SMART data (card readers, some USB bridges)
        }
        $d.source = 'smartctl'
        if ($serial) { $d.serial = $serial }
        $fw = Get-Prop $j 'firmware_version'; if ($fw) { $d.firmware = $fw }
        $mn = Get-Prop $j 'model_name';       if ($mn) { $d.model = $mn }
        $d.smartDevice = "$($dev.name) ($($dev.type))"

        if ($ss) {
            $d.smartPassed = [bool]$ss.passed
            if (-not $ss.passed) {
                Add-Issue $d 'critical' 'smart-failed' 'Drive''s own SMART self-assessment: FAILED. The drive predicts its own failure - back it up now and replace it.'
            }
        }
        $temp = Get-Prop (Get-Prop $j 'temperature') 'current'
        if ($null -ne $temp) { $d.tempC = [int]$temp }
        $poh = Get-Prop (Get-Prop $j 'power_on_time') 'hours'
        if ($null -ne $poh) { $d.powerOnHours = [int64]$poh }

        # ---------- ATA / SATA ----------
        $ata = Get-Prop $j 'ata_smart_attributes'
        if ($ata) {
            $attrs = @()
            foreach ($a in @($ata.table)) {
                $raw = [int64](Get-Prop $a.raw 'value')
                $wf  = [string](Get-Prop $a 'when_failed')
                $attrs += [ordered]@{
                    id = $a.id; name = $a.name; value = $a.value; worst = $a.worst; thresh = $a.thresh
                    raw = [string]$a.raw.string; failed = $wf
                }
                if ($wf -eq 'now') {
                    Add-Issue $d 'critical' "attr-fail-$($a.id)" "SMART attribute $($a.id) $($a.name) is below the manufacturer's failure threshold (value $($a.value), threshold $($a.thresh))."
                } elseif ($wf -eq 'past') {
                    Add-Issue $d 'warning' "attr-past-$($a.id)" "SMART attribute $($a.id) $($a.name) has dropped below its failure threshold at some point in the past."
                }

                $low = $raw -band 0xFFFFFFFF
                switch ([int]$a.id) {
                    5   { $d.counters.reallocated = $low }
                    196 { $d.counters.reallocEvents = $low }
                    197 { $d.counters.pending = $low }
                    198 { $d.counters.offlineUncorrectable = $low }
                    187 { $d.counters.reportedUncorrect = $low }
                    10  { $d.counters.spinRetry = $low }
                    184 { $d.counters.endToEnd = $low }
                    199 { $d.counters.crcErrors = $low }
                }
                if ($a.name -match 'Wear_Leveling_Count|SSD_Life_Left|Media_Wearout_Indicator|Percent_Lifetime_Remain|Remaining_Lifetime_Perc') {
                    if ($null -eq $d.lifeLeftPct) { $d.lifeLeftPct = [math]::Min(100, [int]$a.value) }
                }
                if ($a.name -eq 'Total_LBAs_Written') {
                    $d.tbWritten = [math]::Round($raw * 512 / 1e12, 2)
                }
            }
            $d.attributes = $attrs

            $c = $d.counters
            if ($c.Contains('reallocated') -and $c.reallocated -gt 0) {
                $lvl = if ($c.reallocated -ge $T.ReallocCrit) { 'critical' } else { 'warning' }
                Add-Issue $d $lvl 'realloc' "$($c.reallocated) reallocated sectors - the drive has already replaced bad sectors with spares. A strong early sign of wear or failure; keep backups current."
            }
            if ($c.Contains('pending') -and $c.pending -gt 0) {
                Add-Issue $d 'critical' 'pending' "$($c.pending) pending sectors - areas the drive currently cannot read reliably. One of the strongest predictors of failure. Back up now."
            }
            if ($c.Contains('offlineUncorrectable') -and $c.offlineUncorrectable -gt 0) {
                Add-Issue $d 'critical' 'offline-unc' "$($c.offlineUncorrectable) offline uncorrectable sectors - data that could not be recovered. Back up and plan replacement."
            }
            if ($c.Contains('reportedUncorrect') -and $c.reportedUncorrect -gt 0) {
                Add-Issue $d 'warning' 'reported-unc' "$($c.reportedUncorrect) reported uncorrectable errors - reads that failed even after error correction."
            }
            if ($c.Contains('spinRetry') -and $c.spinRetry -gt 0) {
                Add-Issue $d 'warning' 'spin-retry' "$($c.spinRetry) spin-up retries - the motor struggled to start. Often a mechanical or power issue."
            }
            if ($c.Contains('endToEnd') -and $c.endToEnd -gt 0) {
                Add-Issue $d 'critical' 'end-to-end' "$($c.endToEnd) end-to-end errors - data was corrupted inside the drive's own buffer/cache."
            }
            if ($c.Contains('crcErrors') -and $c.crcErrors -gt 0) {
                Add-Issue $d 'info' 'crc' "$($c.crcErrors) interface CRC errors (lifetime). Usually a cable/port problem, not the disk itself; only a concern if it keeps rising."
            }

            # Most recent self-test
            $st = Get-Prop (Get-Prop (Get-Prop $j 'ata_smart_self_test_log') 'standard') 'table'
            if ($st) {
                $last = @($st)[0]
                $d.selfTest = [ordered]@{ type = $last.type.string; status = $last.status.string; hours = $last.lifetime_hours }
                $passed = Get-Prop $last.status 'passed'
                if ($null -ne $passed -and -not $passed) {
                    Add-Issue $d 'critical' 'selftest' "Most recent SMART self-test FAILED: $($last.status.string)"
                }
            }
            $elc = Get-Prop (Get-Prop (Get-Prop $j 'ata_smart_error_log') 'summary') 'count'
            if ($null -ne $elc) { $d.counters.errorLogCount = [int64]$elc }
        }

        # ---------- NVMe ----------
        $nv = Get-Prop $j 'nvme_smart_health_information_log'
        if ($nv) {
            $d.nvme = $nv
            if ($null -eq $d.tempC -and $null -ne $nv.temperature) { $d.tempC = [int]$nv.temperature }
            if ($null -eq $d.powerOnHours) { $d.powerOnHours = [int64]$nv.power_on_hours }
            $d.lifeLeftPct = [math]::Max(0, 100 - [int]$nv.percentage_used)
            $d.tbWritten = [math]::Round([double]$nv.data_units_written * 512000 / 1e12, 2)
            $d.counters.mediaErrors = [int64]$nv.media_errors
            $d.counters.nvmeErrorLog = [int64]$nv.num_err_log_entries
            $d.counters.unsafeShutdowns = [int64]$nv.unsafe_shutdowns

            $cw = [int]$nv.critical_warning
            if ($cw -ne 0) {
                $why = @()
                if ($cw -band 1)  { $why += 'spare capacity below threshold' }
                if ($cw -band 2)  { $why += 'temperature out of range' }
                if ($cw -band 4)  { $why += 'reliability degraded by media/internal errors' }
                if ($cw -band 8)  { $why += 'drive has gone READ-ONLY' }
                if ($cw -band 16) { $why += 'volatile memory backup failed' }
                Add-Issue $d 'critical' 'nvme-critical' ("NVMe critical warning raised: " + ($why -join '; ') + '.')
            }
            if ([int]$nv.available_spare -le [int]$nv.available_spare_threshold) {
                Add-Issue $d 'critical' 'nvme-spare' "Spare blocks at $($nv.available_spare)% - at or below the drive's $($nv.available_spare_threshold)% failure threshold."
            } elseif ([int]$nv.available_spare -lt 50) {
                Add-Issue $d 'warning' 'nvme-spare' "Spare blocks down to $($nv.available_spare)%."
            }
            if ([int64]$nv.media_errors -gt 0) {
                Add-Issue $d 'critical' 'nvme-media' "$($nv.media_errors) media/data-integrity errors - data the SSD could not read back correctly."
            }
        }
    }
} elseif (-not $isAdmin) {
    $smartMode = 'limited'
} else {
    $smartMode = 'windows'
}

# ---------------------------------------------------------------- Windows fallback + shared checks
foreach ($d in $drives) {
    if ($d.winCounters) {
        $wc = $d.winCounters
        if ($null -eq $d.tempC -and $wc.Temperature) { $d.tempC = [int]$wc.Temperature }
        if ($null -eq $d.powerOnHours -and $wc.PowerOnHours) { $d.powerOnHours = [int64]$wc.PowerOnHours }
        if ($null -eq $d.lifeLeftPct -and $d.media -eq 'SSD' -and $null -ne $wc.Wear) { $d.lifeLeftPct = [math]::Max(0, 100 - [int]$wc.Wear) }
        if ($d.source -ne 'smartctl' -and $wc.ReadErrorsUncorrected -gt 0) {
            $d.counters.readErrorsUncorrected = [int64]$wc.ReadErrorsUncorrected
            Add-Issue $d 'warning' 'win-read-unc' "$($wc.ReadErrorsUncorrected) uncorrected read errors reported by Windows."
        }
    }

    # Temperature
    if ($null -ne $d.tempC -and $d.tempC -gt 0) {
        $lim = if ($d.bus -eq 'NVMe') { $T.TempNVMe } elseif ($d.media -eq 'SSD') { $T.TempSATASSD } else { $T.TempHDD }
        if ($d.tempC -ge $lim[1])     { Add-Issue $d 'critical' 'temp' "Temperature is $($d.tempC) C (critical limit $($lim[1]) C). Check cooling/airflow." }
        elseif ($d.tempC -ge $lim[0]) { Add-Issue $d 'warning'  'temp' "Temperature is $($d.tempC) C (warning limit $($lim[0]) C). Heat shortens drive life." }
    }
    # SSD endurance
    if ($null -ne $d.lifeLeftPct) {
        if ($d.lifeLeftPct -le $T.LifeLeftCrit)     { Add-Issue $d 'critical' 'life' "Only $($d.lifeLeftPct)% of rated write endurance left. Plan replacement." }
        elseif ($d.lifeLeftPct -le $T.LifeLeftWarn) { Add-Issue $d 'warning'  'life' "$($d.lifeLeftPct)% of rated write endurance left." }
    }
    # Age (hard drives' failure rates climb noticeably after ~5 years of running)
    if ($d.media -eq 'HDD' -and $d.powerOnHours -ge 43800) {
        Add-Issue $d 'info' 'age' ("Has been powered on for {0:N1} years. Hard drive failure rates rise with age - make sure this one is backed up." -f ($d.powerOnHours / 8766))
    }
    # Nothing could be read at all
    if ($d.source -eq 'Windows' -and $smartMode -eq 'smartctl' -and $d.bus -ne 'USB') {
        Add-Issue $d 'info' 'no-smart' 'smartctl could not read SMART data from this drive; only Windows health status is shown.'
    }
    if ($d.bus -eq 'USB' -and $d.source -eq 'Windows') {
        Add-Issue $d 'info' 'usb' 'USB device - SMART data is usually not available through USB readers/bridges.'
    }
}

# ---------------------------------------------------------------- System event log
$EventInfo = @{
    'disk:7'    = @('critical', 'Bad block detected')
    'disk:11'   = @('warning',  'Controller error')
    'disk:15'   = @('warning',  'Device not ready')
    'disk:51'   = @('warning',  'Error during paging operation')
    'disk:52'   = @('critical', 'Drive predicted failure (SMART)')
    'disk:153'  = @('warning',  'I/O operation retried')
    'disk:154'  = @('critical', 'Hardware error on I/O')
    'Ntfs:55'   = @('warning',  'File system corruption detected')
    'Ntfs:98'   = @('warning',  'Volume needs repair (chkdsk)')
    'stornvme:11' = @('warning', 'NVMe controller error')
    'stornvme:129'= @('warning', 'NVMe device reset')
    'storahci:129'= @('warning', 'SATA device reset')
    'storahci:11' = @('warning', 'SATA controller error')
}
$generalIssues = New-Object System.Collections.Generic.List[object]
$since = (Get-Date).AddDays(-$EventLogDays)
$allEvents = @()
foreach ($prov in @('disk', 'Ntfs', 'stornvme', 'storahci')) {
    try {
        $allEvents += @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = $prov; Level = 1, 2, 3; StartTime = $since } -ErrorAction Stop)
    } catch {}
}
$eventsByDisk = @{}
foreach ($e in $allEvents) {
    $k = "$($e.ProviderName):$($e.Id)"
    if (-not $EventInfo.ContainsKey($k)) { continue }
    $text = ([string]$e.Message) + ' ' + (($e.Properties | ForEach-Object { [string]$_.Value }) -join ' ')
    $disk = $null
    if ($text -match '\\Device\\Harddisk(\d+)\\') { $disk = $Matches[1] }
    if ($disk -eq $null) { $disk = '?' }
    if (-not $eventsByDisk.ContainsKey($disk)) { $eventsByDisk[$disk] = @{} }
    if (-not $eventsByDisk[$disk].ContainsKey($k)) { $eventsByDisk[$disk][$k] = [ordered]@{ key = $k; label = $EventInfo[$k][1]; level = $EventInfo[$k][0]; count = 0; last = $null } }
    $entry = $eventsByDisk[$disk][$k]
    $entry.count++
    if (-not $entry.last -or $e.TimeCreated -gt [datetime]$entry.last) { $entry.last = $e.TimeCreated.ToString('s') }
}
foreach ($disk in $eventsByDisk.Keys) {
    $d = $drives | Where-Object { $_.diskNumber -eq $disk } | Select-Object -First 1
    foreach ($entry in $eventsByDisk[$disk].Values) {
        $msg = "$($entry.count) x '$($entry.label)' in the Windows System log (last $EventLogDays days, most recent $($entry.last.Replace('T',' ')))."
        if ($d -and $d.bus -ne 'USB') {
            $d.events += $entry
            Add-Issue $d $entry.level "evt-$($entry.key)" $msg
        } elseif (-not $d) {
            $generalIssues.Add([ordered]@{ level = $entry.level; key = "evt-$($entry.key)"; text = $msg }) | Out-Null
        }
    }
}

# ---------------------------------------------------------------- history / trends
$history = @()
if (Test-Path $HistoryPath) {
    try { $h = Get-Content $HistoryPath -Raw | ConvertFrom-Json; $history = @($h.snapshots) } catch { Write-Log "history unreadable: $_" }
}
$prev = if ($history.Count -gt 0) { $history[-1] } else { $null }
$prevDrives = @{}
if ($prev) { foreach ($pdx in @($prev.drives)) { $prevDrives[$pdx.key] = $pdx } }

# first-seen baseline for each drive
$firstSeen = @{}
foreach ($snap in $history) {
    foreach ($sd in @($snap.drives)) {
        if (-not $firstSeen.ContainsKey($sd.key)) { $firstSeen[$sd.key] = @{ time = $snap.time; counters = $sd.counters } }
    }
}

foreach ($d in $drives) {
    $p = $prevDrives[$d.key]
    $fs = $firstSeen[$d.key]
    $trend = @()
    foreach ($ck in $TrendLabels.Keys) {
        if (-not $d.counters.Contains($ck)) { continue }
        $cur = [int64]$d.counters[$ck]
        $pv = if ($p) { Get-Prop $p.counters $ck } else { $null }
        $bv = if ($fs) { Get-Prop $fs.counters $ck } else { $null }
        if ($null -ne $pv -and $cur -gt [int64]$pv) {
            $lvl = if ($ck -in @('pending', 'offlineUncorrectable', 'mediaErrors')) { 'critical' } else { 'warning' }
            Add-Issue $d $lvl "trend-$ck" "$($TrendLabels[$ck]) INCREASED from $pv to $cur since the last check ($(([datetime]$prev.time).ToString('g'))). A rising count means the drive is actively degrading."
        }
        if ($null -ne $bv) {
            $trend += [ordered]@{ label = $TrendLabels[$ck]; first = [int64]$bv; firstTime = $fs.time; now = $cur }
        }
    }
    $d.trend = $trend
    $d.firstSeen = if ($fs) { $fs.time } else { (Get-Date).ToString('s') }

    # ---- SSD endurance estimate (days until the rated write endurance runs out)
    $d.lifeEstimateDays = $null; $d.lifeEstimateBasis = $null
    if ($null -ne $d.lifeLeftPct -and $d.lifeLeftPct -gt 0) {
        # oldest snapshot of this drive that has both life % and power-on hours
        $old = $null; $oldTime = $null
        foreach ($snap in $history) {
            $sd = @($snap.drives) | Where-Object { $_.key -eq $d.key -and $null -ne $_.lifeLeftPct } | Select-Object -First 1
            if ($sd) { $old = $sd; $oldTime = [datetime]$snap.time; break }
        }
        $spanDays = if ($oldTime) { ((Get-Date) - $oldTime).TotalDays } else { 0 }
        $drop = if ($old) { [double]$old.lifeLeftPct - $d.lifeLeftPct } else { 0 }

        if ($spanDays -ge 14 -and $drop -ge 1) {
            # Measured: wear observed since monitoring began
            $d.lifeEstimateDays = [int]($d.lifeLeftPct / ($drop / $spanDays))
            $d.lifeEstimateBasis = "measured wear over the last $([int]$spanDays) days"
        } elseif ($d.powerOnHours -gt 0 -and $d.lifeLeftPct -lt 100) {
            # Lifetime average wear per power-on hour, scaled by how much the PC is actually on
            $used = 100 - $d.lifeLeftPct
            $remainingPoh = $d.lifeLeftPct / ($used / $d.powerOnHours)
            $duty = 1.0
            $oldPoh = if ($old) { Get-Prop $old 'powerOnHours' } else { $null }
            if ($oldPoh -and $spanDays -ge 3) {
                $duty = [math]::Min(1.0, [math]::Max(0.05, ($d.powerOnHours - [double]$oldPoh) / ($spanDays * 24)))
            }
            $d.lifeEstimateDays = [int]($remainingPoh / 24 / $duty)
            $d.lifeEstimateBasis = 'lifetime average wear rate'
        }
        if ($null -ne $d.lifeEstimateDays -and $d.lifeEstimateDays -lt 365) {
            $lvl = if ($d.lifeEstimateDays -lt 90) { 'warning' } else { 'info' }
            Add-Issue $d $lvl 'life-est' "At the current write rate, rated endurance runs out in about $($d.lifeEstimateDays) days (based on $($d.lifeEstimateBasis)). Plan a replacement."
        }
    }
}

# Drives that vanished since last check (excluding USB)
if ($prev) {
    foreach ($pdx in @($prev.drives)) {
        if ($pdx.bus -eq 'USB') { continue }
        if (-not ($drives | Where-Object { $_.key -eq $pdx.key })) {
            $generalIssues.Add([ordered]@{ level = 'warning'; key = "missing-$($pdx.key)"; text = "Drive '$($pdx.name)' (serial $($pdx.serial)) was present at the last check but is not detected now. If you didn't remove it, check cables/power - a drive that drops off the bus can be failing." }) | Out-Null
        }
    }
}

# ---------------------------------------------------------------- overall + snapshot
$overall = 'ok'
foreach ($i in @($drives | ForEach-Object { $_.status }) + @($generalIssues | ForEach-Object { $_.level })) {
    if ($LevelRank.ContainsKey($i) -and $LevelRank[$i] -gt $LevelRank[$overall]) { $overall = $i }
}
$now = (Get-Date).ToString('s')

$snapDrives = @()
foreach ($d in $drives) {
    $snapDrives += [ordered]@{
        key = $d.key; name = $d.name; serial = $d.serial; bus = $d.bus; status = $d.status
        tempC = $d.tempC; lifeLeftPct = $d.lifeLeftPct; powerOnHours = $d.powerOnHours; counters = $d.counters
        issueKeys = @($d.issues | Where-Object { $_.level -ne 'info' } | ForEach-Object { "$($d.key)|$($_.key)" })
    }
}
$snapshot = [ordered]@{ time = $now; overall = $overall; drives = $snapDrives; generalKeys = @($generalIssues | ForEach-Object { $_.key }) }

# Was there any issue that wasn't present last time?
$prevKeys = @()
if ($prev) {
    foreach ($pdx in @($prev.drives)) { $prevKeys += @($pdx.issueKeys) }
    $prevKeys += @($prev.generalKeys)
}
$curKeys = @($snapDrives | ForEach-Object { $_.issueKeys }) + @($snapshot.generalKeys)
$newKeys = @($curKeys | Where-Object { $_ -and ($prevKeys -notcontains $_) })

$history = @($history) + @([pscustomobject]$snapshot)
if ($history.Count -gt $T.HistoryKeep) { $history = $history[($history.Count - $T.HistoryKeep)..($history.Count - 1)] }
if ($smartMode -ne 'limited') {
    # don't record non-admin runs: they lack counters and would break trend comparisons
    $json = ConvertTo-Json -InputObject ([ordered]@{ snapshots = $history }) -Depth 8 -Compress
    [IO.File]::WriteAllText($HistoryPath, $json, (New-Object Text.UTF8Encoding $false))
}

# Per-drive mini history for the dashboard (last 60 checks)
$recent = @($history | Select-Object -Last 60)
foreach ($d in $drives) {
    $d.history = @($recent | ForEach-Object {
        $t = $_.time
        $m = @($_.drives) | Where-Object { $_.key -eq $d.key } | Select-Object -First 1
        if ($m) { [ordered]@{ t = $t; s = $m.status; c = $m.tempC } }
    })
}

# ---------------------------------------------------------------- dashboard
$data = [ordered]@{
    generated   = $now
    computer    = $env:COMPUTERNAME
    overall     = $overall
    mode        = $smartMode
    isAdmin     = $isAdmin
    smartctl    = $smartctl
    eventDays   = $EventLogDays
    newIssues   = $newKeys
    general     = $generalIssues
    drives      = $drives
}
$dataJson = ConvertTo-Json -InputObject $data -Depth 10 -Compress
$template = [IO.File]::ReadAllText($TemplatePath)
$html = $template.Replace('/*__DATA__*/null', $dataJson)
[IO.File]::WriteAllText($DashboardPath, $html, (New-Object Text.UTF8Encoding $false))

# Small status file for the tray icon (Tray.ps1)
$status = [ordered]@{
    generated = $now
    overall   = $overall
    mode      = $smartMode
    general   = @($generalIssues | ForEach-Object { [ordered]@{ level = $_.level; text = $_.text } })
    drives    = @($drives | Sort-Object { [int]$_.diskNumber } | ForEach-Object {
        $dd = $_
        $top = $dd.issues | Where-Object { $_.level -eq $dd.status } | Select-Object -First 1
        [ordered]@{
            letters     = @($dd.volumes | ForEach-Object { $_.letter })
            label       = (@($dd.volumes | ForEach-Object { $_.label } | Where-Object { $_ }) -join ', ')
            name        = $dd.name
            status      = $dd.status
            tempC       = $dd.tempC
            lifeLeftPct = $dd.lifeLeftPct
            topIssue    = if ($top) { $top.text } else { $null }
        }
    })
}
[IO.File]::WriteAllText((Join-Path $DataDir 'status.json'), (ConvertTo-Json -InputObject $status -Depth 5), (New-Object Text.UTF8Encoding $false))

$summary = ($drives | ForEach-Object { "$($_.name)=$($_.status)" }) -join '; '
Write-Log "overall=$overall mode=$smartMode new=$($newKeys.Count) :: $summary"

# ---------------------------------------------------------------- alerts
function Show-Toast([string]$title, [string]$body, [bool]$sticky) {
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
        $uri = [Security.SecurityElement]::Escape(([Uri]$DashboardPath).AbsoluteUri)
        $scenario = if ($sticky) { ' scenario="reminder"' } else { '' }
        $xml = @"
<toast launch="$uri" activationType="protocol"$scenario>
  <visual><binding template="ToastGeneric">
    <text>$([Security.SecurityElement]::Escape($title))</text>
    <text>$([Security.SecurityElement]::Escape($body))</text>
  </binding></visual>
  <actions>
    <action content="Open dashboard" activationType="protocol" arguments="$uri"/>
    <action content="Dismiss" activationType="system" arguments="dismiss"/>
  </actions>
</toast>
"@
        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml($xml)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
        $aumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($aumid).Show($toast)
    } catch {
        Write-Log "toast failed: $_"
    }
}

function Open-Dashboard {
    # explorer.exe hands the file to the user's normal (non-elevated) browser
    Start-Process -FilePath "$env:WINDIR\explorer.exe" -ArgumentList "`"$DashboardPath`""
}

$forceShow = $Show -or (Test-Path $ShowFlag)
if (Test-Path $ShowFlag) { Remove-Item $ShowFlag -Force -ErrorAction SilentlyContinue }

if (-not $NoNotify) {
    $bad = @($drives | Where-Object { $_.status -in @('warning', 'critical') })
    if ($overall -in @('warning', 'critical')) {
        $first = @($bad | ForEach-Object { $dd = $_; $dd.issues | Where-Object { $_.level -eq $dd.status } | Select-Object -First 1 | ForEach-Object { "$($dd.name): $($_.text)" } }) + @($generalIssues | ForEach-Object { $_.text })
        $title = if ($overall -eq 'critical') { "DRIVE PROBLEM - back up now ($($bad.Count) drive(s))" } else { "Drive health warning ($($bad.Count) drive(s))" }
        $body = ($first | Select-Object -First 2) -join "`n"
        if ($body.Length -gt 250) { $body = $body.Substring(0, 247) + '...' }
        Show-Toast $title $body ($overall -eq 'critical')
        # Open the dashboard for anything critical, or when a problem is new since the last check
        if ($overall -eq 'critical' -or $newKeys.Count -gt 0 -or $forceShow) { Open-Dashboard }
    } else {
        if ($NotifyWhenHealthy) { Show-Toast 'All drives healthy' "$($drives.Count) drives checked - no warning signs." $false }
        if ($forceShow) { Open-Dashboard }
    }
}

Write-Log '---- run end'
