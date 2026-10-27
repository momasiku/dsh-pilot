
# pilot / _dsh-overlay.ps1 - the visible part of a takeover.
#
# Ring around every monitor, a caption naming the operator, and a halo that follows
# the pointer so it is obvious the movement is not yours. Esc stamps the cancel token
# the host published.
#
# The halo is DRAWING, not the pointer itself: this process never calls SetCursorPos
# and never installs an input hook, because either would add exactly the input lag
# that makes a person's own mouse feel broken while an agent drives. Windows draws
# the real cursor above every window, so the ring and glow sit under it and the
# pointer reads as larger and lit without being replaced.
param(
    [Parameter(Mandatory = $true)][string] $StateDir
)
$ErrorActionPreference = 'Stop'

# One overlay per state directory, checked BEFORE the C# compile and the WPF load.
# Those cost 1.5-3 s on a busy machine, and a duplicate copy that pays for them before
# discovering it is a duplicate shows up as "two overlays polling" for seconds.
$mutexName = 'Local\DshOverlay_' + ($StateDir -replace '[^A-Za-z0-9]', '_')
$global:DshOvMutex = New-Object System.Threading.Mutex($false, $mutexName)
if (-not $global:DshOvMutex.WaitOne(0)) {
    try {
        if (Test-Path -LiteralPath $StateDir) {
            [System.IO.File]::AppendAllText((Join-Path $StateDir 'status.txt'),
                ((Get-Date).ToString('HH:mm:ss.fff') + ' another overlay owns this state dir; exiting' + [Environment]::NewLine))
        }
    } catch { }
    exit 0
}



# Declare per-monitor v2 DPI awareness, and measure the scale anyway.
#
# Under powershell.exe the declaration below is a no-op: the host manifest settles the
# process's awareness before the script runs, so this window stays DPI-unaware and
# Windows lays it out in logical units (a 2560x1600 panel at 150% reports 1707x1067).
# Laying out in logical units is fine - the caption scales with the OS - but
# GetCursorPos answers in *physical* pixels, so the halo was drawn where the pointer is
# not. Primary() reads the real display mode through EnumDisplaySettings, which is not
# virtualised, and the caller divides the cursor position by the quotient.
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class DshOvDpi {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion;
        public short dmDriverVersion;
        public short dmSize;
        public short dmDriverExtra;
        public int dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public int dmDisplayOrientation;
        public int dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel;
        public int dmPelsWidth;
        public int dmPelsHeight;
        public int dmDisplayFlags;
        public int dmDisplayFrequency;
        public int dmICMMethod;
        public int dmICMIntent;
        public int dmMediaType;
        public int dmDitherType;
        public int dmReserved1;
        public int dmReserved2;
        public int dmPanningWidth;
        public int dmPanningHeight;
    }
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool EnumDisplaySettingsW(string device, int mode, ref DEVMODE devMode);
    public static bool Apply() {
        try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return true; } catch { }
        try { if (SetProcessDPIAware()) return true; } catch { }
        return false;
    }
    /** Physical pixels of the current display mode, or null when the call fails. */
    public static int[] Primary() {
        try {
            DEVMODE dm = new DEVMODE();
            dm.dmSize = (short) Marshal.SizeOf(typeof(DEVMODE));
            if (!EnumDisplaySettingsW(null, -1, ref dm)) return null;
            if (dm.dmPelsWidth <= 0 || dm.dmPelsHeight <= 0) return null;
            return new int[] { dm.dmPelsWidth, dm.dmPelsHeight };
        } catch { return null; }
    }
}
"@
$null = [DshOvDpi]::Apply()

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class DshOv {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr h, int id);
    public const int GWL_EXSTYLE = -20;
    public static void ClickThrough(IntPtr h) {
        int ex = GetWindowLong(h, GWL_EXSTYLE);
        SetWindowLong(h, GWL_EXSTYLE, ex | 0x20 | 0x80 | 0x08000000);
    }
}
"@

$showFile = Join-Path $StateDir 'show.txt'
$muteFile = Join-Path $StateDir 'mute.txt'
$mutedFile = Join-Path $StateDir 'muted.txt'
$quitFile = Join-Path $StateDir 'quit.txt'
$hitFile  = Join-Path $StateDir 'esc.txt'
$logFile  = Join-Path $StateDir 'status.txt'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
function Log([string] $m) {
    try { [System.IO.File]::AppendAllText($logFile, ((Get-Date).ToString('HH:mm:ss.fff') + ' ' + $m + [Environment]::NewLine)) } catch { }
}


# The mutex name is built from the StateDir *string*, so the same directory reached as
# C:\Users\Administrator\... and as C:\Users\ADMINI~1\... yields two mutexes and two
# overlays. A pid file inside the directory closes that hole; the mutex stays because it
# also covers a second copy that starts before this one has written the file.
$instFile = Join-Path $StateDir 'instance.txt'
try {
    $prev = 0
    if (Test-Path -LiteralPath $instFile) { $prev = [int](([System.IO.File]::ReadAllText($instFile)).Trim()) }
    if ($prev -gt 0 -and $prev -ne $PID) {
        $prevProc = Get-Process -Id $prev -ErrorAction SilentlyContinue
        if ($null -ne $prevProc -and $prevProc.ProcessName -match 'powershell') {
            Log ("another overlay (pid " + $prev + ") owns this state dir; exiting")
            exit 0
        }
    }
    [System.IO.File]::WriteAllText($instFile, [string] $PID)
} catch { }

$global:DshOvVsL = [System.Windows.SystemParameters]::VirtualScreenLeft
$global:DshOvVsT = [System.Windows.SystemParameters]::VirtualScreenTop
$vw = [System.Windows.SystemParameters]::VirtualScreenWidth
$vh = [System.Windows.SystemParameters]::VirtualScreenHeight
$unit = [Math]::Min($vw / 1920.0, $vh / 1080.0)
if ($unit -lt 0.75) { $unit = 0.75 }

# This window is laid out in logical units and Windows scales it, which is why the
# caption looks right on a 150% display - but GetCursorPos still answers in *physical*
# pixels. The halo is the one thing placed by that answer, so it needs the ratio back.
# SetProcessDpiAwarenessContext above is a no-op under powershell.exe (its manifest
# settles awareness before the script starts), so measure the ratio instead: the video
# mode is physical, the WPF virtual screen is logical, and the quotient is the scale.
$dpiScale = 1.0
$physW = 0
$physH = 0
$physSource = 'none'
try {
    $mode = [DshOvDpi]::Primary()
    if ($null -ne $mode -and $mode.Count -ge 2) { $physW = [int] $mode[0]; $physH = [int] $mode[1]; $physSource = 'EnumDisplaySettings' }
} catch { }
if ($physW -le 0) {
    try {
        $vc = Get-CimInstance Win32_VideoController -ErrorAction Stop |
            Where-Object { $_.CurrentHorizontalResolution -gt 0 } |
            Select-Object -First 1
        if ($null -ne $vc) { $physW = [int] $vc.CurrentHorizontalResolution; $physH = [int] $vc.CurrentVerticalResolution; $physSource = 'WMI' }
    } catch { }
}
if ($physW -gt 0 -and $vw -gt 0) {
    $ratio = [double] $physW / [double] $vw
    if ($ratio -ge 1.05 -and $ratio -le 4) { $dpiScale = [Math]::Round($ratio, 4) }
}
Log ("screen logical " + $vw + "x" + $vh + ", physical " + $physW + "x" + $physH + " (" + $physSource + "), scale " + $dpiScale)

$coreThickness = [Math]::Max(6, [Math]::Round(8 * $unit))
$glowThickness = [Math]::Max(18, [Math]::Round(36 * $unit))
$blurRadius    = [Math]::Max(18, [Math]::Round(34 * $unit))
$radius        = [Math]::Round(22 * $unit)
$fontSize      = [Math]::Max(30, [Math]::Round(40 * $unit))
$spotD         = [Math]::Round(168 * $unit)
$global:DshOvSpotD = $spotD
$haloD         = [Math]::Round(58 * $unit)

function SB([int] $a, [int] $r, [int] $g, [int] $b) {
    New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb($a, $r, $g, $b))
}

$window = New-Object System.Windows.Window
$window.WindowStyle = 'None'
$window.AllowsTransparency = $true
$window.Background = [System.Windows.Media.Brushes]::Transparent
$window.Topmost = $true
$window.ShowInTaskbar = $false
$window.ShowActivated = $false
$window.ResizeMode = 'NoResize'
$window.Left = $global:DshOvVsL
$window.Top = $global:DshOvVsT
$window.Width = $vw
$window.Height = $vh

$root = New-Object System.Windows.Controls.Grid

# ---- border glow ---------------------------------------------------------
# One ramp, no outline. This is the whole trick from Windows-MCP:
#
#   alpha = 240 * (1 - depth/extent) ** 1.4
#
# Brightest exactly at the screen edge and gone by `extent` px inward. The 1.4
# exponent is what makes it read as light falling on the screen rather than as a
# painted band, and there is deliberately no bright hairline at the edge - a line
# would turn the glow into a frame.
# ---- border glow ---------------------------------------------------------
# Four edge strips, each painted with one LinearGradientBrush running from the colour
# at the screen edge to fully transparent, borderDepth px inward. The first cut used
# sixteen nested rectangles to trace the same ramp and cost about 400 ms of first
# paint on a layered window; four gradient fills cost almost nothing.
#
# The stops are alpha 110 * (1 - d/depth) ** 1.8 sampled four times, which is
# indistinguishable from the per-pixel curve at these depths.
$borderDepth = [Math]::Round(56 * $unit)
$ringGrid = New-Object System.Windows.Controls.Grid
$global:DshOvRing = $ringGrid

function New-EdgeBrush([double] $ax, [double] $ay, [double] $bx, [double] $by) {
    $br = New-Object System.Windows.Media.LinearGradientBrush
    $br.StartPoint = New-Object System.Windows.Point($ax, $ay)
    $br.EndPoint = New-Object System.Windows.Point($bx, $by)
    foreach ($pair in @(@(0.00, 110), @(0.35, 62), @(0.70, 20), @(1.00, 0))) {
        $gs = New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromArgb([int] $pair[1], 205, 242, 255)), ([double] $pair[0])
        $br.GradientStops.Add($gs) | Out-Null
    }
    return $br
}

$edgeSpecs = @(
    @('Stretch', 'Top',    (New-EdgeBrush 0 0 0 1)),
    @('Stretch', 'Bottom', (New-EdgeBrush 0 1 0 0)),
    @('Left',    'Stretch',(New-EdgeBrush 0 0 1 0)),
    @('Right',   'Stretch',(New-EdgeBrush 1 0 0 0))
)
foreach ($spec in $edgeSpecs) {
    $strip = New-Object System.Windows.Shapes.Rectangle
    $strip.Fill = $spec[2]
    $strip.HorizontalAlignment = $spec[0]
    $strip.VerticalAlignment = $spec[1]
    if ($spec[0] -eq 'Stretch') { $strip.Height = [Math]::Round($borderDepth) } else { $strip.Width = [Math]::Round($borderDepth) }
    $ringGrid.Children.Add($strip) | Out-Null
}
$root.Children.Add($ringGrid) | Out-Null


# ---- halo that follows the pointer ---------------------------------------
# Its own window, not a child of the ring window: a child Grid with runtime
# Margin never painted on this layered surface, while a window that is simply
# moved does. Moving a window is also cheaper than re-laying out a full-screen
# visual tree 30 times a second.
$haloWin = New-Object System.Windows.Window
$haloWin.WindowStyle = 'None'
$haloWin.AllowsTransparency = $true
$haloWin.Background = [System.Windows.Media.Brushes]::Transparent
$haloWin.Topmost = $true
$haloWin.ShowInTaskbar = $false
$haloWin.ShowActivated = $false
$haloWin.ResizeMode = 'NoResize'
$haloWin.Width = $spotD
$haloWin.Height = $spotD
$haloWin.Left = -10000
$haloWin.Top = -10000

$halo = New-Object System.Windows.Controls.Grid
$spot = New-Object System.Windows.Shapes.Ellipse
$spot.Width = $spotD
$spot.Height = $spotD
$spotFill = New-Object System.Windows.Media.RadialGradientBrush
# Windows-MCP's aura, sampled: a gaussian falloff with the middle punched out so
# the real arrow stays legible, and no drawn contour at all. A ring reads as a
# target reticle; a falloff reads as light.
$auraStops = @(
    @(0.00, 60),  @(0.07, 140), @(0.17, 245), @(0.34, 190),
    @(0.56, 90),  @(0.80, 26),  @(1.00, 0)
)
foreach ($pair in $auraStops) {
    $gs = New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromArgb([int] $pair[1], 185, 232, 255)), ([double] $pair[0])
    $spotFill.GradientStops.Add($gs) | Out-Null
}
$spot.Fill = $spotFill
$halo.Children.Add($spot) | Out-Null

$haloWin.Content = $halo
$haloWin.Add_SourceInitialized({
    # This window sits exactly where the pointer is. Without WS_EX_TRANSPARENT it
    # eats the very click it is drawn around.
    $hh = (New-Object System.Windows.Interop.WindowInteropHelper($haloWin)).Handle
    [DshOv]::ClickThrough($hh) | Out-Null
}.GetNewClosure())
$global:DshOvHaloWin = $haloWin


# ---- caption panel -------------------------------------------------------
# A dark plate behind the words, with the accent colour bleeding out of its edge
# rather than a black drop shadow. Windows-MCP does the same thing and it is what
# makes a notice look like it belongs ON the screen instead of floating over it.
#
# The two Chinese runs are built from UTF-8 bytes on purpose: this file lost its BOM
# once and PowerShell 5.1 then read the literal as GBK, turning the caption into
# mojibake. Bytes cannot be mis-decoded.
# Windows-MCP sets its notice in Segoe UI Semibold with a Segoe UI hint. Same stack,
# one weight down from Bold - Semibold is the weight Windows uses for its own captions,
# and it is what stops the line from looking stamped on.
$sans = New-Object System.Windows.Media.FontFamily('Segoe UI Variable Display, Segoe UI, Microsoft YaHei UI, Microsoft YaHei')
$capLine1 = [byte[]]@(0x44,0x53,0x48,0x20,0xE6,0xAD,0xA3,0xE5,0x9C,0xA8,0xE6,0x93,0x8D,0xE4,0xBD,0x9C,0xE4,0xBD,0xA0,0xE7,0x9A,0x84,0xE7,0x94,0xB5,0xE8,0x84,0x91)
$capLine2 = [byte[]]@(0xE5,0x8F,0x96,0xE6,0xB6,0x88)

$panel = New-Object System.Windows.Controls.Border
$panel.CornerRadius = New-Object System.Windows.CornerRadius ([Math]::Round(20 * $unit))
# A translucent blue, not a black plate: the desktop has to show through it or the
# panel reads as a hole punched in the screen.
$panelBg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(140, 18, 74, 148))
$panel.Background = $panelBg
$panel.Padding = New-Object System.Windows.Thickness ([Math]::Round(26 * $unit)), ([Math]::Round(12 * $unit)), ([Math]::Round(26 * $unit)), ([Math]::Round(14 * $unit))
$panel.HorizontalAlignment = 'Center'
$panel.VerticalAlignment = 'Top'
$panel.Margin = New-Object System.Windows.Thickness 0, ([Math]::Round(26 * $unit)), 0, 0

# The glow is the panel's own shadow, pulled straight out (ShadowDepth 0) and
# tinted to the accent, so the plate dissolves into the screen edge of the frame.
$panelGlow = New-Object System.Windows.Media.Effects.DropShadowEffect
$panelGlow.Color = [System.Windows.Media.Color]::FromRgb(120, 200, 255)
$panelGlow.ShadowDepth = 0
$panelGlow.BlurRadius = [Math]::Round(22 * $unit)
$panelGlow.Opacity = 0.55
$panel.Effect = $panelGlow
$global:DshOvPanelGlow = $panelGlow

# The plate's edge is a gradient that rotates, so a highlight travels around the
# rounded border. Two passes of light - one bright core, one dim wake - read as a
# sheen rather than as a spinner.
$edgeBrush = New-Object System.Windows.Media.LinearGradientBrush
$edgeBrush.StartPoint = New-Object System.Windows.Point(0, 0)
$edgeBrush.EndPoint = New-Object System.Windows.Point(1, 1)
foreach ($pair in @(@(0.00, 30), @(0.36, 120), @(0.50, 255), @(0.64, 120), @(1.00, 30))) {
    $gs = New-Object System.Windows.Media.GradientStop ([System.Windows.Media.Color]::FromArgb([int] $pair[1], 236, 249, 255)), ([double] $pair[0])
    $edgeBrush.GradientStops.Add($gs) | Out-Null
}
$edgeSpin = New-Object System.Windows.Media.RotateTransform
$edgeSpin.CenterX = 0.5
$edgeSpin.CenterY = 0.5
$edgeSpin.Angle = 0
$edgeBrush.RelativeTransform = $edgeSpin
$global:DshOvEdgeSpin = $edgeSpin
$panel.BorderBrush = $edgeBrush
$panel.BorderThickness = New-Object System.Windows.Thickness 2.6

# ---- the words on the plate ----------------------------------------------
$row = New-Object System.Windows.Controls.Grid
$row.VerticalAlignment = 'Center'
foreach ($w in @('Auto', 'Auto', 'Auto')) {
    $col = New-Object System.Windows.Controls.ColumnDefinition
    $col.Width = New-Object System.Windows.GridLength(0, [System.Windows.GridUnitType]::$w)
    $row.ColumnDefinitions.Add($col) | Out-Null
}

$label = New-Object System.Windows.Controls.TextBlock
$label.Text = [System.Text.Encoding]::UTF8.GetString($capLine1)
$label.FontSize = $fontSize
$label.FontFamily = $sans
$label.FontWeight = [System.Windows.FontWeights]::SemiBold
$label.Foreground = [System.Windows.Media.Brushes]::White
$label.VerticalAlignment = 'Center'
[System.Windows.Controls.Grid]::SetColumn($label, 0)
$row.Children.Add($label) | Out-Null

$keyWrap = New-Object System.Windows.Controls.Border
$keyWrap.CornerRadius = New-Object System.Windows.CornerRadius ([Math]::Round(6 * $unit))
$keyWrap.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(170, 8, 34, 76))
$keyWrap.BorderBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(130, 255, 255, 255))
$keyWrap.BorderThickness = New-Object System.Windows.Thickness 1
$keyWrap.Padding = New-Object System.Windows.Thickness ([Math]::Round(9 * $unit)), ([Math]::Round(1 * $unit)), ([Math]::Round(9 * $unit)), ([Math]::Round(2 * $unit))
$keyWrap.Margin = New-Object System.Windows.Thickness ([Math]::Round(16 * $unit)), 0, ([Math]::Round(10 * $unit)), 0
$keyWrap.VerticalAlignment = 'Center'
[System.Windows.Controls.Grid]::SetColumn($keyWrap, 1)
$keyText = New-Object System.Windows.Controls.TextBlock
$keyText.Text = 'Esc'
$keyText.FontSize = [Math]::Round($fontSize * 0.82)
$keyText.FontFamily = $sans
$keyText.FontWeight = [System.Windows.FontWeights]::SemiBold
$keyText.Foreground = [System.Windows.Media.Brushes]::White
$keyWrap.Child = $keyText
$row.Children.Add($keyWrap) | Out-Null

$label2 = New-Object System.Windows.Controls.TextBlock
$label2.Text = [System.Text.Encoding]::UTF8.GetString($capLine2)
$label2.FontSize = $fontSize
$label2.FontFamily = $sans
$label2.FontWeight = [System.Windows.FontWeights]::SemiBold
$label2.Foreground = [System.Windows.Media.Brushes]::White
$label2.Opacity = 0.82
$label2.VerticalAlignment = 'Center'
[System.Windows.Controls.Grid]::SetColumn($label2, 2)
$row.Children.Add($label2) | Out-Null

$panel.Child = $row
$global:DshOvPanel = $panel
$root.Children.Add($panel) | Out-Null
$global:DshOvPanel = $panel
$global:DshOvRow = $row

$window.Content = $root

$global:DshOvHwnd = [IntPtr]::Zero
$global:DshOvCancelTarget = ''
$global:DshOvStoppedFor = ''
$global:DshOvHotkeyOn = $false

function Enable-Hotkey {
    if ($global:DshOvHotkeyOn -or $global:DshOvHwnd -eq [IntPtr]::Zero) { return }
    $global:DshOvHotkeyOn = [DshOv]::RegisterHotKey($global:DshOvHwnd, 1, 0, 0x1B)
}
function Disable-Hotkey {
    if (-not $global:DshOvHotkeyOn -or $global:DshOvHwnd -eq [IntPtr]::Zero) { return }
    [DshOv]::UnregisterHotKey($global:DshOvHwnd, 1) | Out-Null
    $global:DshOvHotkeyOn = $false
}

function Stop-Takeover {
    $global:DshOvStoppedFor = $global:DshOvCancelTarget
    if ($global:DshOvCancelTarget -ne '') {
        try { [System.IO.File]::WriteAllText($global:DshOvCancelTarget, 'stop', [System.Text.Encoding]::UTF8) } catch { }
    }
    try { [System.IO.File]::WriteAllText($hitFile, (Get-Date).ToString('o'), [System.Text.Encoding]::UTF8) } catch { }
    if ($window.IsVisible) { $window.Hide(); Disable-Hotkey }
    $global:DshOvCancelTarget = ''
}

$script:haloErrors = 0
function Update-Halo {
    # Removed on purpose. A window that has to poll GetCursorPos and be moved every
    # 16 ms trails the real pointer by one or two frames no matter how fast the loop
    # runs, and a lagging second cursor is what made the takeover feel heavy. The
    # pointer itself is enlarged through the Windows setting instead.
    return

    # No latching. A failed GetCursorPos (the desktop can be mid-switch between a
    # locked and an active session) used to disable the halo for the rest of the
    # process - which is exactly "it worked at first and then stopped".
    try {
        # The nested struct has to be named, not written as DshOv+POINT: unquoted,
        # PowerShell reads the plus as arithmetic and the call throws on every tick.
        $p = [DshOv+POINT]::new()
        # A frozen position makes the halo verifiable without racing a human hand.
        $freeze = Join-Path $StateDir 'freeze.txt'
        $fx = $null
        if (Test-Path -LiteralPath $freeze) {
            try {
                $parts = ([System.IO.File]::ReadAllText($freeze)).Trim() -split ','
                if ($parts.Count -ge 2) { $fx = @([int] $parts[0], [int] $parts[1]) }
            } catch { }
        }
        $ok = $false
        if ($null -ne $fx) { $p.X = $fx[0]; $p.Y = $fx[1]; $ok = $true } else { $ok = [DshOv]::GetCursorPos([ref] $p) }
        if ($ok) {
            $h = $global:DshOvHaloWin
            if ($null -eq $h) { if (-not $script:haloLogged) { $script:haloLogged = $true; Log 'halo missing' }; return }
            # Cursor pixels are physical; this window's coordinates are logical.
            $lx = $p.X / $dpiScale
            $ly = $p.Y / $dpiScale
            $h.Left = $lx - ($global:DshOvSpotD / 2)
            $h.Top = $ly - ($global:DshOvSpotD / 2)
            $script:haloMoves = [int] $script:haloMoves + 1
            if ($script:haloMoves -le 3 -or ($script:haloMoves % 40) -eq 0) {
                Log ("halo move " + $script:haloMoves + " -> " + $p.X + "," + $p.Y + " at " + [int]$lx + "," + [int]$ly + " margin=" + $h.Margin.Left + "," + $h.Margin.Top)
            }
        }
    } catch {
        $script:haloErrors++
        if ($script:haloErrors -le 3 -or ($script:haloErrors % 300) -eq 0) {
            Log ("halo error " + $script:haloErrors + ": " + $_.Exception.Message)
        }
    }
}

function Update-State {
    # A capture must not contain the overlay. The host drops mute.txt, waits for
    # muted.txt (so it cannot shoot a frame mid-hide), takes the picture, then removes
    # both files - the same handshake Windows-MCP uses.
    if (Test-Path -LiteralPath $muteFile) {
        if ($window.IsVisible) {
            $window.Hide()
            if ($null -ne $global:DshOvHaloWin -and $global:DshOvHaloWin.IsVisible) { $global:DshOvHaloWin.Hide() }
            Log 'muted for capture'
        }
        if (-not (Test-Path -LiteralPath $mutedFile)) { Set-Content -LiteralPath $mutedFile -Value '1' -Encoding ASCII }
        return
    }
    if (Test-Path -LiteralPath $mutedFile) { Remove-Item -LiteralPath $mutedFile -Force -ErrorAction SilentlyContinue }
    $show = Test-Path -LiteralPath $showFile
    if ($show) {
        $raw = ''
        try { $raw = [System.IO.File]::ReadAllText($showFile, [System.Text.Encoding]::UTF8).Trim() } catch { }
        if ($raw -eq $global:DshOvStoppedFor) { $show = $false } else { $global:DshOvCancelTarget = $raw }
    }
    if ($show) {
        $global:DshOvMissTicks = 0
        # A remote session renegotiates its resolution while the overlay is already up,
        # which used to leave a 1080p window on a 1024p desktop and push the caption past
        # the right edge. Checking once a second is enough for that and costs nothing on a
        # machine whose resolution never moves - a local desktop is settled before show.
        $global:DshOvRefit = $global:DshOvRefit + 1
        if ($window.IsVisible -and $global:DshOvRefit -ge 60) {
            $global:DshOvRefit = 0
            $vwNow = [System.Windows.SystemParameters]::VirtualScreenWidth
            $vhNow = [System.Windows.SystemParameters]::VirtualScreenHeight
            if ($window.Width -ne $vwNow -or $window.Height -ne $vhNow) {
                $window.Width = $vwNow
                $window.Height = $vhNow
                $window.Left = [System.Windows.SystemParameters]::VirtualScreenLeft
                $window.Top = [System.Windows.SystemParameters]::VirtualScreenTop
                Log ("refit " + $vwNow + "x" + $vhNow)
            }
        }
        if (-not $window.IsVisible) {
            # The desktop can change size between shows (a reconnect, a display mode
            # switch); re-fit rather than draw a 1080p ring on a 1600p desktop.
            $w = [System.Windows.SystemParameters]::VirtualScreenWidth
            $h = [System.Windows.SystemParameters]::VirtualScreenHeight
            if ($window.Width -ne $w -or $window.Height -ne $h) {
                $window.Left = [System.Windows.SystemParameters]::VirtualScreenLeft
                $window.Top = [System.Windows.SystemParameters]::VirtualScreenTop
                $window.Width = $w
                $window.Height = $h
            }
            $window.Show(); Enable-Hotkey
            $global:DshOvBreath = [Environment]::TickCount
            $global:DshOvRefit = 0
            # The halo is deliberately never shown (see Update-Halo).
            Log ("shown " + $w + "x" + $h)
            Log ("panel " + [Math]::Round($global:DshOvPanel.ActualWidth) + "x" + [Math]::Round($global:DshOvPanel.ActualHeight) + "  row " + [Math]::Round($global:DshOvRow.ActualWidth))
        }
        # A three-second breath, the curve Windows-MCP uses, but with a wider swing:
        # at 0.42 the border barely changed because its peak alpha is already only 150.
        # Down to 0.12 the dark phase nearly disappears, which is what makes the pulse
        # readable at a glance.
        #
        # It is re-applied every fourth tick, not every tick: changing the opacity of a
        # Grid holding 56 full-screen rectangles forces a re-composite, and doing that at
        # 30 Hz pushed the tick interval from 33 ms to 47 ms - which showed up as the
        # cursor halo lagging behind the pointer. A 3 s curve sampled at 7.5 Hz is smooth.
        $script:breathTick = $script:breathTick + 1
        if (($script:breathTick % 8) -eq 1) {
            if ($global:DshOvBreath -eq 0) { $global:DshOvBreath = [Environment]::TickCount }
            $secs = ([Environment]::TickCount - $global:DshOvBreath) / 1000.0
            $breath = (1 + [Math]::Cos(2 * [Math]::PI * $secs / 3.0)) / 2
            # The plate's own light breathes; the screen edge stays steady, because a
            # pulsing frame around the whole display reads as a warning light, not as
            # something considered.
            if ($null -ne $global:DshOvPanelGlow) { $global:DshOvPanelGlow.Opacity = 0.30 + 0.45 * $breath }
        }
        if ($null -ne $global:DshOvEdgeSpin) { $global:DshOvEdgeSpin.Angle = ($global:DshOvEdgeSpin.Angle + 2.6) % 360 }
        Update-Halo
    } elseif ($window.IsVisible) {
        $global:DshOvBreath = 0
        # One failed stat is not "the host hid me". The host rewrites this file at the
        # start of every action with a truncating write, and a Test-Path that lands in
        # that window reads false - hiding on it produced a flash per action. Waiting
        # two more ticks absorbs the write and still hides promptly (the host's own
        # linger is `takeoverLingerMs`, eight seconds by default).
        $global:DshOvMissTicks++
        if ($global:DshOvMissTicks -lt 3) { return }
        $window.Hide()
        $global:DshOvMissTicks = 0
        Log 'hidden'
        if ($global:DshOvHaloWin.IsVisible) { $global:DshOvHaloWin.Hide() }
        Disable-Hotkey
        $global:DshOvCancelTarget = ''
    }
    if (Test-Path -LiteralPath $quitFile) { $window.Close() }
}

$window.Add_SourceInitialized({
    $global:DshOvHwnd = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
    [DshOv]::ClickThrough($global:DshOvHwnd) | Out-Null
    $source = [System.Windows.Interop.HwndSource]::FromHwnd($global:DshOvHwnd)
    $source.AddHook([System.Windows.Interop.HwndSourceHook]{
        param($msgHwnd, $msg, $wParam, $lParam, [ref] $handled)
        if ($msg -eq 0x0312 -and [int] $wParam -eq 1) { Stop-Takeover; $handled.Value = $true }
        return [IntPtr]::Zero
    })
}.GetNewClosure())

$haloWin.Add_Closed({ })
$window.Add_Closed({
    if ($global:DshOvHaloWin.IsVisible) { $global:DshOvHaloWin.Close() }
    if ($global:DshOvHwnd -ne [IntPtr]::Zero) { [DshOv]::UnregisterHotKey($global:DshOvHwnd, 1) | Out-Null }
})

# No parent watch: a host that dies leaves no trace to watch, and a false positive
# kills the ring the moment the launcher is a short-lived shell. An idle timeout
# bounds the leftover process without ever firing while it is in use.
$global:DshOvTicks = 0
$global:DshOvMissTicks = 0
$global:DshOvIdleTicks = 0

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(16)
$timer.Add_Tick({
    # A throw here used to be swallowed by the dispatcher: the overlay stayed visible
    # and simply stopped updating, which looks exactly like a frozen halo.
    try { Update-State } catch { if (-not $script:tickErrLogged) { $script:tickErrLogged = $true; Log ('TICK ERROR: ' + $_.Exception.Message + ' @ ' + $_.InvocationInfo.ScriptLineNumber) } }
    $global:DshOvTicks++
    if ($window.IsVisible) { $global:DshOvIdleTicks = 0 } else { $global:DshOvIdleTicks++ }
    # 33 ms * 18000 = ~10 minutes hidden before the process gives the memory back.
    if ($global:DshOvIdleTicks -gt 18000) { $window.Close() }
})
$timer.Start()

# Create the handle and strip activation BEFORE the first Show. Applying the
# extended style from SourceInitialized is too late: Windows has already offered
# the window the foreground by then, and a topmost window that takes focus breaks
# the very actions it is drawn for.
$pre = New-Object System.Windows.Interop.WindowInteropHelper($window)
$preHwnd = $pre.EnsureHandle()
[DshOv]::ClickThrough($preHwnd) | Out-Null
$preHalo = New-Object System.Windows.Interop.WindowInteropHelper($haloWin)
$preHaloHwnd = $preHalo.EnsureHandle()
[DshOv]::ClickThrough($preHaloHwnd) | Out-Null

# No startup Show/Hide: the handles already exist (EnsureHandle above), and showing
# then hiding here races the timer's first real Show - the overlay would log two
# shows for the first action, which is the flicker this scene is trying to remove.
[System.Windows.Threading.Dispatcher]::Run()
