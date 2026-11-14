#!/usr/bin/env python3
"""PocketTrackpad Windows receiver -- turns the iPhone into a mouse/keyboard for Windows.

WHY THIS EXISTS
---------------
The iPhone advertises itself as a BLE HID peripheral via CoreBluetooth. iOS does not
let an app set the GAP Appearance AD type, so Windows 11 never lists the device in
"Add device" (its discovery filter drops peripherals without a standard class id).
That is a platform limitation, not something the app can work around.

This receiver removes the radio from the equation entirely: the iPhone sends the very
same 12-byte composite HID report over WiFi/UDP (the exact protocol the optional
ESP32 firmware uses), and this program injects that report into Windows with the
Win32 SendInput API. No ESP32, no extra hardware -- just a PC and a WiFi network.

UDP PROTOCOL (byte-identical to the ESP32 firmware in esp32/src/main.cpp)
-------------------------------------------------------------------------
  hello    : iPhone -> PC   [0x50, 0x54]  ("PT")
  welcome  : PC    -> iPhone[0x54, 0x50]  ("TP")   reply to hello
  report   : iPhone -> PC   12 bytes
             [modifier, reserved, key1..key6, buttons, dx, dy, wheel]
             modifier : standard USB HID modifier bitmap
                        bit0 LCtrl  bit1 LShift  bit2 LAlt  bit3 LGui
                        bit4 RCtrl  bit5 RShift  bit6 RAlt  bit7 RGui
             key1..6  : USB HID Keyboard/Keypad page usage codes (0 means unused)
             buttons  : bit0 left  bit1 right  bit2 middle
             dx/dy/wheel : signed 8-bit relative amounts

The report is a *state* snapshot, not an event stream: the receiver diffs each
incoming report against the previous one and emits key/button down/up transitions,
exactly like a real HID driver would.

USAGE
-----
  py -3 pt_receiver.py                 # listen on UDP 5000 (default)
  py -3 pt_receiver.py --port 5001     # different port (set the same in the app)
  py -3 pt_receiver.py --rel           # relative mouse moves instead of absolute
  py -3 pt_receiver.py --dry-run       # parse + log only, do not touch the mouse
  py -3 pt_receiver.py --selftest      # verify SendInput works on this PC

Requires Python 3.8+ on Windows. No third-party packages.
"""

import argparse
import ctypes
import socket
import struct
import sys
import time
from ctypes import wintypes

# ----------------------------------------------------------------------------
# Protocol constants
# ----------------------------------------------------------------------------

UDP_PORT_DEFAULT = 5000
HELLO = b"PT"
WELCOME = b"TP"
REPORT_LEN = 12

# ----------------------------------------------------------------------------
# Win32 SendInput plumbing
# ----------------------------------------------------------------------------

INPUT_MOUSE = 0
INPUT_KEYBOARD = 1

KEYEVENTF_EXTENDEDKEY = 0x0001
KEYEVENTF_KEYUP = 0x0002

MOUSEEVENTF_MOVE = 0x0001
MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004
MOUSEEVENTF_RIGHTDOWN = 0x0008
MOUSEEVENTF_RIGHTUP = 0x0010
MOUSEEVENTF_MIDDLEDOWN = 0x0020
MOUSEEVENTF_MIDDLEUP = 0x0040
MOUSEEVENTF_WHEEL = 0x0800
MOUSEEVENTF_ABSOLUTE = 0x8000
MOUSEEVENTF_VIRTUALDESK = 0x4000

WHEEL_DELTA = 120

ULONG_PTR = ctypes.c_ulonglong if ctypes.sizeof(ctypes.c_void_p) == 8 else ctypes.c_ulong


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", wintypes.LONG),
        ("dy", wintypes.LONG),
        ("mouseData", wintypes.DWORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ULONG_PTR),
    ]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", wintypes.WORD),
        ("wScan", wintypes.WORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ULONG_PTR),
    ]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [
        ("uMsg", wintypes.DWORD),
        ("wParamL", wintypes.WORD),
        ("wParamH", wintypes.WORD),
    ]


class _INPUTunion(ctypes.Union):
    _fields_ = [
        ("mi", MOUSEINPUT),
        ("ki", KEYBDINPUT),
        ("hi", HARDWAREINPUT),
    ]


class INPUT(ctypes.Structure):
    _fields_ = [
        ("type", wintypes.DWORD),
        ("data", _INPUTunion),
    ]


class _POINT(ctypes.Structure):
    _fields_ = [("x", wintypes.LONG), ("y", wintypes.LONG)]


def _load_user32():
    try:
        return ctypes.WinDLL("user32", use_last_error=True)
    except OSError:
        return None


_user32 = _load_user32()
if _user32 is not None:
    _user32.SendInput.argtypes = (wintypes.UINT,
                                  ctypes.POINTER(INPUT),
                                  ctypes.c_int)
    _user32.SendInput.restype = wintypes.UINT
    _user32.GetSystemMetrics.argtypes = (ctypes.c_int,)
    _user32.GetSystemMetrics.restype = ctypes.c_int
    _user32.GetCursorPos.argtypes = (ctypes.POINTER(_POINT),)
    _user32.GetCursorPos.restype = wintypes.BOOL
    _user32.SetProcessDPIAware.argtypes = ()
    _user32.SetProcessDPIAware.restype = wintypes.BOOL

# Virtual desktop metrics (multi-monitor aware)
SM_XVIRTUALSCREEN = 76
SM_YVIRTUALSCREEN = 77
SM_CXVIRTUALSCREEN = 78
SM_CYVIRTUALSCREEN = 79


# ----------------------------------------------------------------------------
# HID usage code -> Windows virtual key
# ----------------------------------------------------------------------------
#
# The iPhone sends USB HID Keyboard/Keypad usage codes. Windows wants VK codes.
# Letters/digits line up directly; punctuation uses the same convention as a
# physical keyboard (unshifted base key + shift modifier), so the mapping below
# only needs the unshifted base key for each usage.

HID_TO_VK = {}

# 'a'..'z' -> VK 'A'..'Z'
for _i in range(26):
    HID_TO_VK[0x04 + _i] = 0x41 + _i
# '1'..'9' -> VK '1'..'9', '0' -> VK '0'
for _i in range(9):
    HID_TO_VK[0x1E + _i] = 0x31 + _i
HID_TO_VK[0x27] = 0x30

HID_TO_VK.update({
    0x28: 0x0D,  # Return
    0x29: 0x1B,  # Escape
    0x2A: 0x08,  # Backspace
    0x2B: 0x09,  # Tab
    0x2C: 0x20,  # Space
    0x2D: 0xBD,  # -  (OEM)
    0x2E: 0xBB,  # =  (OEM)
    0x2F: 0xDB,  # [  (OEM)
    0x30: 0xDD,  # ]  (OEM)
    0x31: 0xDC,  # \  (OEM)
    0x33: 0xBA,  # ;  (OEM)
    0x34: 0xDE,  # '  (OEM)
    0x35: 0xC0,  # `  (OEM)
    0x36: 0xBC,  # ,  (OEM)
    0x37: 0xBE,  # .  (OEM)
    0x38: 0xBF,  # /  (OEM)
    0x39: 0x14,  # CapsLock
    0x46: 0x2C,  # PrintScreen
    0x47: 0x91,  # ScrollLock
    0x48: 0x13,  # Pause
    0x49: 0x2D,  # Insert
    0x4A: 0x24,  # Home
    0x4B: 0x21,  # PageUp
    0x4C: 0x2E,  # Delete
    0x4D: 0x23,  # End
    0x4E: 0x22,  # PageDown
    0x4F: 0x27,  # Right
    0x50: 0x25,  # Left
    0x51: 0x28,  # Down
    0x52: 0x26,  # Up
    0x65: 0x5D,  # Menu / Application
})

# F1..F12 -> VK_F1..VK_F12
for _i in range(12):
    HID_TO_VK[0x3A + _i] = 0x70 + _i

# Keys that need the extended-key flag so Windows treats them correctly.
EXTENDED_VKS = {
    0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28,  # arrows, Home/End/PgUp/PgDn
    0x2C, 0x2D, 0x2E,                                  # PrintScreen/Ins/Del
    0x5D,                                              # Menu
    0xA3, 0xA5,                                        # right Ctrl / right Alt
}

# USB HID modifier bitmap -> Windows VK (left/right variants kept distinct).
MOD_TO_VK = {
    0x01: 0xA2,  # Left Ctrl
    0x02: 0xA0,  # Left Shift
    0x04: 0xA4,  # Left Alt
    0x08: 0x5B,  # Left GUI (Win)
    0x10: 0xA3,  # Right Ctrl
    0x20: 0xA1,  # Right Shift
    0x40: 0xA5,  # Right Alt
    0x80: 0x5C,  # Right GUI
}

VK_NAMES = {
    0x08: "Backspace", 0x09: "Tab", 0x0D: "Enter", 0x13: "Pause",
    0x14: "CapsLock", 0x1B: "Esc", 0x20: "Space", 0x21: "PageUp",
    0x22: "PageDown", 0x23: "End", 0x24: "Home", 0x25: "Left",
    0x26: "Up", 0x27: "Right", 0x28: "Down", 0x2C: "PrintScreen",
    0x2D: "Insert", 0x2E: "Delete",
}


def vk_name(vk):
    if vk in VK_NAMES:
        return VK_NAMES[vk]
    if 0x30 <= vk <= 0x39:
        return "'%s'" % chr(vk)
    if 0x41 <= vk <= 0x5A:
        return "'%s'" % chr(vk)
    if 0x70 <= vk <= 0x7B:
        return "F%d" % (vk - 0x6F)
    if 0xA0 <= vk <= 0xA5:
        return {0xA0: "LShift", 0xA1: "RShift", 0xA2: "LCtrl",
                0xA3: "RCtrl", 0xA4: "LAlt", 0xA5: "RAlt"}.get(vk, hex(vk))
    if vk == 0x5B:
        return "LWin"
    if vk == 0x5C:
        return "RWin"
    return hex(vk)


# ----------------------------------------------------------------------------
# Injector
# ----------------------------------------------------------------------------

class Injector:
    """Turns HID report transitions into Win32 SendInput calls."""

    def __init__(self, relative=False, dry_run=False):
        self.relative = relative
        self.dry_run = dry_run or _user32 is None
        self.events = 0
        self.last_error = 0

        # Previous report state, for diffing.
        self.prev_mod = 0
        self.prev_keys = set()
        self.prev_buttons = 0

        # Virtual desktop geometry and our own cursor position on it.
        # vx/vy are absolute screen coordinates (not deltas), so that absolute
        # pointer mode can convert them to the 0..65535 normalized space.
        self.origin_x, self.origin_y = 0, 0
        self.vw, self.vh = 1920, 1080
        self.vx, self.vy = 0, 0
        self._read_virtual_desktop()

    # -- desktop metrics ----------------------------------------------------

    def _read_virtual_desktop(self):
        if _user32 is None:
            return
        try:
            _user32.SetProcessDPIAware()
        except Exception:
            pass
        try:
            vx = _user32.GetSystemMetrics(SM_XVIRTUALSCREEN)
            vy = _user32.GetSystemMetrics(SM_YVIRTUALSCREEN)
            vw = _user32.GetSystemMetrics(SM_CXVIRTUALSCREEN)
            vh = _user32.GetSystemMetrics(SM_CYVIRTUALSCREEN)
        except Exception:
            return
        if vw > 0 and vh > 0:
            self.vw, self.vh = vw, vh
            self.origin_x, self.origin_y = vx, vy
            # Start the virtual cursor where the real pointer currently is,
            # so the first absolute move does not make the pointer jump.
            pt = _POINT()
            if _user32.GetCursorPos(ctypes.byref(pt)):
                self.vx, self.vy = pt.x, pt.y
            else:
                self.vx = vx + vw // 2
                self.vy = vy + vh // 2
            # Keep the tracked position inside the virtual desktop.
            self.vx = max(vx, min(vx + vw - 1, self.vx))
            self.vy = max(vy, min(vy + vh - 1, self.vy))

    # -- low level ----------------------------------------------------------

    def _send(self, inputs):
        if not inputs:
            return
        if self.dry_run:
            self.events += len(inputs)
            return
        arr = (INPUT * len(inputs))(*inputs)
        sent = _user32.SendInput(len(inputs), arr, ctypes.sizeof(INPUT))
        if sent != len(inputs):
            self.last_error = ctypes.get_last_error()

    def _key(self, vk, up=False):
        flags = KEYEVENTF_KEYUP if up else 0
        if vk in EXTENDED_VKS:
            flags |= KEYEVENTF_EXTENDEDKEY
        ki = KEYBDINPUT(wVk=vk, wScan=0, dwFlags=flags, time=0, dwExtraInfo=0)
        return INPUT(type=INPUT_KEYBOARD, data=_INPUTunion(ki=ki))

    def _mouse(self, dx=0, dy=0, data=0, flags=0):
        mi = MOUSEINPUT(dx=dx, dy=dy, mouseData=data, dwFlags=flags,
                        time=0, dwExtraInfo=0)
        return INPUT(type=INPUT_MOUSE, data=_INPUTunion(mi=mi))

    # -- report handling ----------------------------------------------------

    def apply(self, modifier, keys, buttons, dx, dy, wheel):
        """Apply one 12-byte report. `keys` is the set of non-zero usage codes."""
        inputs = []

        # --- keyboard: diff modifier + key sets ---
        old_mod, new_mod = self.prev_mod, modifier
        old_keys, new_keys = self.prev_keys, keys

        # Keys released (before modifiers change, so the pairing stays sane).
        for kc in sorted(old_keys - new_keys):
            vk = HID_TO_VK.get(kc)
            if vk:
                inputs.append(self._key(vk, up=True))
        # Modifiers released.
        for bit in (0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80):
            if (old_mod & bit) and not (new_mod & bit):
                vk = MOD_TO_VK.get(bit)
                if vk:
                    inputs.append(self._key(vk, up=True))
        # Modifiers pressed.
        for bit in (0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80):
            if (new_mod & bit) and not (old_mod & bit):
                vk = MOD_TO_VK.get(bit)
                if vk:
                    inputs.append(self._key(vk))
        # Keys pressed.
        for kc in sorted(new_keys - old_keys):
            vk = HID_TO_VK.get(kc)
            if vk:
                inputs.append(self._key(vk))

        # --- mouse buttons ---
        old_b, new_b = self.prev_buttons, buttons
        for bit, down, up in ((0x01, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP),
                              (0x02, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP),
                              (0x04, MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP)):
            if (new_b & bit) and not (old_b & bit):
                inputs.append(self._mouse(flags=down))
            elif (old_b & bit) and not (new_b & bit):
                inputs.append(self._mouse(flags=up))

        # --- motion & wheel ---
        if dx or dy:
            inputs.append(self._motion(dx, dy))
        if wheel:
            inputs.append(self._mouse(data=wheel * WHEEL_DELTA,
                                      flags=MOUSEEVENTF_WHEEL))

        self._send(inputs)
        self.prev_mod = new_mod
        self.prev_keys = set(new_keys)
        self.prev_buttons = new_b

    def _motion(self, dx, dy):
        if self.relative:
            return self._mouse(dx=dx, dy=dy, flags=MOUSEEVENTF_MOVE)
        # Absolute: keep our own cursor position so movement is 1:1 with the
        # finger, unaffected by Windows pointer acceleration.
        x = max(self.origin_x, min(self.origin_x + self.vw - 1, self.vx + dx))
        y = max(self.origin_y, min(self.origin_y + self.vh - 1, self.vy + dy))
        self.vx, self.vy = x, y
        # Convert to the 0..65535 normalized space SendInput expects.
        nx = int(round((x - self.origin_x) * 65535.0 / max(1, self.vw - 1)))
        ny = int(round((y - self.origin_y) * 65535.0 / max(1, self.vh - 1)))
        nx = max(0, min(65535, nx))
        ny = max(0, min(65535, ny))
        mi = MOUSEINPUT(dx=nx, dy=ny, mouseData=0,
                        dwFlags=MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
                        time=0, dwExtraInfo=0)
        return INPUT(type=INPUT_MOUSE, data=_INPUTunion(mi=mi))

    # -- helpers ------------------------------------------------------------

    def release_all(self):
        """Release any key/button still held (used on shutdown)."""
        inputs = []
        for kc in sorted(self.prev_keys):
            vk = HID_TO_VK.get(kc)
            if vk:
                inputs.append(self._key(vk, up=True))
        for bit in (0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80):
            if self.prev_mod & bit:
                vk = MOD_TO_VK.get(bit)
                if vk:
                    inputs.append(self._key(vk, up=True))
        for bit, up in ((0x01, MOUSEEVENTF_LEFTUP), (0x02, MOUSEEVENTF_RIGHTUP),
                        (0x04, MOUSEEVENTF_MIDDLEUP)):
            if self.prev_buttons & bit:
                inputs.append(self._mouse(flags=up))
        self._send(inputs)
        self.prev_mod = 0
        self.prev_keys = set()
        self.prev_buttons = 0


def _fix_origin(injector):
    """Ensure the virtual-desktop origin is known.

    _read_virtual_desktop() already sets it on success; this is the fallback
    for the case where GetSystemMetrics failed (headless / restricted session).
    """
    if injector.origin_x or injector.origin_y:
        return
    if _user32 is None:
        return
    try:
        injector.origin_x = _user32.GetSystemMetrics(SM_XVIRTUALSCREEN)
        injector.origin_y = _user32.GetSystemMetrics(SM_YVIRTUALSCREEN)
    except Exception:
        injector.origin_x = 0
        injector.origin_y = 0


# ----------------------------------------------------------------------------
# Main loop
# ----------------------------------------------------------------------------

def parse_report(data):
    """12-byte report -> (modifier, {usage codes}, buttons, dx, dy, wheel)."""
    modifier = data[0]
    keys = set()
    for b in data[2:8]:
        if b:
            keys.add(b)
    buttons = data[8]
    dx = struct.unpack("b", data[9:10])[0]
    dy = struct.unpack("b", data[10:11])[0]
    wheel = struct.unpack("b", data[11:12])[0]
    return modifier, keys, buttons, dx, dy, wheel


def describe(modifier, keys, buttons, dx, dy, wheel):
    parts = []
    mods = []
    for bit in (0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80):
        if modifier & bit:
            mods.append(vk_name(MOD_TO_VK[bit]))
    if mods:
        parts.append("+".join(mods))
    if keys:
        parts.append("+".join(vk_name(HID_TO_VK.get(k, hex(k)))
                               for k in sorted(keys)))
    if buttons & 0x01:
        parts.append("LMB")
    if buttons & 0x02:
        parts.append("RMB")
    if buttons & 0x04:
        parts.append("MMB")
    if dx or dy:
        parts.append("move(%d,%d)" % (dx, dy))
    if wheel:
        parts.append("wheel(%d)" % wheel)
    return " ".join(parts) if parts else "(idle)"


def selftest():
    if _user32 is None:
        print("SendInput unavailable: this is not Windows or user32 is blocked.")
        return 1
    print("Sending a test key press and a small mouse move...")
    inj = Injector()
    _fix_origin(inj)
    inj.apply(0x00, {0x04}, 0, 0, 0, 0)   # 'a' down
    time.sleep(0.05)
    inj.apply(0x00, set(), 0, 0, 0, 0)    # 'a' up
    inj.apply(0x00, set(), 0, 5, 5, 0)    # move
    print("OK -- SendInput works. (You should have seen an 'a' and a tiny move.)")
    return 0


def main():
    ap = argparse.ArgumentParser(description="PocketTrackpad Windows receiver")
    ap.add_argument("--port", type=int, default=UDP_PORT_DEFAULT,
                    help="UDP port to listen on (default %d)" % UDP_PORT_DEFAULT)
    ap.add_argument("--rel", action="store_true",
                    help="use relative mouse movement (default: absolute, 1:1)")
    ap.add_argument("--dry-run", action="store_true",
                    help="parse and log reports without touching the mouse")
    ap.add_argument("--selftest", action="store_true",
                    help="verify SendInput works, then exit")
    ap.add_argument("--verbose", action="store_true", help="log every report")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", args.port))
    sock.settimeout(1.0)

    inj = Injector(relative=args.rel, dry_run=args.dry_run)
    _fix_origin(inj)

    print("PocketTrackpad receiver listening on UDP port %d" % args.port)
    print("  mouse mode : %s" % ("relative" if args.rel else "absolute (1:1)"))
    print("  output     : %s" % ("DRY RUN (nothing injected)" if inj.dry_run
                                 else "real input via SendInput"))
    print("Waiting for the iPhone... (in the app: enable the bridge and point it "
          "at this PC's IP)")
    print("Press Ctrl+C to stop.")
    print("")

    last_peer = None
    try:
        while True:
            try:
                data, addr = sock.recvfrom(64)
            except socket.timeout:
                continue
            except OSError:
                break

            if len(data) == 2 and data == HELLO:
                try:
                    sock.sendto(WELCOME, addr)
                except OSError:
                    pass
                last_peer = addr
                print("[hello] %s:%d -- handshake done" % addr)
                continue

            if len(data) != REPORT_LEN:
                if args.verbose:
                    print("[skip] %d bytes from %s" % (len(data), addr))
                continue

            last_peer = addr
            modifier, keys, buttons, dx, dy, wheel = parse_report(data)
            if args.verbose or True:
                desc = describe(modifier, keys, buttons, dx, dy, wheel)
                if desc != "(idle)":
                    print("%s:%d  %s" % (addr[0], addr[1], desc))
            inj.apply(modifier, keys, buttons, dx, dy, wheel)
    except KeyboardInterrupt:
        print("\nStopping.")
    finally:
        try:
            inj.release_all()
        except Exception:
            pass
        sock.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
