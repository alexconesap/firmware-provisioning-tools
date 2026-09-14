<#
.SYNOPSIS
    Flash firmware onto an ESP32 / ESP32-S3 board over USB.

.DESCRIPTION
    Uses esptool (bundled inside the Arduino IDE's esp32 core) - no ESP-IDF,
    no git, no source repo required.

.PARAMETER Project
    Product name, e.g. "wendy".

.PARAMETER Module
    Board/module name, e.g. "rbtensy". Resolves to .\wendy\rbtensy\

.PARAMETER Port
    Override the serial COM port (skips auto-detect/prompt).

.PARAMETER EspType
    Override IDF_TARGET from .settings (esp32 or esp32s3).

.PARAMETER Baud
    Flash baud rate. Default 460800.

.PARAMETER Full
    Blank-chip flash: writes bootloader + partition table + OTA-init data +
    the app, instead of just re-flashing the app over an existing
    bootloader. Requires those files pre-staged locally (the update server
    does not publish them yet); this is the "prepared on a
    laptop before going on-site" case.

.PARAMETER Refresh
    Re-download the app binary even if a cached copy already sits in the
    local cache.

.PARAMETER Yes
    Skip the confirmation prompt before flashing.

.EXAMPLE
    .\flash.ps1 wendy rbtensy

.EXAMPLE
    .\flash.ps1 wendy rbtensy -Port COM5

.EXAMPLE
    .\flash.ps1 wendy rbtensy -Full   # needs pre-staged build files
#>
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Project,
    [Parameter(Mandatory = $true, Position = 1)][string]$Module,
    [string]$Port,
    [string]$EspType,
    [string]$Baud = '460800',
    [switch]$Full,
    [switch]$Refresh,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$ToolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ToolsRoot 'lib\common.ps1')
$script:ToolsRoot = $ToolsRoot
$script:AssumeYes = [bool]$Yes

Load-ModuleSettings -Project $Project -Module $Module
$IdfTarget = if ($EspType) { $EspType } else { $Settings['IDF_TARGET'] }

$SerialPort = Resolve-Port -PortOverride $Port
$EspTool = Find-EspTool
if (-not $EspTool) {
    Die "Could not find esptool. Install the esp32 core in Arduino IDE (Boards Manager), or install esptool yourself (pip install esptool)."
}

$Parts = Read-PartitionsCsv -Path $script:PartitionsCsv
$BuildDir = Get-CacheBuildDir -Project $Project -Module $Module
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

$FlashPairs = New-Object System.Collections.Generic.List[string]
$OtaBinFilename = $Settings['OTA_BIN_FILENAME']

if ($Full) {
    $BootloaderFile = Join-Path $BuildDir 'bootloader\bootloader.bin'
    $PartTableFile = Join-Path $BuildDir 'partition_table\partition-table.bin'
    $OtaDataFile = Join-Path $BuildDir 'ota_data_initial.bin'
    $AppFile = Join-Path $BuildDir $OtaBinFilename

    $Missing = @($BootloaderFile, $PartTableFile, $OtaDataFile, $AppFile) | Where-Object { -not (Test-Path $_) }
    if ($Missing.Count -gt 0) {
        Write-Host "Full blank-chip flash needs these files staged locally first (the update" -ForegroundColor Red
        Write-Host "server doesn't publish them yet):" -ForegroundColor Red
        $Missing | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
        Write-Host ""
        Write-Host "Copy a full 'code\build\$Module\' folder from a developer machine into:"
        Write-Host "  $BuildDir"
        Die "Missing pre-staged build files."
    }

    $BootloaderOffset = Get-BootloaderOffset -IdfTarget $IdfTarget
    $FlashPairs.Add($BootloaderOffset); $FlashPairs.Add('bootloader\bootloader.bin')
    $FlashPairs.Add('0x8000'); $FlashPairs.Add('partition_table\partition-table.bin')
    $FlashPairs.Add($Parts.OtaDataOffset); $FlashPairs.Add('ota_data_initial.bin')
    $FlashPairs.Add($Parts.AppOffset); $FlashPairs.Add($OtaBinFilename)
    $ModeLabel = 'full (blank-chip) flash'
} else {
    $AppFile = Join-Path $BuildDir $OtaBinFilename
    if ($Refresh -or -not (Test-Path $AppFile)) {
        Get-AppBin -DestDir $BuildDir | Out-Null
    } else {
        Write-Info "Using cached binary: $AppFile (pass -Refresh to re-download)"
    }
    $FlashPairs.Add($Parts.AppOffset); $FlashPairs.Add($OtaBinFilename)
    $ModeLabel = 'app-only flash (existing bootloader/partition table preserved)'
}

$Sep = '=' * 67
Write-Host $Sep
Write-Host "Product/board:  $Project $Module" -ForegroundColor Cyan
Write-Host "Chip:           $IdfTarget"
Write-Host "Port:           $SerialPort" -ForegroundColor Yellow
Write-Host "Mode:           $ModeLabel"
Write-Host "Files:"
for ($i = 0; $i -lt $FlashPairs.Count; $i += 2) {
    Write-Host "  $($FlashPairs[$i])  $($FlashPairs[$i + 1])"
}
Write-Host $Sep

if (-not (Confirm-Action -Prompt "Flash now?")) { Die "Aborted." }

$LogFile = Join-Path $BuildDir 'flash.last.log'

Push-Location $BuildDir
try {
    $EspArgs = @('--chip', $IdfTarget, '--port', $SerialPort, '--baud', $Baud,
                 'write_flash', '-z', '--flash_mode', 'keep', '--flash_freq', 'keep', '--flash_size', 'keep') + $FlashPairs
    & $EspTool @EspArgs 2>&1 | Tee-Object -FilePath $LogFile
    $Rc = $LASTEXITCODE
} finally {
    Pop-Location
}

Write-Host ""
if ($Rc -eq 0) {
    Write-Host "FLASH SUCCEEDED - $Project $Module  port: $SerialPort" -ForegroundColor Green
} else {
    Write-Host "FLASH FAILED - $Project $Module  port: $SerialPort" -ForegroundColor Red
    Write-Host "Full log: $LogFile"
}
exit $Rc
