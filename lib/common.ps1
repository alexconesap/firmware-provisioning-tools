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

# Reads the single byte at -Offset (a bootloader offset) off the currently
# connected chip and dies with a plain-English message if it isn't a valid
# ESP image header (magic byte 0xE9) - i.e. this chip has no bootloader at
# all, so an app-only flash would "succeed" while leaving it unable to boot
# anything (a genuinely blank chip needs -Full instead). Only meaningful
# before an app-only flash; -Full always (re)writes the bootloader itself.
function Test-BootloaderPresent {
    param(
        [string]$EspToolPath,
        [string]$IdfTarget,
        [string]$SerialPort,
        [string]$Baud,
        [string]$Offset
    )
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        & $EspToolPath --chip $IdfTarget --port $SerialPort --baud $Baud read_flash $Offset 1 $tmp 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Could not verify the existing bootloader before flashing - continuing anyway."
            return
        }
        $bytes = [System.IO.File]::ReadAllBytes($tmp)
        if ($bytes.Length -lt 1 -or $bytes[0] -ne 0xE9) {
            $found = if ($bytes.Length -ge 1) { '0x{0:X2}' -f $bytes[0] } else { '(nothing read)' }
            Die "No valid bootloader found at $Offset (expected ESP image magic byte 0xE9, found $found). This looks like a blank / never-flashed chip - an app-only flash would write the app but the chip could never boot it. Re-run with -Full instead (needs bootloader.bin/partition-table.bin/ota_data_initial.bin pre-staged locally - see AGENTS.md/CLAUDE.md)."
        }
    } finally {
        Remove-Item -Path $tmp -ErrorAction SilentlyContinue
    }
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
        $latest = Get-ChildItem -Path $base -Directory |
            Sort-Object { [version]($_.Name -replace '[^0-9.].*$', '') } -ErrorAction SilentlyContinue |
            Select-Object -Last 1
        if ($latest) {
            $exe = Join-Path $latest.FullName 'esptool.exe'
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
    Write-Info "Downloading $url"
    try {
        Invoke-WebRequest -Uri $url -OutFile $dest -TimeoutSec 60 -UseBasicParsing
    } catch {
        Die "Download failed: $url`nCheck your internet connection, or pre-stage $($script:Settings['OTA_BIN_FILENAME']) in:`n  $DestDir"
    }
    return $dest
}
