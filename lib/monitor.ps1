<#
.SYNOPSIS
    Serial monitor for a flashed ESP32/ESP32-S3 board.

.DESCRIPTION
    Prints whatever the board's own UART logging writes, so you can see
    boot/panic output without Arduino IDE. Read-only - never touches flash.
    Uses .NET's SerialPort directly, so nothing extra needs to be installed.
    Press Ctrl+C to stop.

.PARAMETER Project
    Product name, e.g. "wendy".

.PARAMETER Module
    Board/module name, e.g. "rbtensy".

.PARAMETER Port
    Override the serial COM port (skips auto-detect/prompt).

.PARAMETER Baud
    Serial baud rate for the board's own log output. Default 115200 - this
    is the app's runtime UART speed, NOT the 460800 flashing baud used by
    flash.ps1.

.EXAMPLE
    monitor.bat wendy rbtensy

.EXAMPLE
    monitor.bat wendy rbtensy -Port COM5 -Baud 115200
#>
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Project,
    [Parameter(Mandatory = $true, Position = 1)][string]$Module,
    [string]$Port,
    [int]$Baud = 115200
)

$ErrorActionPreference = 'Stop'
# This script lives in lib\ (run via the root monitor.bat); the tools root is one level up.
$ToolsRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $ToolsRoot 'lib\common.ps1')
$script:ToolsRoot = $ToolsRoot
$script:AssumeYes = $true

Load-ModuleSettings -Project $Project -Module $Module
$SerialPort = Resolve-Port -PortOverride $Port

Write-Info "Opening $SerialPort at $Baud baud. Press Ctrl+C to stop."

$Sp = New-Object System.IO.Ports.SerialPort($SerialPort, $Baud, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
$Sp.ReadTimeout = 200
try {
    $Sp.Open()
    while ($true) {
        try {
            $Chunk = $Sp.ReadExisting()
            if ($Chunk) { Write-Host -NoNewline $Chunk }
        } catch [System.TimeoutException] {
            # Nothing arrived within the timeout - normal, keep polling.
        }
        Start-Sleep -Milliseconds 50
    }
} finally {
    if ($Sp.IsOpen) { $Sp.Close() }
}
