using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace PaletteE2E
{
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

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
    public struct INPUT
    {
        public uint type;
        public INPUTUNION U;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct CANDIDATEFORM
    {
        public uint dwIndex;
        public uint dwStyle;
        public POINT ptCurrentPos;
        public RECT rcArea;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    internal struct BITMAPFILEHEADER
    {
        public ushort bfType;
        public uint bfSize;
        public ushort bfReserved1;
        public ushort bfReserved2;
        public uint bfOffBits;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct BITMAPINFOHEADER
    {
        public uint biSize;
        public int biWidth;
        public int biHeight;
        public ushort biPlanes;
        public ushort biBitCount;
        public uint biCompression;
        public uint biSizeImage;
        public int biXPelsPerMeter;
        public int biYPelsPerMeter;
        public uint biClrUsed;
        public uint biClrImportant;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct BITMAPINFO
    {
        public BITMAPINFOHEADER bmiHeader;
        public uint bmiColors;
    }

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

    public sealed class ImeResult
    {
        public bool HasContext;
        public bool Open;
        public bool ConversionValid;
        public uint ConversionMode;
        public uint SentenceMode;
    }

    public sealed class CandidateResult
    {
        public bool HasContext;
        public bool QuerySucceeded;
        public int LastError;
        public uint Index;
        public uint Style;
        public int X;
        public int Y;
        public RECT Area;
    }

    public sealed class WindowRecord
    {
        public long Handle;
        public uint ProcessId;
        public uint ThreadId;
        public bool Visible;
        public string Title;
        public string ClassName;
        public RECT Bounds;
    }

    public sealed class CaptureResult
    {
        public bool Success;
        public int LastError;
        public string ErrorText;
        public int Width;
        public int Height;
        public long Bytes;
    }

    public sealed class ProcessImagePathResult
    {
        public bool Success;
        public int LastError;
        public string Path;
    }

    public static class Win32
    {
        private const uint DESKTOP_READOBJECTS = 0x0001;
        private const int UOI_NAME = 2;
        private const uint INPUT_KEYBOARD = 1;
        private const uint KEYEVENTF_KEYUP = 0x0002;
        private const uint SRCCOPY = 0x00CC0020;
        private const uint CAPTUREBLT = 0x40000000;
        private const uint BI_RGB = 0;
        private const uint DIB_RGB_COLORS = 0;
        private const uint WM_CLOSE = 0x0010;
        private const uint WM_INPUTLANGCHANGEREQUEST = 0x0050;
        private const uint SMTO_ABORTIFHUNG = 0x0002;
        private const uint IMC_GETCANDIDATEPOS = 0x0007;
        private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

        private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr OpenInputDesktop(uint flags, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint access);
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool GetUserObjectInformationW(IntPtr hObj, int index, StringBuilder info, int length, out int needed);
        [DllImport("user32.dll")]
        private static extern bool CloseDesktop(IntPtr hDesktop);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr dpiContext);
        [DllImport("user32.dll")]
        public static extern uint GetDpiForWindow(IntPtr hwnd);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
        [DllImport("user32.dll", SetLastError = true)]
        public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
        [DllImport("user32.dll")]
        public static extern bool IsWindow(IntPtr hwnd);
        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")]
        public static extern bool IsIconic(IntPtr hwnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowTextW(IntPtr hwnd, StringBuilder text, int maxCount);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassNameW(IntPtr hwnd, StringBuilder className, int maxCount);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, uint processId);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool QueryFullProcessImageNameW(IntPtr process, uint flags, StringBuilder imagePath, ref int size);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool ClientToScreen(IntPtr hwnd, ref POINT point);
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SetForegroundWindow(IntPtr hwnd);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SendMessageTimeoutW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool PostMessageW(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint SendInput(uint count, INPUT[] inputs, int size);
        [DllImport("user32.dll")]
        public static extern short GetAsyncKeyState(int virtualKey);
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern IntPtr LoadKeyboardLayoutW(string klid, uint flags);
        [DllImport("user32.dll")]
        public static extern IntPtr GetKeyboardLayout(uint threadId);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern int GetKeyboardLayoutList(int count, [Out] IntPtr[] layouts);
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool UnloadKeyboardLayout(IntPtr hkl);
        [DllImport("user32.dll")]
        public static extern int GetSystemMetrics(int index);

        [DllImport("imm32.dll", SetLastError = true)]
        private static extern IntPtr ImmGetContext(IntPtr hwnd);
        [DllImport("imm32.dll", SetLastError = true)]
        private static extern bool ImmReleaseContext(IntPtr hwnd, IntPtr context);
        [DllImport("imm32.dll")]
        private static extern bool ImmGetOpenStatus(IntPtr context);
        [DllImport("imm32.dll")]
        private static extern bool ImmSetOpenStatus(IntPtr context, bool open);
        [DllImport("imm32.dll", SetLastError = true)]
        private static extern bool ImmGetConversionStatus(IntPtr context, out uint conversion, out uint sentence);
        [DllImport("imm32.dll", SetLastError = true)]
        private static extern bool ImmSetConversionStatus(IntPtr context, uint conversion, uint sentence);
        [DllImport("imm32.dll", SetLastError = true)]
        private static extern bool ImmGetCandidateWindow(IntPtr context, uint index, ref CANDIDATEFORM form);
        [DllImport("imm32.dll")]
        public static extern bool ImmIsIME(IntPtr hkl);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr GetDC(IntPtr hwnd);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern int ReleaseDC(IntPtr hwnd, IntPtr dc);
        [DllImport("gdi32.dll", SetLastError = true)]
        private static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32.dll", SetLastError = true)]
        private static extern IntPtr CreateCompatibleBitmap(IntPtr dc, int width, int height);
        [DllImport("gdi32.dll", SetLastError = true)]
        private static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
        [DllImport("gdi32.dll", SetLastError = true)]
        private static extern bool DeleteObject(IntPtr obj);
        [DllImport("gdi32.dll", SetLastError = true)]
        private static extern bool DeleteDC(IntPtr dc);
        [DllImport("gdi32.dll", SetLastError = true)]
        private static extern bool BitBlt(IntPtr destination, int x, int y, int width, int height, IntPtr source, int sourceX, int sourceY, uint rasterOp);
        [DllImport("gdi32.dll", SetLastError = true)]
        private static extern int GetDIBits(IntPtr dc, IntPtr bitmap, uint startScan, uint scanLines, [Out] byte[] bits, ref BITMAPINFO info, uint usage);
        [DllImport("dwmapi.dll", SetLastError = true)]
        public static extern int DwmFlush();

        public static int InputStructureSize()
        {
            return Marshal.SizeOf(typeof(INPUT));
        }

        public static ProcessImagePathResult QueryProcessImagePath(uint processId)
        {
            ProcessImagePathResult result = new ProcessImagePathResult();
            IntPtr process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
            if (process == IntPtr.Zero)
            {
                result.Success = false;
                result.LastError = Marshal.GetLastWin32Error();
                result.Path = null;
                return result;
            }
            try
            {
                StringBuilder path = new StringBuilder(32768);
                int size = path.Capacity;
                result.Success = QueryFullProcessImageNameW(process, 0, path, ref size);
                result.LastError = result.Success ? 0 : Marshal.GetLastWin32Error();
                result.Path = result.Success ? path.ToString() : null;
                return result;
            }
            finally
            {
                CloseHandle(process);
            }
        }

        public static string GetWindowClassName(IntPtr hwnd)
        {
            StringBuilder className = new StringBuilder(256);
            int length = GetClassNameW(hwnd, className, className.Capacity);
            return length > 0 ? className.ToString() : String.Empty;
        }
        public static IntPtr[] LoadedKeyboardLayouts()
        {
            int count = GetKeyboardLayoutList(0, null);
            if (count <= 0)
                return new IntPtr[0];
            IntPtr[] layouts = new IntPtr[count];
            int actual = GetKeyboardLayoutList(layouts.Length, layouts);
            if (actual <= 0)
                return new IntPtr[0];
            if (actual == layouts.Length)
                return layouts;
            Array.Resize(ref layouts, actual);
            return layouts;
        }

        public static DesktopResult CheckInputDesktop()
        {
            DesktopResult result = new DesktopResult();
            IntPtr desktop = OpenInputDesktop(0, false, DESKTOP_READOBJECTS);
            if (desktop == IntPtr.Zero)
            {
                result.Success = false;
                result.LastError = Marshal.GetLastWin32Error();
                result.Name = null;
                return result;
            }
            try
            {
                StringBuilder name = new StringBuilder(512);
                int needed;
                if (!GetUserObjectInformationW(desktop, UOI_NAME, name, name.Capacity * 2, out needed))
                {
                    result.Success = false;
                    result.LastError = Marshal.GetLastWin32Error();
                    result.Name = null;
                    return result;
                }
                result.Success = true;
                result.LastError = 0;
                result.Name = name.ToString();
                return result;
            }
            finally
            {
                CloseDesktop(desktop);
            }
        }

        public static WindowRecord[] VisibleWindows()
        {
            List<WindowRecord> windows = new List<WindowRecord>();
            EnumWindowsProc callback = delegate(IntPtr hwnd, IntPtr ignored)
            {
                uint pid;
                uint tid = GetWindowThreadProcessId(hwnd, out pid);
                StringBuilder title = new StringBuilder(512);
                StringBuilder className = new StringBuilder(256);
                GetWindowTextW(hwnd, title, title.Capacity);
                GetClassNameW(hwnd, className, className.Capacity);
                RECT bounds;
                if (!GetWindowRect(hwnd, out bounds))
                    bounds = new RECT();
                windows.Add(new WindowRecord
                {
                    Handle = hwnd.ToInt64(),
                    ProcessId = pid,
                    ThreadId = tid,
                    Visible = IsWindowVisible(hwnd),
                    Title = title.ToString(),
                    ClassName = className.ToString(),
                    Bounds = bounds
                });
                return true;
            };
            EnumWindows(callback, IntPtr.Zero);
            GC.KeepAlive(callback);
            return windows.ToArray();
        }

        public static InputResult SendEvents(ushort[] virtualKeys, bool[] keyUps)
        {
            InputResult result = new InputResult();
            if (virtualKeys == null || keyUps == null || virtualKeys.Length != keyUps.Length)
            {
                result.Requested = 0;
                result.Inserted = 0;
                result.LastError = 87;
                result.InputSize = InputStructureSize();
                return result;
            }
            INPUT[] inputs = new INPUT[virtualKeys.Length];
            for (int i = 0; i < virtualKeys.Length; i++)
            {
                inputs[i].type = INPUT_KEYBOARD;
                inputs[i].U.ki.wVk = virtualKeys[i];
                inputs[i].U.ki.wScan = 0;
                inputs[i].U.ki.dwFlags = keyUps[i] ? KEYEVENTF_KEYUP : 0;
                inputs[i].U.ki.time = 0;
                inputs[i].U.ki.dwExtraInfo = UIntPtr.Zero;
            }
            result.Requested = (uint)inputs.Length;
            result.InputSize = InputStructureSize();
            result.Inserted = SendInput(result.Requested, inputs, result.InputSize);
            result.LastError = Marshal.GetLastWin32Error();
            return result;
        }

        public static ImeResult QueryIme(IntPtr hwnd)
        {
            ImeResult result = new ImeResult();
            IntPtr context = ImmGetContext(hwnd);
            if (context == IntPtr.Zero)
                return result;
            try
            {
                result.HasContext = true;
                result.Open = ImmGetOpenStatus(context);
                result.ConversionValid = ImmGetConversionStatus(context, out result.ConversionMode, out result.SentenceMode);
                return result;
            }
            finally
            {
                ImmReleaseContext(hwnd, context);
            }
        }

        public static bool RestoreIme(IntPtr hwnd, bool open, bool conversionValid, uint conversionMode, uint sentenceMode, out int lastError)
        {
            lastError = 0;
            IntPtr context = ImmGetContext(hwnd);
            if (context == IntPtr.Zero)
            {
                lastError = Marshal.GetLastWin32Error();
                return false;
            }
            try
            {
                bool openOk = ImmSetOpenStatus(context, open);
                bool conversionOk = !conversionValid || ImmSetConversionStatus(context, conversionMode, sentenceMode);
                if (!openOk || !conversionOk)
                {
                    lastError = Marshal.GetLastWin32Error();
                    return false;
                }
                return true;
            }
            finally
            {
                ImmReleaseContext(hwnd, context);
            }
        }

        public static CandidateResult QueryCandidate(IntPtr hwnd, uint index)
        {
            CandidateResult result = new CandidateResult();
            IntPtr context = ImmGetContext(hwnd);
            if (context == IntPtr.Zero)
            {
                result.LastError = Marshal.GetLastWin32Error();
                return result;
            }
            try
            {
                result.HasContext = true;
                CANDIDATEFORM form = new CANDIDATEFORM();
                bool ok = ImmGetCandidateWindow(context, index, ref form);
                result.QuerySucceeded = ok;
                result.LastError = ok ? 0 : Marshal.GetLastWin32Error();
                result.Index = form.dwIndex;
                result.Style = form.dwStyle;
                result.X = form.ptCurrentPos.X;
                result.Y = form.ptCurrentPos.Y;
                result.Area = form.rcArea;
                return result;
            }
            finally
            {
                ImmReleaseContext(hwnd, context);
            }
        }

        public static bool RequestInputLanguage(IntPtr hwnd, IntPtr hkl, out int lastError)
        {
            lastError = 0;
            bool ok = PostMessageW(hwnd, WM_INPUTLANGCHANGEREQUEST, IntPtr.Zero, hkl);
            if (!ok)
                lastError = Marshal.GetLastWin32Error();
            return ok;
        }

        public static bool SendClose(IntPtr hwnd, uint timeoutMilliseconds, out int lastError)
        {
            IntPtr result;
            IntPtr call = SendMessageTimeoutW(hwnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero, SMTO_ABORTIFHUNG, timeoutMilliseconds, out result);
            if (call == IntPtr.Zero)
            {
                lastError = Marshal.GetLastWin32Error();
                return false;
            }
            lastError = 0;
            return true;
        }

        public static bool CaptureScreenRect(string path, int x, int y, int width, int height, out CaptureResult result)
        {
            result = new CaptureResult();
            result.Width = width;
            result.Height = height;
            if (width <= 0 || height <= 0 || (long)width * height * 4 > Int32.MaxValue)
            {
                result.Success = false;
                result.LastError = 87;
                return false;
            }
            IntPtr screen = GetDC(IntPtr.Zero);
            if (screen == IntPtr.Zero)
            {
                result.Success = false;
                result.LastError = Marshal.GetLastWin32Error();
                return false;
            }
            IntPtr memory = IntPtr.Zero;
            IntPtr bitmap = IntPtr.Zero;
            IntPtr prior = IntPtr.Zero;
            try
            {
                memory = CreateCompatibleDC(screen);
                bitmap = CreateCompatibleBitmap(screen, width, height);
                if (memory == IntPtr.Zero || bitmap == IntPtr.Zero)
                {
                    result.Success = false;
                    result.LastError = Marshal.GetLastWin32Error();
                    return false;
                }
                prior = SelectObject(memory, bitmap);
                if (prior == IntPtr.Zero || prior == new IntPtr(-1))
                {
                    result.Success = false;
                    result.LastError = Marshal.GetLastWin32Error();
                    return false;
                }
                if (!BitBlt(memory, 0, 0, width, height, screen, x, y, SRCCOPY | CAPTUREBLT))
                {
                    result.Success = false;
                    result.LastError = Marshal.GetLastWin32Error();
                    return false;
                }
                SelectObject(memory, prior);
                prior = IntPtr.Zero;

                BITMAPINFO info = new BITMAPINFO();
                info.bmiHeader.biSize = (uint)Marshal.SizeOf(typeof(BITMAPINFOHEADER));
                info.bmiHeader.biWidth = width;
                info.bmiHeader.biHeight = -height;
                info.bmiHeader.biPlanes = 1;
                info.bmiHeader.biBitCount = 32;
                info.bmiHeader.biCompression = BI_RGB;
                info.bmiHeader.biSizeImage = (uint)(width * height * 4);
                byte[] pixels = new byte[width * height * 4];
                int lines = GetDIBits(screen, bitmap, 0, (uint)height, pixels, ref info, DIB_RGB_COLORS);
                if (lines != height)
                {
                    result.Success = false;
                    result.LastError = Marshal.GetLastWin32Error();
                    return false;
                }
                using (FileStream stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read))
                using (BinaryWriter writer = new BinaryWriter(stream))
                {
                    writer.Write((ushort)0x4d42);
                    writer.Write((uint)(14 + 40 + pixels.Length));
                    writer.Write((ushort)0);
                    writer.Write((ushort)0);
                    writer.Write((uint)54);
                    writer.Write((uint)40);
                    writer.Write(width);
                    writer.Write(-height);
                    writer.Write((ushort)1);
                    writer.Write((ushort)32);
                    writer.Write((uint)0);
                    writer.Write((uint)pixels.Length);
                    writer.Write((int)0);
                    writer.Write((int)0);
                    writer.Write((uint)0);
                    writer.Write((uint)0);
                    writer.Write(pixels);
                }
                result.Success = true;
                result.LastError = 0;
                result.Bytes = 54L + pixels.Length;
                return true;
            }
            catch (Exception exception)
            {
                result.Success = false;
                result.LastError = Marshal.GetLastWin32Error();
                result.ErrorText = exception.GetType().FullName + ": " + exception.Message;
                return false;
            }
            finally
            {
                if (prior != IntPtr.Zero)
                    SelectObject(memory, prior);
                if (bitmap != IntPtr.Zero)
                    DeleteObject(bitmap);
                if (memory != IntPtr.Zero)
                    DeleteDC(memory);
                ReleaseDC(IntPtr.Zero, screen);
            }
        }
    }
}
