using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
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
        public int Status;
        public int LastError;
        public long BridgeRequestId;
        public uint TargetProcessId;
        public uint TargetThreadId;
        public uint OwnerProcessId;
        public uint OwnerThreadId;
        public bool HasContext;
        public bool Open;
        public bool ConversionValid;
        public uint ConversionMode;
        public uint SentenceMode;
    }

    public sealed class CandidateResult
    {
        public int Status;
        public long BridgeRequestId;
        public uint TargetProcessId;
        public uint TargetThreadId;
        public uint OwnerProcessId;
        public uint OwnerThreadId;
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
        private const uint GPUI_IME_BRIDGE_MESSAGE = 0x8043; // WM_APP + 0x43
        private const uint GPUI_IME_BRIDGE_QUERY_IME = 1;
        private const uint GPUI_IME_BRIDGE_GET_IME_FIELD = 2;
        private const uint GPUI_IME_BRIDGE_QUERY_CANDIDATE = 3;
        private const uint GPUI_IME_BRIDGE_GET_CANDIDATE_FIELD = 4;
        private const uint GPUI_IME_BRIDGE_SET_OPEN = 5;
        private const uint GPUI_IME_BRIDGE_SET_CONVERSION = 6;
        private const uint GPUI_IME_BRIDGE_STATUS_UNAUTHORIZED = 9;
        private const int GPUI_IME_BRIDGE_STATUS_OK = 0;
        private const int GPUI_IME_BRIDGE_STATUS_NO_CONTEXT = 1;
        private const int GPUI_IME_BRIDGE_STATUS_QUERY_FAILED = 3;
        private const uint SMTO_ABORTIFHUNG = 0x0002;
        private const uint SMTO_BLOCK = 0x0001;
        private const uint SMTO_ERRORONEXIT = 0x0020;
        private const uint GPUI_IME_BRIDGE_TIMEOUT_MS = 1500;
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
        [DllImport("kernel32.dll")]
        private static extern void SetLastError(uint errorCode);
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

        private static ulong PackImeFieldRequest(uint nonce, uint operation, uint field)
        {
            return ((ulong)nonce << 32) | operation | ((ulong)field << 16);
        }

        private static ulong PackImeConversionRequest(uint nonce)
        {
            return ((ulong)nonce << 32) | GPUI_IME_BRIDGE_SET_CONVERSION;
        }

        public static bool ValidateImeBridgeProtocol()
        {
            const uint nonce = 0x6a31d4b9u;
            ulong fieldRequest = PackImeFieldRequest(nonce, GPUI_IME_BRIDGE_GET_CANDIDATE_FIELD, 13);
            ulong conversionRequest = PackImeConversionRequest(nonce);
            ulong conversionPayload = ((ulong)0x10293847u << 32) | 0xa1b2c3d4u;
            return GPUI_IME_BRIDGE_MESSAGE == 0x8043 &&
                (fieldRequest >> 32) == nonce &&
                (fieldRequest & 0xffff) == GPUI_IME_BRIDGE_GET_CANDIDATE_FIELD &&
                ((fieldRequest >> 16) & 0xffff) == 13 &&
                (conversionRequest >> 32) == nonce &&
                (conversionRequest & 0xffff) == GPUI_IME_BRIDGE_SET_CONVERSION &&
                (conversionPayload & 0xffffffffu) == 0xa1b2c3d4u &&
                (conversionPayload >> 32) == 0x10293847u &&
                GPUI_IME_BRIDGE_STATUS_OK == 0 && GPUI_IME_BRIDGE_STATUS_NO_CONTEXT == 1 &&
                GPUI_IME_BRIDGE_STATUS_QUERY_FAILED == 3 &&
                GPUI_IME_BRIDGE_STATUS_UNAUTHORIZED == 9;
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

        private static void VerifyImeBridgeTarget(IntPtr hwnd, uint expectedProcessId, uint expectedThreadId,
            long expectedStartTicks, string expectedPath, string expectedSha256)
        {
            using (Process process = Process.GetProcessById(checked((int)expectedProcessId)))
            {
                if (process.StartTime.ToUniversalTime().Ticks != expectedStartTicks)
                    throw new InvalidOperationException("Owner-thread IMM bridge PID start time changed.");
            }
            ProcessImagePathResult image = QueryProcessImagePath(expectedProcessId);
            if (!image.Success || String.IsNullOrWhiteSpace(image.Path) ||
                !String.Equals(Path.GetFullPath(image.Path), Path.GetFullPath(expectedPath), StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Owner-thread IMM bridge executable path changed or could not be queried; Win32=" + image.LastError + ".");
            using (FileStream stream = File.OpenRead(image.Path))
            using (SHA256 sha = SHA256.Create())
            {
                string actualSha256 = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", String.Empty);
                if (!String.Equals(actualSha256, expectedSha256, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Owner-thread IMM bridge executable hash changed.");
            }
            if (hwnd == IntPtr.Zero || !IsWindow(hwnd) || !IsWindowVisible(hwnd))
                throw new InvalidOperationException("Owner-thread IMM bridge target is not a visible HWND.");
            uint actualProcessId;
            uint actualThreadId = GetWindowThreadProcessId(hwnd, out actualProcessId);
            if (actualProcessId != expectedProcessId || actualThreadId != expectedThreadId ||
                !String.Equals(GetWindowClassName(hwnd), "gpui_mbt_windows_host_v1", StringComparison.Ordinal))
                throw new InvalidOperationException("Owner-thread IMM bridge target PID, thread, or GPUI class changed.");
            if (GetForegroundWindow() != hwnd)
                throw new InvalidOperationException("Owner-thread IMM bridge target lost foreground ownership.");
            DesktopResult desktop = CheckInputDesktop();
            if (!desktop.Success || !String.Equals(desktop.Name, "Default", StringComparison.Ordinal))
                throw new InvalidOperationException("Owner-thread IMM bridge requires the active Default input desktop; Win32=" + desktop.LastError + ".");
        }

        private static long SendImeBridgeRaw(IntPtr hwnd, uint expectedProcessId, uint expectedThreadId,
            long expectedStartTicks, string expectedPath, string expectedSha256,
            uint bridgeNonce, long packedWParam, long argument, uint timeoutMilliseconds)
        {
            if (bridgeNonce == 0)
                throw new InvalidOperationException("Owner-thread IMM bridge nonce must be nonzero.");
            VerifyImeBridgeTarget(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256);
            IntPtr messageResult;
            SetLastError(0);
            IntPtr delivered = SendMessageTimeoutW(hwnd, GPUI_IME_BRIDGE_MESSAGE,
                new IntPtr(packedWParam), new IntPtr(argument),
                SMTO_ABORTIFHUNG | SMTO_BLOCK | SMTO_ERRORONEXIT,
                timeoutMilliseconds, out messageResult);
            int win32Error = Marshal.GetLastWin32Error();
            if (delivered == IntPtr.Zero)
                throw new InvalidOperationException("Owner-thread IMM bridge request " + (packedWParam & 0xffff) +
                    " timed out or failed; Win32=" + (win32Error == 0 ? "unknown" : win32Error.ToString()) + ".");
            VerifyImeBridgeTarget(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256);
            return messageResult.ToInt64();
        }

        private static long SendImeBridge(IntPtr hwnd, uint expectedProcessId, uint expectedThreadId,
            long expectedStartTicks, string expectedPath, string expectedSha256,
            uint bridgeNonce, uint operation, uint field, long argument, uint timeoutMilliseconds)
        {
            ulong packedWParam = PackImeFieldRequest(bridgeNonce, operation, field);
            return SendImeBridgeRaw(hwnd, expectedProcessId, expectedThreadId,
                expectedStartTicks, expectedPath, expectedSha256,
                bridgeNonce,
                unchecked((long)packedWParam), argument, timeoutMilliseconds);
        }

        private static long ReadImeField(IntPtr hwnd, uint pid, uint tid, long startTicks,
            string path, string sha256, uint bridgeNonce, uint field, long snapshotId)
        {
            long value = SendImeBridge(hwnd, pid, tid, startTicks, path, sha256, bridgeNonce, GPUI_IME_BRIDGE_GET_IME_FIELD,
                field, snapshotId, GPUI_IME_BRIDGE_TIMEOUT_MS);
            if (value < 0)
                throw new InvalidOperationException("Owner-thread IMM bridge rejected stale/invalid IME snapshot field " + field + ".");
            return value;
        }

        private static long ReadCandidateField(IntPtr hwnd, uint pid, uint tid, long startTicks,
            string path, string sha256, uint bridgeNonce, uint field, long snapshotId)
        {
            long value = SendImeBridge(hwnd, pid, tid, startTicks, path, sha256, bridgeNonce, GPUI_IME_BRIDGE_GET_CANDIDATE_FIELD,
                field, snapshotId, GPUI_IME_BRIDGE_TIMEOUT_MS);
            if (value < 0)
                throw new InvalidOperationException("Owner-thread IMM bridge rejected stale/invalid candidate snapshot field " + field + ".");
            return value;
        }

        public static ImeResult QueryIme(IntPtr hwnd, uint expectedProcessId, uint expectedThreadId,
            long expectedStartTicks, string expectedPath, string expectedSha256, uint bridgeNonce, uint timeoutMilliseconds)
        {
            ImeResult result = new ImeResult();
            result.TargetProcessId = expectedProcessId;
            result.TargetThreadId = expectedThreadId;
            long requestId = SendImeBridge(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256,
                bridgeNonce,
                GPUI_IME_BRIDGE_QUERY_IME, 0, 0, timeoutMilliseconds);
            if (requestId <= 0)
                throw new InvalidOperationException("Owner-thread IMM snapshot request failed with bridge status " + requestId + ".");
            result.BridgeRequestId = requestId;
            result.Status = checked((int)ReadImeField(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256, bridgeNonce, 1, requestId));
            result.LastError = unchecked((int)(uint)ReadImeField(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256, bridgeNonce, 2, requestId));
            result.OwnerProcessId = unchecked((uint)ReadImeField(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256, bridgeNonce, 8, requestId));
            result.OwnerThreadId = unchecked((uint)ReadImeField(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256, bridgeNonce, 9, requestId));
            if (result.OwnerProcessId != expectedProcessId || result.OwnerThreadId != expectedThreadId)
                throw new InvalidOperationException("IMM snapshot came from a different process/thread than the owned HWND.");
            if (result.Status == GPUI_IME_BRIDGE_STATUS_NO_CONTEXT)
                return result;
            if (result.Status != GPUI_IME_BRIDGE_STATUS_OK)
                throw new InvalidOperationException("Owner-thread IMM snapshot failed with bridge status " + result.Status + ", Win32=" + result.LastError + ".");
            result.HasContext = ReadImeField(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256, bridgeNonce, 3, requestId) == 1;
            if (!result.HasContext)
                throw new InvalidOperationException("Owner-thread IMM snapshot status was OK without an HIMC.");
            result.Open = ReadImeField(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256, bridgeNonce, 4, requestId) == 1;
            result.ConversionValid = ReadImeField(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256, bridgeNonce, 5, requestId) == 1;
            if (result.ConversionValid)
            {
                result.ConversionMode = unchecked((uint)ReadImeField(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256, bridgeNonce, 6, requestId));
                result.SentenceMode = unchecked((uint)ReadImeField(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256, bridgeNonce, 7, requestId));
            }
            return result;
        }

        public static bool RestoreIme(IntPtr hwnd, uint expectedProcessId, uint expectedThreadId,
            long expectedStartTicks, string expectedPath, string expectedSha256,
            uint bridgeNonce, bool open, bool conversionValid, uint conversionMode, uint sentenceMode, uint timeoutMilliseconds, out int lastError)
        {
            lastError = 0;
            long openResult = SendImeBridge(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256,
                bridgeNonce,
                GPUI_IME_BRIDGE_SET_OPEN, 0, open ? 1 : 0, timeoutMilliseconds);
            if (openResult != 1)
            {
                lastError = openResult < 0 ? checked((int)-openResult) : GPUI_IME_BRIDGE_STATUS_QUERY_FAILED;
                return false;
            }
            if (!conversionValid)
                return true;
            ulong packedWParam = PackImeConversionRequest(bridgeNonce);
            long packedArgument = unchecked((long)(((ulong)sentenceMode << 32) | conversionMode));
            long conversionResult = SendImeBridgeRaw(hwnd, expectedProcessId, expectedThreadId,
                expectedStartTicks, expectedPath, expectedSha256,
                bridgeNonce, unchecked((long)packedWParam), packedArgument, timeoutMilliseconds);
            if (conversionResult != 1)
            {
                lastError = conversionResult < 0 ? checked((int)-conversionResult) : GPUI_IME_BRIDGE_STATUS_QUERY_FAILED;
                return false;
            }
            return true;
        }

        public static CandidateResult QueryCandidate(IntPtr hwnd, uint expectedProcessId, uint expectedThreadId,
            long expectedStartTicks, string expectedPath, string expectedSha256,
            uint bridgeNonce, uint index, uint timeoutMilliseconds)
        {
            CandidateResult result = new CandidateResult();
            result.TargetProcessId = expectedProcessId;
            result.TargetThreadId = expectedThreadId;
            long requestId = SendImeBridge(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256,
                bridgeNonce,
                GPUI_IME_BRIDGE_QUERY_CANDIDATE, 0, index, timeoutMilliseconds);
            if (requestId <= 0)
                throw new InvalidOperationException("Owner-thread candidate snapshot request failed with bridge status " + requestId + ".");
            result.BridgeRequestId = requestId;
            result.Index = index;
            result.Status = checked((int)ReadCandidateField(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256, bridgeNonce, 1, requestId));
            result.LastError = unchecked((int)(uint)ReadCandidateField(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256, bridgeNonce, 2, requestId));
            result.OwnerProcessId = unchecked((uint)ReadCandidateField(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256, bridgeNonce, 12, requestId));
            result.OwnerThreadId = unchecked((uint)ReadCandidateField(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256, bridgeNonce, 13, requestId));
            if (result.OwnerProcessId != expectedProcessId || result.OwnerThreadId != expectedThreadId)
                throw new InvalidOperationException("Candidate snapshot came from a different process/thread than the owned HWND.");
            result.HasContext = ReadCandidateField(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256, bridgeNonce, 3, requestId) == 1;
            if (result.Status != GPUI_IME_BRIDGE_STATUS_OK)
            {
                result.QuerySucceeded = false;
                return result;
            }
            result.QuerySucceeded = true;
            result.Index = unchecked((uint)ReadCandidateField(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256, bridgeNonce, 4, requestId));
            result.Style = unchecked((uint)ReadCandidateField(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256, bridgeNonce, 5, requestId));
            result.X = unchecked((int)ReadCandidateField(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256, bridgeNonce, 6, requestId));
            result.Y = unchecked((int)ReadCandidateField(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256, bridgeNonce, 7, requestId));
            result.Area.Left = unchecked((int)ReadCandidateField(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256, bridgeNonce, 8, requestId));
            result.Area.Top = unchecked((int)ReadCandidateField(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256, bridgeNonce, 9, requestId));
            result.Area.Right = unchecked((int)ReadCandidateField(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256, bridgeNonce, 10, requestId));
            result.Area.Bottom = unchecked((int)ReadCandidateField(hwnd, expectedProcessId, expectedThreadId, expectedStartTicks, expectedPath, expectedSha256, bridgeNonce, 11, requestId));
            return result;
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
