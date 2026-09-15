<#
.SYNOPSIS
    Wipe a board's saved settings (or its entire flash) over USB via esptool.

.DESCRIPTION
    Replicates arduino-build-scripts/erase_settings.sh, but reads the NVS
    offset/size from the module's own partitions.csv instead of assuming the
    classic Arduino default - a differently-partitioned module can differ.

.PARAMETER Project
    Product name, e.g. "wendy".

.PARAMETER Module
    Board/module name, e.g. "rbtensy". Resolves to .\wendy\rbtensy\

.PARAMETER Port
    Override the serial COM port (skips auto-detect/prompt).

.PARAMETER Full
    Erase the ENTIRE flash, including the firmware itself - not just NVS.
    The device will need a full `flash` afterward, not just a reset.
    Without this switch, only the NVS/settings partition is erased - or, if
    -Yes wasn't given and someone can answer (e.g. a double-clicked
    reset.bat), the script asks which of the two to do.

.PARAMETER Yes
    Skip the confirmation prompt.

.EXAMPLE
    reset.bat wendy rbtensy

.EXAMPLE
    reset.bat wendy rbtensy -Full

.NOTES
    IMPORTANT - pairing is stored on BOTH sides, not just this board: the
    coordinator ("main") remembers every paired node's MAC/id, and each
    node independently remembers the coordinator's MAC/channel, each in its
    own NVS (ungula::net::pairing - PairingCoordinator::storePairedClient /
    PairingClient::storePairing). Erasing NVS on only ONE board leaves the
    OTHER board still remembering the pairing - to fully un-pair a node,
    run this on BOTH the node AND its coordinator ("main"). Pairing state
    is also only read from NVS once, at boot, so the change isn't visible
    until the board actually reboots - -after hard_reset below forces that.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Project,
    [Parameter(Mandatory = $true, Position = 1)][string]$Module,
    [string]$Port,
    [switch]$Full,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
# This script lives in lib\ (run via the root reset.bat); the tools root is one level up.
$ToolsRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $ToolsRoot 'lib\common.ps1')
$script:ToolsRoot = $ToolsRoot
$script:AssumeYes = [bool]$Yes

Load-ModuleSettings -Project $Project -Module $Module
$IdfTarget = $Settings['IDF_TARGET']

# Same as flash.ps1: offer -Full as a menu choice when someone can answer.
$FullMode = [bool]$Full
if (-not $FullMode -and (Test-Interactive)) {
    $pick = Read-MenuChoice -Prompt "What do you want to erase?" -Options @(
        "Settings only - saved settings and pairing; the firmware stays",
        "Everything    - the firmware too; the board needs a Full flash afterward"
    )
    $FullMode = ($pick -eq 2)
}

$SerialPort = Resolve-Port -PortOverride $Port
$EspTool = Find-EspTool
if (-not $EspTool) {
    Die "Could not find esptool. Install the esp32 core in Arduino IDE (Boards Manager), or install esptool yourself (pip install esptool)."
}
$Parts = Read-PartitionsCsv -Path $script:PartitionsCsv

if ($FullMode) {
    Write-Host "This will erase the ENTIRE flash on this board, including its firmware." -ForegroundColor Red
    Write-Host "It will not run again until you run flash.bat $Project $Module and choose 'Full flash' (or pass -Full)."
    if (-not (Confirm-Action -Prompt "Erase everything on ${SerialPort}?")) { Die "Aborted." }
    & $EspTool --chip $IdfTarget --port $SerialPort --after hard_reset erase_flash
} else {
    Write-Host "Erasing NVS/settings only - offset $($Parts.NvsOffset), size $($Parts.NvsSize) (from $($script:PartitionsCsv))."
    Write-Host "Note: this only clears THIS board's half of any pairing. To fully un-pair," -ForegroundColor Yellow
    Write-Host "also run this on the other side (the node's coordinator, or vice versa)." -ForegroundColor Yellow
    if (-not (Confirm-Action -Prompt "Erase settings on ${SerialPort}?")) { Die "Aborted." }
    & $EspTool --chip $IdfTarget --port $SerialPort --after hard_reset erase_region $Parts.NvsOffset $Parts.NvsSize
}
$Rc = $LASTEXITCODE

Write-Host ""
if ($Rc -eq 0) {
    Write-Host "RESET DONE - $Project $Module  port: $SerialPort" -ForegroundColor Green
} else {
    Write-Host "RESET FAILED - $Project $Module  port: $SerialPort" -ForegroundColor Red
}
exit $Rc
