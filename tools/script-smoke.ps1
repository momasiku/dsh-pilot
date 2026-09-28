# pilot / tools/script-smoke.ps1 - the PowerShell half, exercised directly.
#
# Two things must stay true after extracting the shared cores:
#   1. the one-shot desktop-action.ps1 still works (it is the fallback path), and
#   2. desktop-worker.ps1 answers requests in one warm process - including a
#      failing request, which must be reported without killing the worker - and is
#      actually faster per action than starting a process each time.
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tools\script-smoke.ps1
$ErrorActionPreference = 'Stop'
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$scripts = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\scripts'
$actionScript = Join-Path $scripts 'desktop-action.ps1'
$probeScript = Join-Path $scripts 'desktop-probe.ps1'
$workerScript = Join-Path $scripts 'desktop-worker.ps1'
$work = Join-Path $env:TEMP ('pilot-script-smoke-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Force -Path $work

$failures = 0
function Check([string] $name, [bool] $ok, [string] $detail) {
  $mark = if ($ok) { 'ok  ' } else { 'FAIL' }
  Write-Host "$mark $name$(if ($detail) { " - $detail" })"
  if (-not $ok) { $script:failures += 1 }
}

function Invoke-OneShot([hashtable] $payload) {
  $file = Join-Path $work ('params-' + [guid]::NewGuid().ToString('N') + '.json')
  [System.IO.File]::WriteAllText($file, ($payload | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $actionScript -ParamsPath $file
  $code = $LASTEXITCODE
  $sw.Stop()
  Remove-Item $file -ErrorAction SilentlyContinue
  $line = @($raw | Where-Object { $_ -and $_.ToString().Trim() -ne '' })[-1]
  return @{ ms = $sw.ElapsedMilliseconds; exit = $code; value = ($line | ConvertFrom-Json) }
}

# ── 1. the one-shot fallback path ───────────────────────────────────────────
$moved = Invoke-OneShot @{ action = 'move'; x = 140; y = 160; settleMs = 0 }
Check 'one-shot: move succeeds' ($moved.value.ok -eq $true -and $moved.value.cursor.x -eq 140 -and $moved.value.cursor.y -eq 160) "exit=$($moved.exit) cursor=$($moved.value.cursor.x),$($moved.value.cursor.y) took $($moved.ms) ms"

$listed = Invoke-OneShot @{ action = 'windows'; settleMs = 0 }
Check 'one-shot: windows lists' ($listed.value.ok -eq $true -and $listed.value.windowCount -ge 1) "count=$($listed.value.windowCount)"

$missing = Invoke-OneShot @{ action = 'focus'; title = 'pilot-no-such-window-zzz'; settleMs = 0 }
Check 'one-shot: an unknown window fails as JSON, not as a crash' ($missing.value.ok -eq $false -and $missing.value.error -match 'no visible top-level window') "exit=$($missing.exit)"

function Invoke-OneShotProbe([hashtable] $payload) {
  $file = Join-Path $work ('params-' + [guid]::NewGuid().ToString('N') + '.json')
  [System.IO.File]::WriteAllText($file, ($payload | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $probeScript -ParamsPath $file
  $code = $LASTEXITCODE
  $sw.Stop()
  Remove-Item $file -ErrorAction SilentlyContinue
  $line = @($raw | Where-Object { $_ -and $_.ToString().Trim() -ne '' })[-1]
  return @{ ms = $sw.ElapsedMilliseconds; exit = $code; value = ($line | ConvertFrom-Json) }
}

$oneShotShot = Join-Path $work 'one-shot.png'
$probeOne = Invoke-OneShotProbe @{ out = $oneShotShot; screen = 'primary' }
Check 'one-shot probe: captures the primary monitor' ($probeOne.value.ok -eq $true -and $probeOne.value.kind -eq 'primary' -and (Test-Path $oneShotShot) -and $probeOne.value.imageWidth -gt 0) "kind=$($probeOne.value.kind) size=$($probeOne.value.imageWidth)x$($probeOne.value.imageHeight) took $($probeOne.ms) ms"

# ── 2. the worker ───────────────────────────────────────────────────────────
$start = New-Object System.Diagnostics.ProcessStartInfo
$start.FileName = 'powershell'
$start.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$workerScript`""
$start.RedirectStandardInput = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$worker = [System.Diagnostics.Process]::Start($start)

function Send-Worker([hashtable] $payload, [int] $timeoutMs = 15000) {
  $json = $payload | ConvertTo-Json -Compress
  $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $worker.StandardInput.WriteLine($b64)
  $worker.StandardInput.Flush()
  $task = $worker.StandardOutput.ReadLineAsync()
  if (-not $task.Wait($timeoutMs)) { throw "the worker did not answer within ${timeoutMs}ms" }
  $sw.Stop()
  $line = $task.Result
  if ($null -eq $line) {
    # stdout ended: the worker is gone. Say why instead of failing on a null parse.
    $stderrTask = $worker.StandardError.ReadToEndAsync()
    $null = $stderrTask.Wait(1000)
    $detail = if ($stderrTask.IsCompleted) { $stderrTask.Result.Trim() } else { '(stderr not drained)' }
    $state = if ($worker.HasExited) { "exitCode=$($worker.ExitCode)" } else { 'still running' }
    throw "the worker closed stdout while answering (${state}): ${detail}"
  }
  return @{ ms = $sw.ElapsedMilliseconds; value = ($line | ConvertFrom-Json) }
}

try {
  $readyTask = $worker.StandardOutput.ReadLineAsync()
  if (-not $readyTask.Wait(30000)) { throw 'the worker never reported ready' }
  $ready = $readyTask.Result | ConvertFrom-Json
  Check 'worker: reports ready with its pid' ($ready.ok -eq $true -and $ready.ready -eq $true -and $ready.pid -gt 0) "pid=$($ready.pid)"

  $cold = Send-Worker @{ id = 'a'; action = 'move'; x = 200; y = 220; settleMs = 0 }
  Check 'worker: first action succeeds' ($cold.value.ok -eq $true -and $cold.value.cursor.x -eq 200 -and $cold.value.id -eq 'a') "took $($cold.ms) ms"

  $warm = @()
  foreach ($i in 1..3) {
    $r = Send-Worker @{ id = "w$i"; action = 'move'; x = (300 + $i); y = (320 + $i); settleMs = 0 }
    if ($r.value.ok -ne $true) { Check "worker: warm action $i" $false ($r.value.error) }
    $warm += $r.ms
  }
  $warmMedian = ($warm | Sort-Object)[1]
  Check 'worker: warm actions stay fast' ($warmMedian -lt 400) "warm=$(($warm -join '/')) ms, median=$warmMedian ms; one-shot cold=$($moved.ms) ms"

  $failed = Send-Worker @{ id = 'f'; action = 'focus'; title = 'pilot-no-such-window-zzz'; settleMs = 0 }
  Check 'worker: a failing action is reported' ($failed.value.ok -eq $false -and $failed.value.error -match 'no visible top-level window') $failed.value.error

  $after = Send-Worker @{ id = 'after'; action = 'move'; x = 260; y = 280; settleMs = 0 }
  Check 'worker: survives a failed action and keeps serving' ($after.value.ok -eq $true -and $after.value.cursor.x -eq 260) "took $($after.ms) ms"

  $cancelFile = Join-Path $work 'cancel.txt'
  [System.IO.File]::WriteAllText($cancelFile, 'stop', (New-Object System.Text.UTF8Encoding($false)))
  $cancelled = Send-Worker @{ id = 'c'; action = 'move'; x = 400; y = 400; settleMs = 500; cancelFile = $cancelFile }
  Check 'worker: a cancelled request says so' ($cancelled.value.ok -eq $false -and $cancelled.value.cancelled -eq $true) ($cancelled.value.error)

  $afterCancel = Send-Worker @{ id = 'd'; action = 'move'; x = 280; y = 300; settleMs = 0 }
  Check 'worker: survives a cancellation and keeps serving' ($afterCancel.value.ok -eq $true -and $afterCancel.value.cursor.x -eq 280) "took $($afterCancel.ms) ms"

  # captures go through the same warm process
  $warmShot = Join-Path $work 'worker.png'
  $probeWarm = Send-Worker @{ id = 'cap'; kind = 'capture'; out = $warmShot; screen = 'primary' }
  Check 'worker: captures through the warm process' ($probeWarm.value.ok -eq $true -and (Test-Path $warmShot) -and $probeWarm.value.imageWidth -gt 0) "size=$($probeWarm.value.imageWidth)x$($probeWarm.value.imageHeight) took $($probeWarm.ms) ms vs one-shot $($probeOne.ms) ms"

  $probeFail = Send-Worker @{ id = 'capfail'; kind = 'capture'; out = (Join-Path $work 'nope.png'); window = 'pilot-no-such-window-zzz' }
  Check 'worker: a failed capture is reported' ($probeFail.value.ok -eq $false -and $probeFail.value.error -match 'no visible top-level window') $probeFail.value.error

  $probeAfter = Send-Worker @{ id = 'capafter'; kind = 'capture'; out = (Join-Path $work 'after.png'); screen = 'primary' }
  Check 'worker: survives a failed capture' ($probeAfter.value.ok -eq $true -and (Test-Path (Join-Path $work 'after.png'))) "took $($probeAfter.ms) ms"

  $worker.StandardInput.WriteLine(([Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('{"quit":true}'))))
  $worker.StandardInput.Flush()
  $exited = $worker.WaitForExit(5000)
  Check 'worker: quits on request' ($exited -eq $true) "exitCode=$(if ($exited) { $worker.ExitCode } else { 'still running' })"
} finally {
  if (-not $worker.HasExited) { try { $worker.Kill() } catch { } }
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "script-smoke: $(if ($failures -eq 0) { 'OK' } else { "$failures check(s) failed" })"
exit $(if ($failures -eq 0) { 0 } else { 1 })
