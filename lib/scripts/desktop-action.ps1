#requires -Version 5.1
<#
  desktop-action.ps1 — DSH pilot effector half.

  Performs exactly one mouse / keyboard / window action against the interactive
  desktop. Coordinates are real physical screen pixels, the same space the
  sensor half (desktop-probe.ps1) reports and the same space the PNG it writes
  is measured in.

  Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File desktop-action.ps1 -ParamsPath <json>
  Params: { "action": "click|doubleClick|rightClick|middleClick|move|drag|scroll|
                        type|key|focus|windows",
            "x": int, "y": int, "toX": int, "toY": int,
            "text": string, "key": string, "amount": int,
            "title": string, "button": "left|right|middle",
            "cancelFile": "<path>", "settleMs": int }
  Stdout: one JSON object. Exit 0 on success, 1 on failure (still JSON).

  `cancelFile` is polled between every step: when it holds the word "stop" the
  action loop aborts immediately, which is how an interrupted turn stops a
  multi-step gesture instead of letting it play out.
#>
[CmdletBinding()]
param([string] $ParamsPath, [Parameter(Position = 0)][string] $ParamsJson)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ---------------------------------------------------------------- Win32 bridge
$nativeSource = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public static class DshInput {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, int data, IntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);

    public const uint MOVE = 0x0001, LEFTDOWN = 0x0002, LEFTUP = 0x0004, RIGHTDOWN = 0x0008,
                      RIGHTUP = 0x0010, MIDDLEDOWN = 0x0020, MIDDLEUP = 0x0040, WHEEL = 0x0800,
                      HWHEEL = 0x1000;
    public const uint KEYUP = 0x0002;
    public const byte VK_LWIN = 0x5B, VK_RWIN = 0x5C;

    public static bool BecomeDpiAware() {
        try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return true; } catch {}
        try { if (SetProcessDpiAwareness(2) == 0) return true; } catch {}
        try { if (SetProcessDPIAware()) return true; } catch {}
        return false;
    }
    public static POINT Cursor() { POINT p; GetCursorPos(out p); return p; }
    public static RECT WindowRect(IntPtr h) { RECT r; GetWindowRect(h, out r); return r; }
    public static string WindowTitle(IntPtr h) {
        var sb = new StringBuilder(512);
        GetWindowTextW(h, sb, sb.Capacity);
        return sb.ToString();
    }
    public static string WindowClass(IntPtr h) {
        var sb = new StringBuilder(256);
        GetClassNameW(h, sb, sb.Capacity);
        return sb.ToString();
    }
    public static string ForegroundTitle() { return WindowTitle(GetForegroundWindow()); }
    public static string ForegroundClass() { return WindowClass(GetForegroundWindow()); }
    public static int ForegroundPid() {
        uint pid = 0;
        GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        return (int) pid;
    }
    public static IntPtr Owner(IntPtr h) { return GetWindow(h, 4); }

    public static void WinKey(bool down) {
        byte vk = VK_LWIN;
        keybd_event(vk, 0, down ? 0u : KEYUP, IntPtr.Zero);
    }
    public static void SendKeysText(string sequence) { SendKeys.SendWait(sequence); }
    public static void Wheel(int delta) { mouse_event(WHEEL, 0, 0, delta, IntPtr.Zero); }
    public static void HWheel(int delta) { mouse_event(HWHEEL, 0, 0, delta, IntPtr.Zero); }
    public static void Button(string which, bool down) {
        uint flag;
        if (which == "right") flag = down ? RIGHTDOWN : RIGHTUP;
        else if (which == "middle") flag = down ? MIDDLEDOWN : MIDDLEUP;
        else flag = down ? LEFTDOWN : LEFTUP;
        mouse_event(flag, 0, 0, 0, IntPtr.Zero);
    }

    // Taskbar buttons live in Explorer's windows, so activation walks to the
    // root owner: SetForegroundWindow on a child is a silent no-op.
    public static bool Activate(IntPtr h) {
        IntPtr root = h;
        for (int i = 0; i < 8; i++) {
            IntPtr owner = Owner(root);
            if (owner == IntPtr.Zero) break;
            root = owner;
        }
        if (IsIconic(root)) ShowWindow(root, 9);
        bool raised = SetForegroundWindow(root);
        if (!raised) {
            // Windows blocks foreground stealing from a foreign process; the
            // documented workaround is to attach to the foreground thread first.
            uint fgPid = 0;
            IntPtr fg = GetForegroundWindow();
            uint fgThread = GetWindowThreadProcessId(fg, out fgPid);
            uint myPid = 0;
            uint myThread = GetWindowThreadProcessId(root, out myPid);
            if (fgThread != myThread) {
                AttachThreadInput(fgThread, myThread, true);
                raised = SetForegroundWindow(root);
                AttachThreadInput(fgThread, myThread, false);
            }
        }
        return raised;
    }
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);

    // Foreground is a scarce, externally-arbitrated resource: another process
    // (or the desktop host itself) can take it between two of our steps, which
    // would send an injected click or keystroke to the wrong application. So
    // every action re-asserts its target immediately before injecting input
    // and verifies the result instead of assuming the focus it asked for held.
    public static bool IsForeground(IntPtr h) { return GetForegroundWindow() == h; }
    public static bool ForceForeground(IntPtr h) {
        if (IsForeground(h)) return true;
        if (IsIconic(h)) ShowWindow(h, 9);
        if (!IsWindowVisible(h)) ShowWindow(h, 5);
        IntPtr fg = GetForegroundWindow();
        uint otherPid = 0, myPid = 0;
        uint fgThread = GetWindowThreadProcessId(fg, out otherPid);
        uint myThread = GetWindowThreadProcessId(h, out myPid);
        bool attached = false;
        if (fgThread != 0 && fgThread != myThread) {
            attached = AttachThreadInput(fgThread, myThread, true);
            if (!attached) attached = AttachThreadInput(myThread, fgThread, true);
        }
        SetForegroundWindow(h);
        BringWindowToTop(h);
        if (attached) {
            AttachThreadInput(fgThread, myThread, false);
            AttachThreadInput(myThread, fgThread, false);
        }
        return IsForeground(h);
    }
    public static bool IsAlive(IntPtr h) { return IsWindow(h); }
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);

    // Top-level window inventory. `Process.MainWindowHandle` reports 0 for a
    // window that is hidden or minimized to the tray, which makes the whole
    // application invisible to a MainWindowHandle-based scan; EnumWindows sees
    // every top-level window regardless of visibility.
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    public static IntPtr[] TopLevelWindows() {
        var found = new System.Collections.Generic.List<IntPtr>();
        EnumWindows((h, l) => { found.Add(h); return true; }, IntPtr.Zero);
        return found.ToArray();
    }
}
'@
$null = Add-Type -TypeDefinition $nativeSource -Language CSharp -ReferencedAssemblies System.Windows.Forms
$null = [DshInput]::BecomeDpiAware()

# ------------------------------------------------------------------- utilities
function Write-ActionError([string] $message) {
    [ordered]@{ ok = $false; error = $message } | ConvertTo-Json -Compress -Depth 6
    [Console]::Out.Flush()
    exit 1
}

function Get-ProcessNameSafe([uint32] $pidValue) {
    try { return (Get-Process -Id $pidValue -ErrorAction Stop).ProcessName } catch { return $null }
}

function Test-Cancelled {
    if ([string]::IsNullOrEmpty($script:CancelFile)) { return $false }
    if (-not (Test-Path -LiteralPath $script:CancelFile)) { return $false }
    try {
        $content = [System.IO.File]::ReadAllText($script:CancelFile, [System.Text.Encoding]::UTF8)
        return $content.Trim() -eq 'stop'
    } catch {
        return $false
    }
}

function Assert-Alive {
    if (Test-Cancelled) {
        [ordered]@{ ok = $false; cancelled = $true; error = 'the action loop was cancelled before this step' } | ConvertTo-Json -Compress -Depth 6
        [Console]::Out.Flush()
        exit 1
    }
}

# Re-assert the target window as foreground immediately before injecting input.
# Focus can be taken by another process between two steps, and a click or
# keystroke delivered to the wrong window is a real, destructive side effect, so
# this fails loud rather than acting on whatever happens to be in front.
function Assert-TargetFocus {
    if ($script:TargetHwnd -eq [IntPtr]::Zero) { return }
    if (-not [DshInput]::IsAlive($script:TargetHwnd)) {
        Write-ActionError "the target window (hwnd $($script:TargetHwndText)) no longer exists; re-read the screen and target a live window"
    }
    if ([DshInput]::IsForeground($script:TargetHwnd)) { return }
    if ([DshInput]::ForceForeground($script:TargetHwnd)) { return }
    $fg = [DshInput]::ForegroundTitle()
    Write-ActionError "could not bring the target window (hwnd $($script:TargetHwndText)) to the foreground; '$fg' is holding focus, so this action was refused instead of being sent to the wrong window"
}

function Get-Point([object] $x, [object] $y, [string] $what) {
    if ($null -eq $x -or $null -eq $y) { Write-ActionError "$what requires both x and y" }
    $px = 0; $py = 0
    if (-not [int]::TryParse(([string] $x), [ref] $px)) { Write-ActionError "$what x must be an integer (got '$x')" }
    if (-not [int]::TryParse(([string] $y), [ref] $py)) { Write-ActionError "$what y must be an integer (got '$y')" }
    $vx = [DshInput]::GetSystemMetrics(76); $vy = [DshInput]::GetSystemMetrics(77)
    $vw = [DshInput]::GetSystemMetrics(78); $vh = [DshInput]::GetSystemMetrics(79)
    if ($px -lt $vx -or $py -lt $vy -or $px -ge ($vx + $vw) -or $py -ge ($vy + $vh)) {
        Write-ActionError "$what point ($px,$py) is outside the virtual desktop ($vx,$vy,$vw,$vh); screenshots are physical pixels, so re-read the image before acting"
    }
    return @($px, $py)
}

function Invoke-Drag([int] $fromX, [int] $fromY, [int] $toX, [int] $toY, [string] $button) {
    $null = [DshInput]::SetCursorPos($fromX, $fromY)
    Start-Sleep -Milliseconds 90
    Assert-Alive
    [DshInput]::Button($button, $true)
    try {
        $steps = 24
        for ($i = 1; $i -le $steps; $i++) {
            $x = [int] [math]::Round($fromX + (($toX - $fromX) * $i / $steps))
            $y = [int] [math]::Round($fromY + (($toY - $fromY) * $i / $steps))
            $null = [DshInput]::SetCursorPos($x, $y)
            Start-Sleep -Milliseconds 18
            if ($i % 4 -eq 0) { Assert-Alive }
        }
    } finally {
        # Never leave the left button latched down, even on abort.
        [DshInput]::Button($button, $false)
    }
    Start-Sleep -Milliseconds 90
}

function Get-KeySequence([string] $spec) {
    $raw = $spec.Trim()
    if ([string]::IsNullOrEmpty($raw)) { Write-ActionError 'key requires a non-empty value' }
    $parts = @(($raw -split '\+') | Where-Object { $_ -ne '' } | ForEach-Object { $_.Trim() })
    if ($parts.Count -eq 0) { Write-ActionError "key '$spec' has no usable key name" }
    $modifiers = ''
    $base = ''
    foreach ($part in $parts) {
        $lower = $part.ToLowerInvariant()
        if ($lower -eq 'ctrl' -or $lower -eq 'control') { $modifiers += '^'; continue }
        if ($lower -eq 'alt') { $modifiers += '%'; continue }
        if ($lower -eq 'shift') { $modifiers += '+'; continue }
        if (@('win', 'windows', 'cmd', 'meta') -contains $lower) { $modifiers += 'WIN'; continue }
        if (-not [string]::IsNullOrEmpty($base)) { Write-ActionError "key combination '$spec' names both '$base' and '$part'; only one non-modifier key is supported" }
        $base = $part
    }
    if ([string]::IsNullOrEmpty($base) -and [string]::IsNullOrEmpty($modifiers)) { Write-ActionError "key '$spec' has no usable key name" }

    # Named keys become SendKeys tokens; a single literal character passes through.
    $named = @{
        'enter' = 'ENTER'; 'return' = 'ENTER'; 'tab' = 'TAB'; 'esc' = 'ESC'; 'escape' = 'ESC'
        'space' = ' '; 'backspace' = 'BACKSPACE'; 'back' = 'BACKSPACE'; 'delete' = 'DELETE'; 'del' = 'DELETE'
        'home' = 'HOME'; 'end' = 'END'; 'pageup' = 'PGUP'; 'pgup' = 'PGUP'; 'pagedown' = 'PGDN'; 'pgdn' = 'PGDN'
        'up' = 'UP'; 'down' = 'DOWN'; 'left' = 'LEFT'; 'right' = 'RIGHT'; 'insert' = 'INS'; 'ins' = 'INS'
    }
    if (-not [string]::IsNullOrEmpty($base)) {
        $lowerBase = $base.ToLowerInvariant()
        if ($named.ContainsKey($lowerBase)) {
            $base = $named[$lowerBase]
        } elseif ($lowerBase -match '^f([1-9]|1[0-6])$') {
            $base = 'F' + $Matches[1]
        } elseif ($lowerBase -match '^f([0-9]{1,2})$') {
            Write-ActionError "key '$spec' is above F16, which the Windows SendKeys bridge does not implement; use F1..F16"
        } elseif ($base.Length -ne 1) {
            Write-ActionError "key '$spec' names an unknown key '$base'; use a single character or a name such as enter/tab/esc/backspace/delete/home/end/up/down/left/right/pgup/pgdn/f1..f16"
        }
    }
    $encoded = if ($base.Length -eq 0) { '' } elseif ($base.Length -eq 1 -and -not ($base -cmatch '[+^%~()\[\]{}]')) { $base } else { "{$base}" }
    if ($modifiers.Contains('WIN')) {
        $plain = $modifiers.Replace('WIN', '')
        if ($plain.Length -gt 0) { Write-ActionError "key '$spec' mixes the win modifier with other modifiers, which this build does not support" }
        return @{ win = $true; sequence = $encoded }
    }
    return @{ win = $false; sequence = ($modifiers + $encoded) }
}

function Invoke-TextPaste([string] $text) {
    Add-Type -AssemblyName System.Windows.Forms
    $saved = $null
    try { if ([System.Windows.Forms.Clipboard]::ContainsText()) { $saved = [System.Windows.Forms.Clipboard]::GetText() } } catch { $saved = $null }
    try { [System.Windows.Forms.Clipboard]::SetText($text) } catch { Write-ActionError "could not place the text on the clipboard: $($_.Exception.Message)" }
    Start-Sleep -Milliseconds 60
    Assert-Alive
    try { [DshInput]::SendKeysText('^v') } catch { Write-ActionError "the paste keystroke could not be delivered: $($_.Exception.Message)" }
    Start-Sleep -Milliseconds 120
    if ($null -ne $saved) {
        try { [System.Windows.Forms.Clipboard]::SetText($saved) } catch { }
    }
}

# ---------------------------------------------------------------------- params
$params = $null
if (-not [string]::IsNullOrWhiteSpace($ParamsPath)) {
    try { $ParamsJson = [System.IO.File]::ReadAllText($ParamsPath, [System.Text.Encoding]::UTF8) }
    catch { Write-ActionError "could not read the params file '$ParamsPath': $($_.Exception.Message)" }
}
if (-not [string]::IsNullOrWhiteSpace($ParamsJson)) {
    try { $params = $ParamsJson | ConvertFrom-Json } catch { Write-ActionError "invalid params JSON: $($_.Exception.Message)" }
}
if ($null -eq $params) { Write-ActionError 'params are required' }

function Get-Param([string] $key) {
    if ($params.PSObject.Properties.Name -contains $key) { return $params.$key }
    return $null
}

$script:CancelFile = [string] (Get-Param 'cancelFile')

# Optional target window. When present, every input action re-asserts it as the
# foreground window immediately before injecting, so a click or keystroke can
# never land in whatever window happens to be in front instead.
$script:TargetHwnd = [IntPtr]::Zero
$script:TargetHwndText = ''
$hwndRaw = [string] (Get-Param 'hwnd')
if (-not [string]::IsNullOrWhiteSpace($hwndRaw)) {
    $parsed = [long] 0
    $text = $hwndRaw.Trim()
    $ok = $false
    if ($text -match '^0[xX]([0-9a-fA-F]+)$') { $ok = [long]::TryParse($Matches[1], [System.Globalization.NumberStyles]::HexNumber, [System.Globalization.CultureInfo]::InvariantCulture, [ref] $parsed) }
    else { $ok = [long]::TryParse($text, [ref] $parsed) }
    if (-not $ok -or $parsed -eq 0) { Write-ActionError "hwnd must be a nonzero window handle such as 0x1094C (got '$hwndRaw')" }
    $script:TargetHwnd = [IntPtr] $parsed
    $script:TargetHwndText = $text
}

$action = [string] (Get-Param 'action')
if ([string]::IsNullOrWhiteSpace($action)) { Write-ActionError 'action is required' }
$action = $action.Trim()

$buttonRaw = [string] (Get-Param 'button')
$button = if ([string]::IsNullOrWhiteSpace($buttonRaw)) { 'left' } else { $buttonRaw.Trim().ToLowerInvariant() }
if (@('left', 'right', 'middle') -notcontains $button) { Write-ActionError "button must be left, right, or middle (got '$button')" }

$windowTitle = [string] (Get-Param 'title')
if ($null -eq $windowTitle) { $windowTitle = '' }

$notes = @()
Assert-Alive

switch ($action) {
    'click' {
        $point = Get-Point (Get-Param 'x') (Get-Param 'y') 'click'
        $null = [DshInput]::SetCursorPos($point[0], $point[1])
        Start-Sleep -Milliseconds 80
        Assert-Alive
        Assert-TargetFocus
        [DshInput]::Button($button, $true)
        Start-Sleep -Milliseconds 45
        [DshInput]::Button($button, $false)
    }
    'doubleClick' {
        $point = Get-Point (Get-Param 'x') (Get-Param 'y') 'doubleClick'
        $null = [DshInput]::SetCursorPos($point[0], $point[1])
        Start-Sleep -Milliseconds 80
        Assert-Alive
        Assert-TargetFocus
        [DshInput]::Button($button, $true); Start-Sleep -Milliseconds 40; [DshInput]::Button($button, $false)
        Start-Sleep -Milliseconds 70
        Assert-Alive
        Assert-TargetFocus
        [DshInput]::Button($button, $true); Start-Sleep -Milliseconds 40; [DshInput]::Button($button, $false)
    }
    'rightClick' {
        $point = Get-Point (Get-Param 'x') (Get-Param 'y') 'rightClick'
        $null = [DshInput]::SetCursorPos($point[0], $point[1])
        Start-Sleep -Milliseconds 80
        Assert-Alive
        Assert-TargetFocus
        [DshInput]::Button('right', $true)
        Start-Sleep -Milliseconds 45
        [DshInput]::Button('right', $false)
    }
    'middleClick' {
        $point = Get-Point (Get-Param 'x') (Get-Param 'y') 'middleClick'
        $null = [DshInput]::SetCursorPos($point[0], $point[1])
        Start-Sleep -Milliseconds 80
        Assert-Alive
        Assert-TargetFocus
        [DshInput]::Button('middle', $true)
        Start-Sleep -Milliseconds 45
        [DshInput]::Button('middle', $false)
    }
    'move' {
        $point = Get-Point (Get-Param 'x') (Get-Param 'y') 'move'
        $null = [DshInput]::SetCursorPos($point[0], $point[1])
    }
    'drag' {
        $from = Get-Point (Get-Param 'x') (Get-Param 'y') 'drag'
        $to = Get-Point (Get-Param 'toX') (Get-Param 'toY') 'drag'
        Assert-TargetFocus
        Invoke-Drag $from[0] $from[1] $to[0] $to[1] $button
    }
    'scroll' {
        $amountRaw = Get-Param 'amount'
        $amount = 3
        if ($null -ne $amountRaw) {
            if (-not [int]::TryParse(([string] $amountRaw), [ref] $amount)) { Write-ActionError "amount must be an integer (got '$amountRaw')" }
        }
        if ($amount -eq 0) { Write-ActionError 'amount must not be zero' }
        $hasPoint = ($null -ne (Get-Param 'x')) -and ($null -ne (Get-Param 'y'))
        if ($hasPoint) {
            $point = Get-Point (Get-Param 'x') (Get-Param 'y') 'scroll'
            $null = [DshInput]::SetCursorPos($point[0], $point[1])
            Start-Sleep -Milliseconds 60
        }
        Assert-Alive
        Assert-TargetFocus
        $horizontal = ($null -ne (Get-Param 'toX')) -or ($null -ne (Get-Param 'toY'))
        if ($horizontal) {
            [DshInput]::HWheel($amount * 120)
        } else {
            [DshInput]::Wheel($amount * 120)
        }
    }
    'type' {
        $text = [string] (Get-Param 'text')
        if ([string]::IsNullOrEmpty($text)) { Write-ActionError 'type requires non-empty text' }
        Assert-TargetFocus
        Invoke-TextPaste $text
        $notes += 'The text was delivered as one paste, so the target saw no individual keystrokes.'
    }
    'key' {
        $keySpec = [string] (Get-Param 'key')
        if ([string]::IsNullOrWhiteSpace($keySpec)) { Write-ActionError 'key requires a value such as enter, tab, esc, ctrl+s, alt+tab' }
        $sequence = Get-KeySequence $keySpec
        Assert-TargetFocus
        if ($sequence.win) {
            [DshInput]::WinKey($true)
            Start-Sleep -Milliseconds 60
            try { [DshInput]::SendKeysText($sequence.sequence) }
            catch { Write-ActionError "the keystroke '$keySpec' could not be delivered: $($_.Exception.Message)" }
            finally { [DshInput]::WinKey($false) }
        } else {
            try { [DshInput]::SendKeysText($sequence.sequence) }
            catch { Write-ActionError "the keystroke '$keySpec' could not be delivered: $($_.Exception.Message)" }
        }
    }
    'focus' {
        if ($script:TargetHwnd -ne [IntPtr]::Zero) {
            # An explicit handle is authoritative and works for a window hidden
            # to the tray, which a title search cannot reach.
            if (-not [DshInput]::IsAlive($script:TargetHwnd)) { Write-ActionError "the target window (hwnd $($script:TargetHwndText)) no longer exists" }
            $raised = [DshInput]::ForceForeground($script:TargetHwnd)
            if (-not $raised) { $notes += "Windows would not hand focus to hwnd $($script:TargetHwndText); '$([DshInput]::ForegroundTitle())' kept it." }
            Start-Sleep -Milliseconds 220
        } else {
            if ([string]::IsNullOrWhiteSpace($windowTitle)) { Write-ActionError 'focus requires a title, or an hwnd' }
            $needle = $windowTitle.ToLowerInvariant()
            $target = $null
            foreach ($process in (Get-Process | Where-Object { $_.MainWindowHandle -ne 0 })) {
                if (-not [DshInput]::IsWindowVisible($process.MainWindowHandle)) { continue }
                $title = [DshInput]::WindowTitle($process.MainWindowHandle)
                if ($title.ToLowerInvariant().Contains($needle) -or $process.ProcessName.ToLowerInvariant().Contains($needle)) {
                    if ($null -eq $target) { $target = $process }
                }
            }
            if ($null -eq $target) { Write-ActionError "no visible top-level window matches '$windowTitle'; a window hidden to the tray reports no MainWindowHandle, so pass its hwnd instead" }
            $raised = [DshInput]::Activate($target.MainWindowHandle)
            if (-not $raised) { $notes += 'Windows refused the explicit foreground request; the taskbar entry may still need a click.' }
            Start-Sleep -Milliseconds 220
        }
    }
    'windows' {
        $query = $windowTitle.ToLowerInvariant()
        $list = @()
        foreach ($handle in [DshInput]::TopLevelWindows()) {
            $title = [DshInput]::WindowTitle($handle)
            if ($title.Length -eq 0) { continue }
            $owner = [uint32] 0
            $null = [DshInput]::GetWindowThreadProcessId($handle, [ref] $owner)
            $processName = Get-ProcessNameSafe $owner
            if ([string]::IsNullOrEmpty($query) -eq $false) {
                $inTitle = $title.ToLowerInvariant().Contains($query)
                $inProcess = ($null -ne $processName) -and $processName.ToLowerInvariant().Contains($query)
                if (-not ($inTitle -or $inProcess)) { continue }
            }
            $rect = [DshInput]::WindowRect($handle)
            $list += [ordered]@{
                handle     = ('0x{0:X}' -f $handle.ToInt64())
                title      = $title
                process    = $processName
                pid        = [int] $owner
                bounds     = ('{0},{1},{2},{3}' -f $rect.Left, $rect.Top, ($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top))
                minimized  = [bool] [DshInput]::IsIconic($handle)
                visible    = [bool] [DshInput]::IsWindowVisible($handle)
                foreground = [bool] [DshInput]::IsForeground($handle)
            }
        }
        $foreground = $list | Where-Object { $_.foreground } | Select-Object -First 1
        $result = [ordered]@{
            ok               = $true
            action           = 'windows'
            windows          = $list
            windowCount      = $list.Count
            foregroundWindow = $foreground
            foregroundTitle  = [DshInput]::ForegroundTitle()
            cursor           = [ordered]@{ x = ([DshInput]::Cursor()).X; y = ([DshInput]::Cursor()).Y }
            notes            = @()
            actedAt          = [DateTimeOffset]::Now.ToString('o')
        }
        $result | ConvertTo-Json -Compress -Depth 8
        [Console]::Out.Flush()
        exit 0
    }
    default {
        Write-ActionError "unknown action '$action' (use click, doubleClick, rightClick, middleClick, move, drag, scroll, type, key, focus, or windows)"
    }
}

# ------------------------------------------------------------------ settle + report
$settleRaw = Get-Param 'settleMs'
$settle = 750
if ($null -ne $settleRaw) {
    if (-not [int]::TryParse(([string] $settleRaw), [ref] $settle)) { Write-ActionError "settleMs must be an integer (got '$settleRaw')" }
}
if ($settle -lt 0) { $settle = 0 }
if ($settle -gt 0) {
    $remaining = $settle
    while ($remaining -gt 0) {
        Assert-Alive
        $slice = [math]::Min(120, $remaining)
        Start-Sleep -Milliseconds $slice
        $remaining -= $slice
    }
}

$cursor = [DshInput]::Cursor()
$result = [ordered]@{
    ok               = $true
    action           = $action
    cursor           = [ordered]@{ x = $cursor.X; y = $cursor.Y }
    foregroundTitle  = [DshInput]::ForegroundTitle()
    foregroundClass  = [DshInput]::ForegroundClass()
    foregroundProcess = Get-ProcessNameSafe ([uint32] [DshInput]::ForegroundPid())
    notes            = $notes
    actedAt          = [DateTimeOffset]::Now.ToString('o')
}
$result | ConvertTo-Json -Compress -Depth 8
[Console]::Out.Flush()
exit 0
