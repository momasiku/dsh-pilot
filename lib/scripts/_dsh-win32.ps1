# pilot / _dsh-win32.ps1 - the Win32 bridge and per-monitor DPI awareness, shared
# by the one-shot scripts and by the persistent worker.
#
# Every block is idempotent: a process that already has the type does not compile
# it again, so the same file can be dot-sourced by several entry points.
$ErrorActionPreference = 'Stop'

if (-not ('DshInput' -as [type])) {
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
}

if (-not ('DshProbe' -as [type])) {
# ---------------------------------------------------------------- Win32 bridge
$nativeSource = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class DshProbe {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);

    public static bool BecomeDpiAware() {
        try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return true; } catch {}
        try { if (SetProcessDpiAwareness(2) == 0) return true; } catch {}
        try { if (SetProcessDPIAware()) return true; } catch {}
        return false;
    }
    public static RECT WindowRect(IntPtr h) { RECT r; GetWindowRect(h, out r); return r; }
    public static POINT Cursor() { POINT p; GetCursorPos(out p); return p; }
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
}
'@
$null = Add-Type -TypeDefinition $nativeSource -Language CSharp
$null = [DshProbe]::BecomeDpiAware()
}