<#
.SYNOPSIS
    Generate a spsedev.rdp file from azd environment outputs.
.DESCRIPTION
    Reads VM FQDN and RDP bridge FQDN from azd env, detects the host's
    screen resolution, and writes a ready-to-use .rdp file at the repo root.
#>

$ErrorActionPreference = 'Stop'

# ── Resolve values from azd env ─────────────────────────────────────────────
$envOutput = azd env get-values 2>$null

function Get-EnvValue([string]$key) {
    $match = $envOutput | Select-String -Pattern "^${key}=`"?([^`"]+)`"?$"
    if ($match) { return $match.Matches[0].Groups[1].Value }
    return $null
}

$vmFqdn     = Get-EnvValue 'fqdn'
$bridgeFqdn = Get-EnvValue 'bridgeFqdn'

if (-not $vmFqdn) {
    Write-Host "WARNING: fqdn not found in azd env — skipping RDP file generation." -ForegroundColor Yellow
    exit 0
}
if (-not $bridgeFqdn) {
    Write-Host "WARNING: bridgeFqdn not found in azd env — skipping RDP file generation." -ForegroundColor Yellow
    exit 0
}

# ── Detect host screen resolution ───────────────────────────────────────────
try {
    Add-Type -AssemblyName System.Windows.Forms
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $width  = $screen.Width
    $height = $screen.Height
} catch {
    $width  = 1920
    $height = 1080
}

# ── Write RDP file ─────────────────────────────────────────────────────────
$rdpPath = Join-Path $PSScriptRoot ".." "spsedev.rdp"

$rdpContent = @"
full address:s:$vmFqdn
username:s:spadmin
gatewayusagemethod:i:2
gatewayhostname:s:$bridgeFqdn
gatewayprofileusagemethod:i:0
gatewaycredentialssource:i:0
promptcredentialonce:i:0
screen mode id:i:1
desktopwidth:i:$width
desktopheight:i:$height
use multimon:i:0
session bpp:i:32
smart sizing:i:1
compression:i:1
displayconnectionbar:i:1
disable wallpaper:i:0
allow font smoothing:i:1
allow desktop composition:i:1
redirectclipboard:i:1
redirectprinters:i:0
redirectsmartcards:i:0
redirectdrives:i:0
audiocapturemode:i:0
videoplaybackmode:i:1
connection type:i:7
networkautodetect:i:1
autoreconnection enabled:i:1
"@

Set-Content -Path $rdpPath -Value $rdpContent -Encoding ASCII -NoNewline

Write-Host ""
Write-Host "=== RDP file generated ===" -ForegroundColor Green
Write-Host "File     : $rdpPath" -ForegroundColor Yellow
Write-Host "VM       : $vmFqdn" -ForegroundColor Yellow
Write-Host "Gateway  : $bridgeFqdn" -ForegroundColor Yellow
Write-Host "Resolution: ${width}x${height}" -ForegroundColor Yellow
