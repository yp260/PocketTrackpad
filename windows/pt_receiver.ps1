<#
.SYNOPSIS
    PocketTrackpad Windows 接收器 —— 零安装版（只用 Windows 自带的 PowerShell）。

.DESCRIPTION
    本脚本不依赖 Python、不需要安装任何软件、不需要驱动、不需要管理员权限。
    Windows 10 / 11 自带 Windows PowerShell 5.1 与 .NET Framework，
    脚本用 Add-Type 在内存里即时编译一小段 C#（P/Invoke user32.dll 的 SendInput），
    再用 .NET 自带的 UDP Socket 收包，把 12 字节复合 HID 报告注入 Windows。

    协议与仓库里的 ESP32 固件（esp32/src/main.cpp）逐字节一致：
      hello   : iPhone -> PC   [0x50, 0x54]        ("PT")
      welcome : PC    -> iPhone [0x54, 0x50]        ("TP")
      report  : iPhone -> PC   12 字节
                [modifier, reserved, key1..key6, buttons, dx, dy, wheel]
      query   : iPhone -> PC   [0x50, 0x54, 0x51]  ("PTQ")  广播查电脑 IP
      answer  : PC    -> iPhone ASCII "PTR|<ip>|<port>"

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File pt_receiver.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File pt_receiver.ps1 -Port 5001

.NOTES
    首次运行时 Windows 防火墙可能询问是否允许 PowerShell 访问网络，
    选「专用网络」+「允许访问」即可（一次性）。
#>

[CmdletBinding()]
param(
    # UDP 监听端口，必须与 App 设置页里的端口一致
    [int]$Port = 5000,

    # 鼠标改用相对移动（默认绝对定位，手指与指针 1:1，不受指针加速影响）
    [switch]$Relative,

    # 只解析并打印收到什么，不真的动鼠标（排查用）
    [switch]$DryRun,

    # 自检：验证本机 SendInput 是否可用，然后退出
    [switch]$SelfTest,

    # 打印每一条收到的报告（含空闲帧）
    [switch]$Trace
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 内嵌 C#：Win32 SendInput 注入 + UDP 收包 + 协议解析
#
# 编译目标是 .NET Framework 4.x 的 C# 5 编译器（Windows PowerShell 5.1 自带），
# 因此不用任何 C# 6+ 语法，也不用 System.Core（HashSet 等）。
# ---------------------------------------------------------------------------

$source = @'
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;

namespace PocketTrackpad
{
    public static class Receiver
    {
        // ---- 协议常量 ----
        public const int REPORT_LEN = 12;
        private static readonly byte[] HELLO   = new byte[] { 0x50, 0x54 };      // "PT"
        private static readonly byte[] WELCOME = new byte[] { 0x54, 0x50 };      // "TP"
        private static readonly byte[] QUERY   = new byte[] { 0x50, 0x54, 0x51 }; // "PTQ"

        // ---- Win32 常量 ----
        private const uint INPUT_MOUSE    = 0;
        private const uint INPUT_KEYBOARD = 1;
        private const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
        private const uint KEYEVENTF_KEYUP        = 0x0002;
        private const uint MOUSEEVENTF_MOVE        = 0x0001;
        private const uint MOUSEEVENTF_LEFTDOWN   = 0x0002;
        private const uint MOUSEEVENTF_LEFTUP     = 0x0004;
        private const uint MOUSEEVENTF_RIGHTDOWN  = 0x0008;
        private const uint MOUSEEVENTF_RIGHTUP    = 0x0010;
        private const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020;
        private const uint MOUSEEVENTF_MIDDLEUP   = 0x0040;
        private const uint MOUSEEVENTF_WHEEL      = 0x0800;
        private const uint MOUSEEVENTF_ABSOLUTE   = 0x8000;
        private const uint MOUSEEVENTF_VIRTUALDESK = 0x4000;
        private const int  WHEEL_DELTA = 120;
        private const int  SM_XVIRTUALSCREEN = 76, SM_YVIRTUALSCREEN = 77;
        private const int  SM_CXVIRTUALSCREEN = 78, SM_CYVIRTUALSCREEN = 79;

        // ---- Win32 结构体 ----
        [StructLayout(LayoutKind.Sequential)]
        public struct MOUSEINPUT
        {
            public int dx; public int dy; public uint mouseData; public uint dwFlags;
            public uint time; public UIntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct KEYBDINPUT
        {
            public ushort wVk; public ushort wScan; public uint dwFlags;
            public uint time; public UIntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct HARDWAREINPUT
        {
            public uint uMsg; public ushort wParamL; public ushort wParamH;
        }

        [StructLayout(LayoutKind.Explicit)]
        public struct INPUTUNION
        {
            [FieldOffset(0)] public MOUSEINPUT mi;
            [FieldOffset(0)] public KEYBDINPUT ki;
            [FieldOffset(0)] public HARDWAREINPUT hi;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct INPUT
        {
            public uint type;
            public INPUTUNION u;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct POINT { public int x; public int y; }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

        [DllImport("user32.dll")]
        private static extern int GetSystemMetrics(int nIndex);

        [DllImport("user32.dll")]
        private static extern bool GetCursorPos(out POINT lpPoint);

        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        // ---- HID 键码 -> Windows 虚拟键码 ----
        private static readonly Dictionary<int, ushort> HidToVk = BuildHidToVk();
        private static readonly Dictionary<int, ushort> ModToVk = BuildModToVk();
        // 扩展键：方向键 / Home / End / PgUp / PgDn / 插入删除 / 菜单 / 右 Ctrl Alt
        private static readonly bool[] ExtendedVks = BuildExtendedVks();

        private static Dictionary<int, ushort> BuildHidToVk()
        {
            Dictionary<int, ushort> m = new Dictionary<int, ushort>();
            int i;
            for (i = 0; i < 26; i++) m[0x04 + i] = (ushort)(0x41 + i);   // a-z
            for (i = 0; i < 9; i++)  m[0x1E + i] = (ushort)(0x31 + i);   // 1-9
            m[0x27] = 0x30;                                                 // 0
            m[0x28] = 0x0D; m[0x29] = 0x1B; m[0x2A] = 0x08; m[0x2B] = 0x09; m[0x2C] = 0x20;
            m[0x2D] = 0xBD; m[0x2E] = 0xBB; m[0x2F] = 0xDB; m[0x30] = 0xDD; m[0x31] = 0xDC;
            m[0x33] = 0xBA; m[0x34] = 0xDE; m[0x35] = 0xC0; m[0x36] = 0xBC; m[0x37] = 0xBE;
            m[0x38] = 0xBF; m[0x39] = 0x14; m[0x46] = 0x2C; m[0x47] = 0x91; m[0x48] = 0x13;
            m[0x49] = 0x2D; m[0x4A] = 0x24; m[0x4B] = 0x21; m[0x4C] = 0x2E; m[0x4D] = 0x23;
            m[0x4E] = 0x22; m[0x4F] = 0x27; m[0x50] = 0x25; m[0x51] = 0x28; m[0x52] = 0x26;
            m[0x65] = 0x5D;
            for (i = 0; i < 12; i++) m[0x3A + i] = (ushort)(0x70 + i);  // F1-F12
            return m;
        }

        private static Dictionary<int, ushort> BuildModToVk()
        {
            Dictionary<int, ushort> m = new Dictionary<int, ushort>();
            m[0x01] = 0xA2; m[0x02] = 0xA0; m[0x04] = 0xA4; m[0x08] = 0x5B;
            m[0x10] = 0xA3; m[0x20] = 0xA1; m[0x40] = 0xA5; m[0x80] = 0x5C;
            return m;
        }

        private static bool[] BuildExtendedVks()
        {
            bool[] s = new bool[256];
            int[] v = new int[] {
                0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28,
                0x2C, 0x2D, 0x2E, 0x5D, 0xA3, 0xA5
            };
            for (int i = 0; i < v.Length; i++) s[v[i]] = true;
            return s;
        }

        // ---- 状态（报告是快照，靠差分还原按下/抬起）----
        private static byte prevMod = 0;
        private static List<int> prevKeys = new List<int>();
        private static byte prevButtons = 0;

        // 虚拟桌面与光标位置（绝对定位用）
        private static int originX = 0, originY = 0, vw = 1920, vh = 1080;
        private static int vx = 0, vy = 0;

        private static bool relative = false;
        private static bool dryRun = false;
        private static bool verbose = false;
        private static volatile bool stopRequested = false;
        private static uint lastError = 0;

        private static readonly byte[] ModBits =
            new byte[] { 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80 };

        private static string VkName(int vk)
        {
            if (vk >= 0x30 && vk <= 0x39) return "'" + (char)vk + "'";
            if (vk >= 0x41 && vk <= 0x5A) return "'" + (char)vk + "'";
            if (vk >= 0x70 && vk <= 0x7B) return "F" + (vk - 0x6F);
            switch (vk)
            {
                case 0x08: return "Backspace"; case 0x09: return "Tab";
                case 0x0D: return "Enter";   case 0x13: return "Pause";
                case 0x14: return "CapsLock"; case 0x1B: return "Esc";
                case 0x20: return "Space";   case 0x21: return "PageUp";
                case 0x22: return "PageDown"; case 0x23: return "End";
                case 0x24: return "Home";    case 0x25: return "Left";
                case 0x26: return "Up";      case 0x27: return "Right";
                case 0x28: return "Down";    case 0x2C: return "PrintScreen";
                case 0x2D: return "Insert";  case 0x2E: return "Delete";
                case 0xA0: return "LShift";  case 0xA1: return "RShift";
                case 0xA2: return "LCtrl";   case 0xA3: return "RCtrl";
                case 0xA4: return "LAlt";    case 0xA5: return "RAlt";
                case 0x5B: return "LWin";    case 0x5C: return "RWin";
                default: return "0x" + vk.ToString("X");
            }
        }

        // ---- 低层注入 ----
        private static void Send(List<INPUT> inputs)
        {
            if (inputs.Count == 0) return;
            if (dryRun) return;
            INPUT[] arr = inputs.ToArray();
            uint sent = SendInput((uint)arr.Length, arr, Marshal.SizeOf(typeof(INPUT)));
            if (sent != (uint)arr.Length) lastError = (uint)Marshal.GetLastWin32Error();
        }

        private static INPUT KeyInput(int vk, bool up)
        {
            uint flags = up ? KEYEVENTF_KEYUP : 0;
            if (vk >= 0 && vk < 256 && ExtendedVks[vk]) flags |= KEYEVENTF_EXTENDEDKEY;
            KEYBDINPUT ki = new KEYBDINPUT();
            ki.wVk = (ushort)vk; ki.wScan = 0; ki.dwFlags = flags; ki.time = 0;
            ki.dwExtraInfo = UIntPtr.Zero;
            INPUT i = new INPUT();
            i.type = INPUT_KEYBOARD;
            i.u.ki = ki;
            return i;
        }

        private static INPUT MouseInput(int dx, int dy, uint data, uint flags)
        {
            MOUSEINPUT mi = new MOUSEINPUT();
            mi.dx = dx; mi.dy = dy; mi.mouseData = data; mi.dwFlags = flags;
            mi.time = 0; mi.dwExtraInfo = UIntPtr.Zero;
            INPUT i = new INPUT();
            i.type = INPUT_MOUSE;
            i.u.mi = mi;
            return i;
        }

        private static void ReadVirtualDesktop()
        {
            try { SetProcessDPIAware(); } catch { }
            int x = 0, y = 0, w = 0, h = 0;
            try
            {
                x = GetSystemMetrics(SM_XVIRTUALSCREEN);
                y = GetSystemMetrics(SM_YVIRTUALSCREEN);
                w = GetSystemMetrics(SM_CXVIRTUALSCREEN);
                h = GetSystemMetrics(SM_CYVIRTUALSCREEN);
            }
            catch { return; }
            if (w > 0 && h > 0)
            {
                vw = w; vh = h; originX = x; originY = y;
                POINT pt;
                if (GetCursorPos(out pt)) { vx = pt.x; vy = pt.y; }
                else { vx = x + w / 2; vy = y + h / 2; }
                if (vx < x) vx = x;
                if (vy < y) vy = y;
                if (vx > x + w - 1) vx = x + w - 1;
                if (vy > y + h - 1) vy = y + h - 1;
            }
        }

        private static INPUT Motion(int dx, int dy)
        {
            if (relative) return MouseInput(dx, dy, 0, MOUSEEVENTF_MOVE);
            int x = vx + dx, y = vy + dy;
            if (x < originX) x = originX;
            if (y < originY) y = originY;
            if (x > originX + vw - 1) x = originX + vw - 1;
            if (y > originY + vh - 1) y = originY + h - 1;
            vx = x; vy = y;
            int nx = (int)Math.Round((x - originX) * 65535.0 / Math.Max(1, vw - 1));
            int ny = (int)Math.Round((y - originY) * 65535.0 / Math.Max(1, vh - 1));
            if (nx < 0) nx = 0; if (nx > 65535) nx = 65535;
            if (ny < 0) ny = 0; if (ny > 65535) ny = 65535;
            return MouseInput(nx, ny, 0,
                MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK);
        }

        // ---- 应用一帧报告 ----
        private static void Apply(byte modifier, List<int> keys, byte buttons,
                                  sbyte dx, sbyte dy, sbyte wheel)
        {
            List<INPUT> inputs = new List<INPUT>();
            ushort vk;

            // 先松键
            foreach (int kc in prevKeys)
                if (!keys.Contains(kc) && HidToVk.TryGetValue(kc, out vk))
                    inputs.Add(KeyInput(vk, true));
            // 松修饰键
            foreach (byte bit in ModBits)
                if ((prevMod & bit) != 0 && (modifier & bit) == 0 && ModToVk.TryGetValue(bit, out vk))
                    inputs.Add(KeyInput(vk, true));
            // 按修饰键
            foreach (byte bit in ModBits)
                if ((modifier & bit) != 0 && (prevMod & bit) == 0 && ModToVk.TryGetValue(bit, out vk))
                    inputs.Add(KeyInput(vk, false));
            // 按键
            foreach (int kc in keys)
                if (!prevKeys.Contains(kc) && HidToVk.TryGetValue(kc, out vk))
                    inputs.Add(KeyInput(vk, false));

            // 鼠标键
            if ((buttons & 0x01) != 0 && (prevButtons & 0x01) == 0) inputs.Add(MouseInput(0, 0, 0, MOUSEEVENTF_LEFTDOWN));
            if ((buttons & 0x01) == 0 && (prevButtons & 0x01) != 0) inputs.Add(MouseInput(0, 0, 0, MOUSEEVENTF_LEFTUP));
            if ((buttons & 0x02) != 0 && (prevButtons & 0x02) == 0) inputs.Add(MouseInput(0, 0, 0, MOUSEEVENTF_RIGHTDOWN));
            if ((buttons & 0x02) == 0 && (prevButtons & 0x02) != 0) inputs.Add(MouseInput(0, 0, 0, MOUSEEVENTF_RIGHTUP));
            if ((buttons & 0x04) != 0 && (prevButtons & 0x04) == 0) inputs.Add(MouseInput(0, 0, 0, MOUSEEVENTF_MIDDLEDOWN));
            if ((buttons & 0x04) == 0 && (prevButtons & 0x04) != 0) inputs.Add(MouseInput(0, 0, 0, MOUSEEVENTF_MIDDLEUP));

            if (dx != 0 || dy != 0) inputs.Add(Motion(dx, dy));
            if (wheel != 0) inputs.Add(MouseInput(0, 0, (uint)(wheel * WHEEL_DELTA), MOUSEEVENTF_WHEEL));

            Send(inputs);

            prevMod = modifier;
            prevKeys = new List<int>(keys);
            prevButtons = buttons;
        }

        // 退出时松开所有还按住的键与鼠标键，避免「卡住的按键」
        private static void ReleaseAll()
        {
            List<INPUT> inputs = new List<INPUT>();
            ushort vk;
            foreach (int kc in prevKeys)
                if (HidToVk.TryGetValue(kc, out vk)) inputs.Add(KeyInput(vk, true));
            foreach (byte bit in ModBits)
                if ((prevMod & bit) != 0 && ModToVk.TryGetValue(bit, out vk)) inputs.Add(KeyInput(vk, true));
            if ((prevButtons & 0x01) != 0) inputs.Add(MouseInput(0, 0, 0, MOUSEEVENTF_LEFTUP));
            if ((prevButtons & 0x02) != 0) inputs.Add(MouseInput(0, 0, 0, MOUSEEVENTF_RIGHTUP));
            if ((prevButtons & 0x04) != 0) inputs.Add(MouseInput(0, 0, 0, MOUSEEVENTF_MIDDLEUP));

            Send(inputs);

            prevKeys = new List<int>();
            prevMod = 0;
            prevButtons = 0;
        }

        private static string Describe(byte modifier, List<int> keys, byte buttons, sbyte dx, sbyte dy, sbyte wheel)
        {
            List<string> parts = new List<string>();
            List<string> mods = new List<string>();
            List<string> ks = new List<string>();
            ushort vk;
            foreach (byte bit in ModBits)
                if ((modifier & bit) != 0 && ModToVk.TryGetValue(bit, out vk)) mods.Add(VkName(vk));
            if (mods.Count > 0) parts.Add(string.Join("+", mods.ToArray()));
            foreach (int kc in keys)
                ks.Add(HidToVk.TryGetValue(kc, out vk) ? VkName(vk) : ("0x" + kc.ToString("X")));
            if (ks.Count > 0) parts.Add(string.Join("+", ks.ToArray()));
            if ((buttons & 0x01) != 0) parts.Add("LMB");
            if ((buttons & 0x02) != 0) parts.Add("RMB");
            if ((buttons & 0x04) != 0) parts.Add("MMB");
            if (dx != 0 || dy != 0) parts.Add("move(" + dx + "," + dy + ")");
            if (wheel != 0) parts.Add("wheel(" + wheel + ")");
            if (parts.Count == 0) return "(idle)";
            return string.Join(" ", parts.ToArray());
        }

        private static List<int> ParseKeys(byte[] data)
        {
            List<int> keys = new List<int>();
            for (int i = 2; i < 8; i++) if (data[i] != 0) keys.Add(data[i]);
            return keys;
        }

        // ---- 对外入口 ----
        public static string Run(int port, bool rel, bool dry, bool selftest, bool verb)
        {
            relative = rel; dryRun = dry; verbose = verb;

            int size = Marshal.SizeOf(typeof(INPUT));
            int expect = (IntPtr.Size == 8) ? 40 : 28;
            if (size != expect)
                return "FATAL: INPUT struct size mismatch (" + size + " != " + expect + ")";

            Console.CancelKeyPress += delegate (object s, ConsoleCancelEventArgs e)
            {
                e.Cancel = true;
                stopRequested = true;
            };
            AppDomain.CurrentDomain.ProcessExit += delegate { ReleaseAll(); };

            if (selftest)
            {
                ReadVirtualDesktop();
                List<INPUT> probe = new List<INPUT>();
                probe.Add(KeyInput(0x41, false));
                probe.Add(KeyInput(0x41, true));
                Send(probe);
                Console.WriteLine("SendInput returned without error. lastError=" + lastError);
                return lastError == 0 ? "SELFTEST OK" : "SELFTEST FAILED (lastError=" + lastError + ")";
            }

            UdpClient udp = new UdpClient();
            udp.ExclusiveAddressUse = false;
            udp.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            udp.EnableBroadcast = true;
            udp.Client.Bind(new IPEndPoint(IPAddress.Any, port));
            udp.Client.ReceiveTimeout = 300;

            ReadVirtualDesktop();

            Console.WriteLine("PocketTrackpad receiver (PowerShell, zero install) listening on UDP " + port);
            Console.WriteLine("  mouse mode : " + (relative ? "relative" : "absolute (1:1)"));
            Console.WriteLine("  output     : " + (dryRun ? "DRY RUN (nothing injected)" : "real input via SendInput"));
            Console.WriteLine("  INPUT size : " + size + " bytes");
            Console.WriteLine("");
            Console.WriteLine("Waiting for the iPhone. In the app: enable the bridge, then press Connect.");
            Console.WriteLine("If the app asks for an address, use one of these LAN IPs:");
            foreach (string ip in LanAddresses()) Console.WriteLine("    " + ip);
            Console.WriteLine("");
            Console.WriteLine("Press Ctrl+C to stop.");
            Console.WriteLine("");

            IPEndPoint from = new IPEndPoint(IPAddress.Any, port);
            while (!stopRequested)
            {
                byte[] data;
                try
                {
                    data = udp.Receive(ref from);
                }
                catch (SocketException)
                {
                    continue;   // 超时，循环回来看停止标志
                }
                catch (ObjectDisposedException)
                {
                    break;
                }

                // hello -> welcome
                if (data.Length == 2 && data[0] == 0x50 && data[1] == 0x54)
                {
                    try { udp.Send(WELCOME, WELCOME.Length, from); } catch { }
                    Console.WriteLine("[hello] " + from.Address + ":" + from.Port + "  handshake done");
                    continue;
                }

                // 广播查电脑 IP -> 回自己的地址
                if (data.Length == 3 && data[0] == 0x50 && data[1] == 0x54 && data[2] == 0x51)
                {
                    string ip = LocalAddressFor(from.Address);
                    byte[] ans = Encoding.ASCII.GetBytes("PTR|" + ip + "|" + port);
                    try { udp.Send(ans, ans.Length, from); } catch { }
                    Console.WriteLine("[query] " + from.Address + ":" + from.Port + "  answered " + ip);
                    continue;
                }

                if (data.Length != REPORT_LEN)
                {
                    if (verbose)
                        Console.WriteLine("[skip] " + data.Length + " bytes from " + from.Address);
                    continue;
                }

                byte modifier = data[0];
                List<int> keys = ParseKeys(data);
                byte buttons = data[8];
                sbyte dx = unchecked((sbyte)data[9]);
                sbyte dy = unchecked((sbyte)data[10]);
                sbyte wheel = unchecked((sbyte)data[11]);

                string desc = Describe(modifier, keys, buttons, dx, dy, wheel);
                if (verbose || desc != "(idle)")
                    Console.WriteLine(from.Address + ":" + from.Port + "  " + desc);

                Apply(modifier, keys, buttons, dx, dy, wheel);
            }

            udp.Close();
            ReleaseAll();
            return "STOPPED";
        }

        // ---- 工具：列出本机局域网 IPv4 ----
        public static string[] LanAddresses()
        {
            List<string> list = new List<string>();
            try
            {
                foreach (NetworkInterface ni in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (ni.OperationalStatus != OperationalStatus.Up) continue;
                    if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                    foreach (UnicastIPAddressInformation ua in ni.GetIPProperties().UnicastAddresses)
                    {
                        if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                        string s = ua.Address.ToString();
                        if (s.StartsWith("169.254")) continue;
                        list.Add(s + "  (" + ni.Name + ")");
                    }
                }
            }
            catch { }
            if (list.Count == 0) list.Add("(no LAN interface found)");
            return list.ToArray();
        }

        // ---- 工具：挑一个能到达对端的本机地址 ----
        private static string LocalAddressFor(IPAddress peer)
        {
            string fallback = "";
            try
            {
                foreach (NetworkInterface ni in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (ni.OperationalStatus != OperationalStatus.Up) continue;
                    if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                    foreach (UnicastIPAddressInformation ua in ni.GetIPProperties().UnicastAddresses)
                    {
                        if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                        string s = ua.Address.ToString();
                        if (s.StartsWith("169.254")) continue;
                        if (fallback == "") fallback = s;
                        byte[] a = ua.Address.GetAddressBytes();
                        byte[] b = peer.GetAddressBytes();
                        if (a[0] == b[0] && a[1] == b[1] && a[2] == b[2]) return s;
                    }
                }
            }
            catch { }
            return fallback == "" ? "127.0.0.1" : fallback;
        }
    }
}
'@

# ---------------------------------------------------------------------------
# 编译内嵌 C#
# ---------------------------------------------------------------------------

Write-Host "Compiling the built-in C# injector (no download, no install)..."
try {
    Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
} catch {
    Write-Host ""
    Write-Host "FAILED to compile the embedded C# code." -ForegroundColor Red
    Write-Host $_.Exception.Message
    Write-Host ""
    Write-Host "This almost never happens on Windows 10/11. If you are on a locked-down" -ForegroundColor Yellow
    Write-Host "machine with ConstrainedLanguage mode, use the Python fallback instead:" -ForegroundColor Yellow
    Write-Host "    windows\pt_receiver.py" -ForegroundColor Yellow
    exit 1
}
Write-Host "OK."
Write-Host ""

# ---------------------------------------------------------------------------
# 运行
# ---------------------------------------------------------------------------

$result = [PocketTrackpad.Receiver]::Run($Port, $Relative.IsPresent, $DryRun.IsPresent, $SelfTest.IsPresent, $Trace.IsPresent)

if ($SelfTest) {
    if ($result -like "SELFTEST OK*") {
        Write-Host "Self test passed: SendInput works on this PC." -ForegroundColor Green
    } else {
        Write-Host $result -ForegroundColor Red
    }
} else {
    Write-Host "Receiver stopped."
}
exit 0
