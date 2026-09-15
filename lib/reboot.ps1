<#
.SYNOPSIS
    Reset a board over USB serial without touching flash.

.DESCRIPTION
    Uses esptool's own reset sequence (the same DTR/RTS dance it performs
    before/after writing), so it works with whatever auto-reset circuit the
    board actually has. Useful after a flash to force a clean boot, or to
    check "is anything there at all" together with monitor.bat.

.PARAMETER Project
    Product name, e.g. "wendy".

.PARAMETER Module
    Board/module name, e.g. "rbtensy".

.PARAMETER Port
    Override the serial COM port (skips auto-detect/prompt).

.PARAMETER EspType
    Override IDF_TARGET from .settings (esp32 or esp32s3).

.EXAMPLE
    reboot.bat wendy rbtensy

.EXAMPLE
    reboot.bat wendy rbtensy -Port COM5
#>
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Project,
    [Parameter(Mandatory = $true, Position = 1)][string]$Module,
    [string]$Port,
    [string]$EspType
)

$ErrorActionPreference = 'Stop'
# This script lives in lib\ (run via the root reboot.bat); the tools root is one level up.
$ToolsRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $ToolsRoot 'lib\common.ps1')
$script:ToolsRoot = $ToolsRoot
$script:AssumeYes = $true

Load-ModuleSettings -Project $Project -Module $Module
$IdfTarget = if ($EspType) { $EspType } else { $Settings['IDF_TARGET'] }

$SerialPort = Resolve-Port -PortOverride $Port
$EspTool = Find-EspTool
if (-not $EspTool) {
    Die "Could not find esptool. Install the esp32 core in Arduino IDE (Boards Manager), or install esptool yourself (pip install esptool)."
}

Write-Info "Resetting $Project $Module on $SerialPort..."
& $EspTool --chip $IdfTarget --port $SerialPort run
if ($LASTEXITCODE -ne 0) {
    Die "Could not reset $Project $Module on $SerialPort (esptool exit code $LASTEXITCODE). Check the USB cable and port."
}

Write-Host "RESET SENT - the board should now be booting. Run monitor.bat $Project $Module to watch it." -ForegroundColor Green
