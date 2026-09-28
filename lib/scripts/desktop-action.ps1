# pilot / desktop-action.ps1 - one action per process.
#
# The action logic lives in _dsh-action.ps1 and the Win32 bridge in
# _dsh-win32.ps1, because the persistent worker (desktop-worker.ps1) needs exactly
# the same code without paying a process start and a C# compile per action. This
# script stays as the fallback: it is what the plugin runs when the worker cannot
# be used.
#
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File desktop-action.ps1 -ParamsPath <file>
# Input:  UTF-8 JSON { action, x, y, toX, toY, amount, text, key, title, button, hwnd, cancelFile, settleMs }
# Stdout: one JSON object. Exit 0 on success, 2 on failure (still JSON).
param([string] $ParamsPath, [Parameter(Position = 0)][string] $ParamsJson)
$ErrorActionPreference = 'Stop'
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

. (Join-Path $PSScriptRoot '_dsh-win32.ps1')
. (Join-Path $PSScriptRoot '_dsh-action.ps1')

$params = $null
if (-not [string]::IsNullOrWhiteSpace($ParamsPath)) {
    try { $ParamsJson = [System.IO.File]::ReadAllText($ParamsPath, [System.Text.Encoding]::UTF8) }
    catch { Write-ActionError "could not read the params file '$ParamsPath': $($_.Exception.Message)" }
}
if (-not [string]::IsNullOrWhiteSpace($ParamsJson)) {
    try { $params = $ParamsJson | ConvertFrom-Json } catch { Write-ActionError "invalid params JSON: $($_.Exception.Message)" }
}
if ($null -eq $params) { Write-ActionError 'params are required' }

try {
    $result = Invoke-DshAction -Config $params
    $result | ConvertTo-Json -Compress -Depth 8
    [Console]::Out.Flush()
    exit 0
} catch {
    $payload = if ($null -ne $script:ActionStopPayload) { $script:ActionStopPayload } else { [ordered]@{ ok = $false; error = $_.Exception.Message } }
    $payload | ConvertTo-Json -Compress -Depth 6
    [Console]::Out.Flush()
    exit 2
}