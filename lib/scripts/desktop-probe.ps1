# pilot / desktop-probe.ps1 - one capture per process.
#
# The capture logic lives in _dsh-capture.ps1 and the Win32 bridge in
# _dsh-win32.ps1, because the persistent worker (desktop-worker.ps1) needs exactly
# the same code without paying a process start and a C# compile per frame. This
# script stays as the fallback: it is what the plugin runs when the worker cannot
# be used.
#
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File desktop-probe.ps1 -ParamsPath <file>
# Input:  UTF-8 JSON { out, screen, window, region, includeCursor }
# Stdout: one JSON object. Exit 0 on success, 2 on failure (still JSON).
param(
    [Parameter(Position = 0)][string] $ParamsJson,
    [string] $ParamsPath
)
$ErrorActionPreference = 'Stop'
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. (Join-Path $PSScriptRoot '_dsh-win32.ps1')
. (Join-Path $PSScriptRoot '_dsh-capture.ps1')

$params = $null
if (-not [string]::IsNullOrWhiteSpace($ParamsPath)) {
    try { $ParamsJson = [System.IO.File]::ReadAllText($ParamsPath, [System.Text.Encoding]::UTF8) }
    catch { Write-ProbeError "could not read the params file '$ParamsPath': $($_.Exception.Message)" }
}
if (-not [string]::IsNullOrWhiteSpace($ParamsJson)) {
    try { $params = $ParamsJson | ConvertFrom-Json } catch { Write-ProbeError "invalid params JSON: $($_.Exception.Message)" }
}
if ($null -eq $params) { Write-ProbeError 'params are required' }

try {
    $result = Invoke-DshCapture -Params $params
    $result | ConvertTo-Json -Compress -Depth 8
    [Console]::Out.Flush()
    exit 0
} catch {
    $payload = if ($null -ne $script:CaptureStopPayload) { $script:CaptureStopPayload } else { [ordered]@{ ok = $false; error = $_.Exception.Message } }
    $payload | ConvertTo-Json -Compress -Depth 6
    [Console]::Out.Flush()
    exit 2
}