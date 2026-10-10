using System;
using System.Runtime.InteropServices;

namespace WindowsButtonE2E
{
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public UIntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public UIntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit, Size = 32)]
    public struct INPUTUNION
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public INPUTUNION U; }

    public sealed class InputResult
    {
        public uint Requested;
        public uint Inserted;
        public int LastError;
        public int InputSize;
    }

    public sealed class DesktopResult
    {
        public bool Success;
        public string Name;
        public int LastError;
    }

    public static class Win32
    {
        private const uint INPUT_MOUSE = 0;
        private const uint INPUT_KEYBOARD = 1;
        private const uint KEYEVENTF_KEYUP = 0x0002;
        private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
        private const uint MOUSEEVENTF_LEFTUP = 0x0004;
        private const uint WM_CLOSE = 0x0010;
        private const uint DESKTOP_READOBJECTS = 0x0001;
        private const int UOI_NAME = 2;

        private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true)] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll", SetLastError = true)] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
        [DllImport("user32.dll", SetLastError = true)] private static extern bool IsWindow(IntPtr hwnd);
        [DllImport("user32.dll", SetLastError = true)] private static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassNameW(IntPtr hwnd, System.Text.StringBuilder className, int maxCount);
        [DllImport("user32.dll", SetLastError = true)] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
        [DllImport("user32.dll", SetLastError = true)] public static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
        [DllImport("user32.dll", SetLastError = true)] public static extern bool ClientToScreen(IntPtr hwnd, ref POINT point);
        [DllImport("user32.dll", SetLastError = true)] private static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
        [DllImport("user32.dll", SetLastError = true)] private static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll", SetLastError = true)] private static extern bool PostMessageW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, INPUT[] inputs, int size);
        [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr OpenInputDesktop(uint flags, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint access);
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] private static extern bool GetUserObjectInformationW(IntPtr handle, int index, System.Text.StringBuilder info, int length, out int needed);
        [DllImport("user32.dll")] private static extern bool CloseDesktop(IntPtr desktop);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll", SetLastError = true)] public static extern bool SetForegroundWindow(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);

        public static int InputStructureSize() { return Marshal.SizeOf(typeof(INPUT)); }

        public static DesktopResult CheckInputDesktop()
        {
            DesktopResult result = new DesktopResult();
            IntPtr desktop = OpenInputDesktop(0, false, DESKTOP_READOBJECTS);
            if (desktop == IntPtr.Zero)
            {
                result.Success = false;
                result.Name = null;
                result.LastError = Marshal.GetLastWin32Error();
                return result;
            }
            try
            {
                System.Text.StringBuilder name = new System.Text.StringBuilder(512);
                int needed;
                result.Success = GetUserObjectInformationW(desktop, UOI_NAME, name, name.Capacity * 2, out needed);
                result.Name = result.Success ? name.ToString() : null;
                result.LastError = result.Success ? 0 : Marshal.GetLastWin32Error();
                return result;
            }
            finally { CloseDesktop(desktop); }
        }

        public static long FindWindow(int expectedPid)
        {
            IntPtr found = IntPtr.Zero;
            EnumWindowsProc callback = delegate(IntPtr hwnd, IntPtr ignored)
            {
                uint pid;
                GetWindowThreadProcessId(hwnd, out pid);
                System.Text.StringBuilder name = new System.Text.StringBuilder(256);
                int length = GetClassNameW(hwnd, name, name.Capacity);
                if (pid == (uint)expectedPid && IsWindowVisible(hwnd) && length > 0 &&
                    String.Equals(name.ToString(), "gpui_mbt_windows_host_v1", StringComparison.Ordinal))
                {
                    if (found != IntPtr.Zero) throw new InvalidOperationException("More than one visible GPUI HWND exists under the owned process.");
                    found = hwnd;
                }
                return true;
            };
            EnumWindows(callback, IntPtr.Zero);
            GC.KeepAlive(callback);
            return found.ToInt64();
        }

        public static bool IsOwnedWindow(long handle, int expectedPid)
        {
            IntPtr hwnd = new IntPtr(handle);
            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            return IsWindow(hwnd) && IsWindowVisible(hwnd) && pid == (uint)expectedPid &&
                String.Equals(GetClassName(hwnd), "gpui_mbt_windows_host_v1", StringComparison.Ordinal);
        }

        private static string GetClassName(IntPtr hwnd)
        {
            System.Text.StringBuilder name = new System.Text.StringBuilder(256);
            int length = GetClassNameW(hwnd, name, name.Capacity);
            return length > 0 ? name.ToString() : String.Empty;
        }

        public static bool ResizeClient(long handle, int width, int height)
        {
            IntPtr hwnd = new IntPtr(handle);
            RECT outer, client;
            if (!GetWindowRect(hwnd, out outer) || !GetClientRect(hwnd, out client)) return false;
            int frameWidth = (outer.Right - outer.Left) - (client.Right - client.Left);
            int frameHeight = (outer.Bottom - outer.Top) - (client.Bottom - client.Top);
            return SetWindowPos(hwnd, IntPtr.Zero, 0, 0, width + frameWidth, height + frameHeight, 0x0002 | 0x0004);
        }

        public static bool MovePointer(long handle, double logicalX, double logicalY, double scale)
        {
            IntPtr hwnd = new IntPtr(handle);
            if (Double.IsNaN(scale) || Double.IsInfinity(scale) || scale <= 0.0) return false;
            POINT point = new POINT { X = (int)Math.Round(logicalX * scale), Y = (int)Math.Round(logicalY * scale) };
            if (!ClientToScreen(hwnd, ref point)) return false;
            return SetCursorPos(point.X, point.Y);
        }

        public static InputResult SendKey(ushort virtualKey, bool keyUp)
        {
            INPUT input = new INPUT();
            input.type = INPUT_KEYBOARD;
            input.U.ki.wVk = virtualKey;
            input.U.ki.dwFlags = keyUp ? KEYEVENTF_KEYUP : 0;
            return SendOne(input);
        }

        public static InputResult SendMouse(bool buttonUp)
        {
            INPUT input = new INPUT();
            input.type = INPUT_MOUSE;
            input.U.mi.dwFlags = buttonUp ? MOUSEEVENTF_LEFTUP : MOUSEEVENTF_LEFTDOWN;
            return SendOne(input);
        }

        private static InputResult SendOne(INPUT input)
        {
            INPUT[] inputs = new INPUT[] { input };
            InputResult result = new InputResult();
            result.Requested = 1;
            result.InputSize = InputStructureSize();
            result.Inserted = SendInput(1, inputs, result.InputSize);
            result.LastError = Marshal.GetLastWin32Error();
            return result;
        }

        public static bool CloseOwnedWindow(long handle, int expectedPid)
        {
            IntPtr hwnd = new IntPtr(handle);
            if (!IsOwnedWindow(handle, expectedPid)) return false;
            return PostMessageW(hwnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
        }
    }
}
