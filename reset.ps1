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
    Without this switch, only the NVS/settings partition is erased.

.PARAMETER Yes
    Skip the confirmation prompt.

.EXAMPLE
    .\reset.ps1 wendy rbtensy

.EXAMPLE
    .\reset.ps1 wendy rbtensy -Full

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
$ToolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ToolsRoot 'lib\common.ps1')
$script:ToolsRoot = $ToolsRoot
$script:AssumeYes = [bool]$Yes

Load-ModuleSettings -Project $Project -Module $Module
$IdfTarget = $Settings['IDF_TARGET']
$SerialPort = Resolve-Port -PortOverride $Port
$EspTool = Find-EspTool
if (-not $EspTool) {
    Die "Could not find esptool. Install the esp32 core in Arduino IDE (Boards Manager), or install esptool yourself (pip install esptool)."
}
$Parts = Read-PartitionsCsv -Path $script:PartitionsCsv

if ($Full) {
    Write-Host "This will erase the ENTIRE flash on this board, including its firmware." -ForegroundColor Red
    Write-Host "It will not run again until you flash it (.\flash.ps1 $Project $Module -Full)."
    if (-not (Confirm-Action -Prompt "Erase everything on ${SerialPort}?")) { Die "Aborted." }
    & $EspTool --chip $IdfTarget --port $SerialPort --after hard_reset erase_flash
} else {
    Write-Host "Erasing NVS/settings only - offset $($Parts.NvsOffset), size $($Parts.NvsSize) (from $($script:PartitionsCsv))."
    Write-Host "Note: this only clears THIS board's half of any pairing. To fully un-pair," -ForegroundColor Yellow
    Write-Host "also run this on the other side (the node's coordinator, or vice versa)." -ForegroundColor Yellow
    if (-not (Confirm-Action -Prompt "Erase settings on ${SerialPort}?")) { Die "Aborted." }
    & $EspTool --chip $IdfTarget --port $SerialPort --after hard_reset erase_region $Parts.NvsOffset $Parts.NvsSize
}

Write-Host "RESET DONE - $Project $Module  port: $SerialPort" -ForegroundColor Green
