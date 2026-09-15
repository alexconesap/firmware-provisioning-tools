# Shared helpers for flash.ps1 / reset.ps1.
# Not meant to be run directly - dot-sourced after the caller sets
# $ToolsRoot to the repo root (the directory containing this lib/ folder).
#
# Layout this file assumes - everything lives under
# projects\ so the repo root stays clean:
#   <ToolsRoot>\projects\<project>\<module>\.settings         tracked
#   <ToolsRoot>\projects\<project>\<module>\.local.settings    gitignored
#   <ToolsRoot>\projects\<project>\<module>\partitions.csv     tracked (copy of the firmware repo's)
#   <ToolsRoot>\projects\<project>\<module>\build\             gitignored cache/staging,
#                                                                mirrors the firmware repo's
#                                                                code\build\<module>\ shape

function Write-Info  { param([string]$Message) Write-Host "[info] $Message" -ForegroundColor Cyan }
function Write-Warn  { param([string]$Message) Write-Host "[warn] $Message" -ForegroundColor Yellow }
function Die         { param([string]$Message) Write-Host "[error] $Message" -ForegroundColor Red; exit 1 }

function Confirm-Action {
    param([string]$Prompt)
    if ($script:AssumeYes) { return $true }
    $ans = Read-Host "$Prompt [y/N]"
    return ($ans -match '^(?i:y|yes)$')
}

# True when someone is there to answer prompts: no -Yes, and input isn't
# redirected (a double-clicked .bat, or a normal console window).
function Test-Interactive {
    if ($script:AssumeYes) { return $false }
    return -not [Console]::IsInputRedirected
}

# Numbered menu for non-technical users. Returns the 1-based choice; Enter
# picks option 1, so keep the safe/default option first. Re-asks on bad input.
function Read-MenuChoice {
    param([string]$Prompt, [string[]]$Options)
    Write-Host $Prompt
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host "  $($i + 1)) $($Options[$i])"
    }
    while ($true) {
        $choice = Read-Host "Choose [1-$($Options.Count)] (Enter = 1)"
        if ([string]::IsNullOrWhiteSpace($choice)) { return 1 }
        $idx = 0
        if ([int]::TryParse($choice.Trim(), [ref]$idx) -and $idx -ge 1 -and $idx -le $Options.Count) {
            return $idx
        }
        Write-Warn "Please type a number between 1 and $($Options.Count)."
    }
}

# Parses a bash-style KEY="value" settings file, resolving simple $VAR /
# ${VAR} references against values already parsed from this file (in the
# order they appear - matches how bash sources it). Returns a hashtable.
function Read-SettingsFile {
    param([string]$Path, [hashtable]$Seed = @{})

    $values = $Seed.Clone()
    if (-not (Test-Path $Path)) { return $values }

    foreach ($line in Get-Content -Path $Path) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed -notmatch '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"?([^"]*)"?\s*$') { continue }

        $key = $Matches[1]
        $val = $Matches[2]

        # Resolve $VAR / ${VAR} references against values parsed so far.
        $val = [regex]::Replace($val, '\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?', {
            param($m)
            $name = $m.Groups[1].Value
            if ($values.ContainsKey($name)) { $values[$name] } else { $m.Value }
        })

        $values[$key] = $val
    }
    return $values
}

function Load-ModuleSettings {
    param([string]$Project, [string]$Module)

    $moduleDir = Join-Path (Join-Path (Join-Path $script:ToolsRoot 'projects') $Project) $Module
    if (-not (Test-Path $moduleDir)) {
        Die "Unknown product/board: '$Project $Module' (no folder at $moduleDir)."
    }

    $settingsFile = Join-Path $moduleDir '.settings'
    $localFile = Join-Path $moduleDir '.local.settings'
    if (-not (Test-Path $settingsFile)) { Die "Missing settings file: $settingsFile" }

    $values = Read-SettingsFile -Path $settingsFile
    $values = Read-SettingsFile -Path $localFile -Seed $values

    foreach ($required in @('MAIN_PROJECT_ID', 'PROJECT_ID', 'IDF_TARGET', 'OTA_UPDATE_URL', 'OTA_BIN_FILENAME')) {
        if (-not $values.ContainsKey($required) -or [string]::IsNullOrWhiteSpace($values[$required])) {
            Die "Missing $required in $settingsFile"
        }
    }

    $script:ModuleDir = $moduleDir
    # As the user typed it; MAIN_PROJECT_ID can differ (fs-uv's is fs_uv).
    $script:ModuleLabel = "$Project $Module"
    $script:Settings = $values
    $script:PartitionsCsv = Join-Path $moduleDir 'partitions.csv'
    if (-not (Test-Path $script:PartitionsCsv)) {
        Die "Missing $($script:PartitionsCsv) - copy it from the firmware repo's <project>\code\<module>\partitions.csv."
    }
}

# Reads partitions.csv and returns a hashtable with NvsOffset, NvsSize,
# OtaDataOffset, OtaDataSize, AppOffset, AppSize, App1Offset, App1Size.
# AppOffset prefers the ota_0 slot; falls back to a factory partition if
# present instead. App1Offset is the ota_1 slot, if the module has a second
# one ($null otherwise) - see flash.ps1: a device that has ever received a
# real OTA update may currently be booting from ota_1, not ota_0, so an
# app-only serial reflash has to write BOTH slots to be sure the new binary
# actually takes effect regardless of which one is active.
function Read-PartitionsCsv {
    param([string]$Path)

    $result = @{ NvsOffset = $null; NvsSize = $null; OtaDataOffset = $null; OtaDataSize = $null; AppOffset = $null; AppSize = $null; App1Offset = $null; App1Size = $null }
    $factoryOffset = $null; $factorySize = $null

    foreach ($line in Get-Content -Path $Path) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }

        $fields = $trimmed.Split(',') | ForEach-Object { $_.Trim() }
        if ($fields.Count -lt 5) { continue }
        $type = $fields[1]; $subtype = $fields[2]; $offset = $fields[3]; $size = $fields[4]

        switch ("$type,$subtype") {
            'data,nvs' { $result.NvsOffset = $offset; $result.NvsSize = $size }
            'data,ota' { $result.OtaDataOffset = $offset; $result.OtaDataSize = $size }
            'app,ota_0' { $result.AppOffset = $offset; $result.AppSize = $size }
            'app,ota_1' { $result.App1Offset = $offset; $result.App1Size = $size }
            'app,factory' { $factoryOffset = $offset; $factorySize = $size }
        }
    }

    if (-not $result.AppOffset -and $factoryOffset) {
        $result.AppOffset = $factoryOffset
        $result.AppSize = $factorySize
    }

    if (-not $result.NvsOffset) { Die "Could not find an 'nvs' partition in $Path" }
    if (-not $result.AppOffset) { Die "Could not find an 'ota_0' or 'factory' app partition in $Path" }

    return $result
}

function Get-BootloaderOffset {
    param([string]$IdfTarget)
    if ($IdfTarget -eq 'esp32') { return '0x1000' }
    return '0x0'
}

# Default-mode (app-only) safety check. Reads the first 0x9000 bytes off the
# connected chip and dies with a plain-English message if an app-only flash
# can't work there - both cases need -Full instead:
#  - no ESP image header (magic byte 0xE9) at -Offset, the bootloader offset:
#    a blank / never-flashed chip, which could never boot the app;
#  - the partition table at 0x8000 doesn't have the app slots/otadata this
#    module's partitions.csv expects: the board runs other firmware (e.g. a
#    vendor demo) or an older layout, so its bootloader never looks where
#    the app gets written and it sits in a reset loop.
# If the chip can't be read at all, warns and continues.
function Test-ExistingFirmware {
    param(
        [string]$EspToolPath,
        [string]$IdfTarget,
        [string]$SerialPort,
        [string]$Baud,
        [string]$Offset
    )
    # Windows PowerShell 5.1 turns redirected native stderr into errors, which
    # 'Stop' would make fatal - the exit code is checked explicitly instead.
    $ErrorActionPreference = 'Continue'
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        & $EspToolPath --chip $IdfTarget --port $SerialPort --baud $Baud read_flash '0x0' '0x9000' $tmp 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Could not check the firmware already on the board before flashing - continuing anyway."
            return
        }
        $dump = [System.IO.File]::ReadAllBytes($tmp)
        $bootOffset = [int](ConvertTo-FlashInt $Offset)
        if ($dump.Length -le $bootOffset -or $dump[$bootOffset] -ne 0xE9) {
            $found = if ($dump.Length -gt $bootOffset) { '0x{0:X2}' -f $dump[$bootOffset] } else { '(nothing read)' }
            Die "No valid bootloader found at $Offset (expected ESP image magic byte 0xE9, found $found). This looks like a blank / never-flashed chip - an app-only flash would write the app but the chip could never boot it. Run flash again and choose 'Full flash' (or pass -Full) - it needs bootloader.bin/partition-table.bin/ota_data_initial.bin pre-staged locally, see AGENTS.md/CLAUDE.md."
        }
        $device = Get-DeviceLayout -Dump $dump
        $expected = Get-CsvLayout -Path $script:PartitionsCsv
        if ($device -ne $expected) {
            Die ("The board's flash layout doesn't match $($script:ModuleLabel) - it most likely has different firmware on it (for example a manufacturer demo) or an older layout. A normal update would leave it stuck restarting. Run flash again and choose 'Full flash' (or pass -Full).`n" +
                "  on the board: $(Format-Layout $device)`n" +
                "  expected:     $(Format-Layout $expected)")
        }
    } finally {
        Remove-Item -Path $tmp -ErrorAction SilentlyContinue
    }
}

# Partition layout helpers for Test-ExistingFirmware: one
# "<type>/<subtype>/<offset>/<size>" entry (decimal) per app slot and per
# otadata partition, sorted and space-joined, so the chip's table and
# partitions.csv compare as plain strings.
function Get-CsvLayout {
    param([string]$Path)
    $rows = foreach ($line in Get-Content -Path $Path) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        $f = @($trimmed.Split(',') | ForEach-Object { $_.Trim() })
        if ($f.Count -lt 5) { continue }
        $key = "$($f[1]),$($f[2])"
        if ($key -eq 'app,factory') {
            $t = 0; $s = 0
        } elseif ($key -match '^app,ota_(\d+)$') {
            $t = 0; $s = 16 + [int]$Matches[1]
        } elseif ($key -eq 'data,ota') {
            $t = 1; $s = 0
        } else {
            continue
        }
        '{0}/{1}/{2}/{3}' -f $t, $s, (ConvertTo-FlashInt $f[3]), (ConvertTo-FlashInt $f[4])
    }
    return (@($rows) | Sort-Object) -join ' '
}

function Get-DeviceLayout {
    param([byte[]]$Dump)
    $rows = @()
    $end = [Math]::Min($Dump.Length, 0x8C00)
    for ($i = 0x8000; $i + 32 -le $end; $i += 32) {
        if ($Dump[$i] -eq 0xEB -and $Dump[$i + 1] -eq 0xEB) { continue }   # MD5 checksum row
        if ($Dump[$i] -ne 0xAA -or $Dump[$i + 1] -ne 0x50) { break }       # 0xFFFF: end of table
        $t = $Dump[$i + 2]; $s = $Dump[$i + 3]
        if ($t -eq 0 -or ($t -eq 1 -and $s -eq 0)) {
            $rows += '{0}/{1}/{2}/{3}' -f $t, $s, [BitConverter]::ToUInt32($Dump, $i + 4), [BitConverter]::ToUInt32($Dump, $i + 8)
        }
    }
    return (@($rows) | Sort-Object) -join ' '
}

# "0x20000" / "131072" / "64K" / "4M" -> Int64
function ConvertTo-FlashInt {
    param([string]$Value)
    $v = $Value.Trim()
    if ($v -match '^(\d+)[Kk]$') { return [int64]$Matches[1] * 1KB }
    if ($v -match '^(\d+)[Mm]$') { return [int64]$Matches[1] * 1MB }
    if ($v -match '^0[xX]([0-9A-Fa-f]+)$') { return [Convert]::ToInt64($Matches[1], 16) }
    return [int64]$v
}

function Format-Layout {
    param([string]$Layout)
    if (-not $Layout) { return '(no partition table)' }
    $parts = foreach ($entry in $Layout -split ' ') {
        $p = $entry -split '/'
        $name = if ($p[0] -eq '1') { 'otadata' } elseif ($p[1] -eq '0') { 'factory' } else { 'ota_' + ([int]$p[1] - 16) }
        '{0}@0x{1:x}[0x{2:x}]' -f $name, [int64]$p[2], [int64]$p[3]
    }
    return $parts -join ' '
}

function Get-CacheBuildDir {
    param([string]$Project, [string]$Module)
    return Join-Path (Join-Path (Join-Path $script:ToolsRoot 'projects') $Project) (Join-Path $Module 'build')
}

# Locates esptool, bundled inside the Arduino IDE's esp32 core so field
# machines need nothing else installed. Returns the executable path, or
# $null if not found (falls back to 'esptool' on PATH as a last resort).
function Find-EspTool {
    $base = Join-Path $env:LOCALAPPDATA 'Arduino15\packages\esp32\tools\esptool_py'
    if (Test-Path $base) {
        # Newest first. Folder names like "4.9.dev3" / "5.0.dev1" (esp32 cores
        # 3.1-3.2) aren't valid [version] strings as-is, so normalize them.
        $dirs = Get-ChildItem -Path $base -Directory | Sort-Object -Descending {
            $v = ($_.Name -replace '[^0-9.].*$', '').Trim('.')
            if ($v -notmatch '\.') { $v += '.0' }
            try { [version]$v } catch { [version]'0.0' }
        }
        foreach ($dir in $dirs) {
            $exe = Join-Path $dir.FullName 'esptool.exe'
            if (Test-Path $exe) { return $exe }
        }
    }
    $onPath = Get-Command 'esptool.exe', 'esptool' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { return $onPath.Source }
    return $null
}

function Get-SerialPortList {
    return [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object
}

# Sets and returns the serial port to use, from (in order): -Port override,
# .local.settings SERIAL_PORT, or an interactive prompt over the ports
# currently plugged in.
function Resolve-Port {
    param([string]$PortOverride)

    if ($PortOverride) { return $PortOverride }
    if ($script:Settings.ContainsKey('SERIAL_PORT') -and $script:Settings['SERIAL_PORT']) {
        return $script:Settings['SERIAL_PORT']
    }

    $ports = @(Get-SerialPortList)
    if ($ports.Count -eq 0) {
        Die "No serial ports found. Plug in the board via USB and try again, or pass -Port <port>."
    } elseif ($ports.Count -eq 1) {
        Write-Info "Using serial port: $($ports[0])"
        return $ports[0]
    } else {
        Write-Host "Multiple serial ports found:"
        for ($i = 0; $i -lt $ports.Count; $i++) {
            Write-Host "  $($i + 1)) $($ports[$i])"
        }
        $choice = Read-Host "Which port is the board on? [1-$($ports.Count)]"
        $idx = 0
        if (-not [int]::TryParse($choice, [ref]$idx) -or $idx -lt 1 -or $idx -gt $ports.Count) {
            Die "Invalid selection."
        }
        return $ports[$idx - 1]
    }
}

# Downloads OTA_BIN_FILENAME from OTA_UPDATE_URL into $DestDir. Returns the
# downloaded file's path.
function Get-AppBin {
    param([string]$DestDir)

    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    $url = $script:Settings['OTA_UPDATE_URL'].TrimEnd('/') + '/' + $script:Settings['OTA_BIN_FILENAME']
    $dest = Join-Path $DestDir $script:Settings['OTA_BIN_FILENAME']
    $part = "$dest.part"
    Write-Info "Downloading $url"
    # Windows PowerShell 5.1 can default to pre-TLS-1.2 protocols, and its
    # progress bar slows big downloads to a crawl.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    try {
        # Temp name first: an interrupted download must never be left where
        # the next run would reuse it as the cached binary.
        Invoke-WebRequest -Uri $url -OutFile $part -TimeoutSec 300 -UseBasicParsing
        Move-Item -Force -Path $part -Destination $dest
    } catch {
        Remove-Item -Path $part -ErrorAction SilentlyContinue
        Die "Download failed: $url`nCheck your internet connection, or pre-stage $($script:Settings['OTA_BIN_FILENAME']) in:`n  $DestDir"
    }
    return $dest
}
