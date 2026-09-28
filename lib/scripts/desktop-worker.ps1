# pilot / desktop-worker.ps1 - one warm PowerShell process, many requests.
#
# Why: every action and every frame used to cost a process start plus an Add-Type
# compile of the C# bridge, which measured ~0.9 s each. Here the bridge is compiled
# once and the process stays alive, so a request costs the work itself.
#
# Protocol, one request per line, one response per line, all UTF-8 JSON:
#   in : base64(JSON)  { id?, kind?: 'action'|'capture', quit?, ... }
#        kind defaults to 'action': { action, x, y, toX, toY, amount, text, key, title, button, hwnd, cancelFile, settleMs }
#        kind 'capture':          { out, screen, window, region, includeCursor }
#   out: JSON          { ok: true, ... } | { ok: false, error, cancelled? }
# The first line the worker writes is { ok: true, ready: true, pid }.
#
# A cancelled request is answered with { ok:false, cancelled:true } and the worker
# keeps running: the cancel file is polled between steps, exactly as the one-shot
# script did, so interrupting a turn never leaves a gesture half-applied.
$ErrorActionPreference = 'Stop'
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ProgressPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot '_dsh-win32.ps1')
. (Join-Path $PSScriptRoot '_dsh-action.ps1')
. (Join-Path $PSScriptRoot '_dsh-capture.ps1')

function Write-Protocol([object] $payload) {
    [Console]::Out.WriteLine(($payload | ConvertTo-Json -Compress -Depth 8))
    [Console]::Out.Flush()
}

Write-Protocol ([ordered]@{ ok = $true; ready = $true; pid = $PID })

while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    $line = $line.Trim()
    if ($line.Length -eq 0) { continue }

    $script:ActionStopPayload = $null
    $script:CaptureStopPayload = $null
    $requestId = ''
    try {
        $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($line))
        $config = $json | ConvertFrom-Json
        if ($config.PSObject.Properties.Name -contains 'id' -and $null -ne $config.id) { $requestId = [string] $config.id }
        if ($config.PSObject.Properties.Name -contains 'quit' -and $config.quit -eq $true) { break }
        $kind = if ($config.PSObject.Properties.Name -contains 'kind' -and $null -ne $config.kind) { ([string] $config.kind).ToLowerInvariant() } else { 'action' }
        switch ($kind) {
            'capture' { $result = Invoke-DshCapture -Params $config }
            'action'  { $result = Invoke-DshAction -Config $config }
            default   { throw "unknown request kind '$kind' (use action or capture)" }
        }
        if ($requestId.Length -gt 0) { $result['id'] = $requestId }
        Write-Protocol $result
    } catch {
        $payload = if ($null -ne $script:ActionStopPayload) { $script:ActionStopPayload }
                   elseif ($null -ne $script:CaptureStopPayload) { $script:CaptureStopPayload }
                   else { [ordered]@{ ok = $false; error = $_.Exception.Message } }
        if ($requestId.Length -gt 0) { $payload['id'] = $requestId }
        Write-Protocol $payload
    }
}
exit 0