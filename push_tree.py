import subprocess, base64, json, os, sys

GH = r"C:/Program Files/GitHub CLI/gh.exe"
REPO = "yp260/PocketTrackpad"
# 把本地 HEAD 的完整树作为新提交挂到远端 main 之上（避免与远端重复内容的提交做 rebase）。
ENV = dict(os.environ, NO_PROXY="api.github.com,github.com", HTTPS_PROXY="", HTTP_PROXY="")

def gh(method, path, data=None):
    cmd = [GH, "api", "-X", method, f"repos/{REPO}{path}"]
    stdin = None
    if data is not None:
        cmd += ["--input", "-"]
        stdin = json.dumps(data).encode("utf-8")
    p = subprocess.run(cmd, input=stdin, capture_output=True, env=ENV)
    if p.returncode != 0:
        sys.stderr.write("GH ERR %s\n%s\n" % (p.returncode, p.stderr.decode("utf-8", "replace")))
        sys.exit(1)
    return json.loads(p.stdout.decode("utf-8", "replace"))

# 远端 main（权威父节点）
ref = gh("GET", "/git/refs/heads/main")
BASE = ref["object"]["sha"]
print("remote main =", BASE)

# 列出本地 HEAD 的全部受跟踪文件，逐个生成 blob（用存储的 blob 内容，避免工作区 CRLF 干扰）
files = subprocess.check_output(
    ["git", "ls-tree", "-r", "HEAD", "--name-only"]
).decode("utf-8").splitlines()
files = [f for f in files if f]

blobs = []
for f in files:
    content = subprocess.check_output(["git", "cat-file", "blob", "HEAD:" + f])
    b64 = base64.b64encode(content).decode("ascii")
    r = gh("POST", "/git/blobs", {"content": b64, "encoding": "base64"})
    blobs.append((f, r["sha"]))
    print("blob", f, r["sha"][:8], len(content), "bytes")

tree = gh("POST", "/git/trees", {
    "tree": [{"path": f, "mode": "100644", "type": "blob", "sha": sha}
             for f, sha in blobs]
})
print("tree =", tree["sha"])

msg = json.dumps(
    "feat: 新增 USB HID 有线通道给 Windows，BLE 通道保留给 iPad（双通道）\n\n"
    "iPad 走 BLE 已真机验证通过（subscribed=1、report 持续在涨）。Windows 端搜不到：\n"
    "根因是 ESP32-S3 硬件只有 BLE、不支持经典蓝牙 BR/EDR（乐鑫官方文档确认，任何固件都加不出），\n"
    "而该 Windows 的老 Broadcom BCM20702(BT4.0) 适配器搜不到纯 BLE HID。\n"
    "- 方案：用 S3 原生 USB-OTG 口做 USB HID（标准 boot 键鼠，Windows 免驱、零延迟）。\n"
    "- main.cpp 引入 USBHIDKeyboard/USBHIDMouse；sendHidReport 把 12 字节报告同时发 BLE 和 USB：\n"
    "  前 8 字节 KeyReport(modifiers,reserved,keys[6]) 用 sendReport，后 4 字节 buttons/dx/dy/wheel 用 move+press/release。\n"
    "- platformio.ini 加 -D ARDUINO_USB_MODE=1 -D CONFIG_TINYUSB_ENABLED=1 -D CONFIG_TINYUSB_HID_ENABLED=1；\n"
    "  ARDUINO_USB_CDC_ON_BOOT 保持 0，确保 Serial 仍走 UART0 左口日志。\n"
    "- 两口分工：左 USB-UART 烧录+日志，右 USB-OTG 接 Windows 当键鼠。[STAT] 加 bleSubs/usbReady。\n"
    "- BLE 侧代码（inputReport 顺序、bonding、0x03C0、改名 PT-Pad-S3）全部保留不动。",
    ensure_ascii=False
)

commit = gh("POST", "/git/commits", {
    "message": msg, "tree": tree["sha"], "parents": [BASE]
})
print("new commit =", commit["sha"])

gh("PATCH", "/git/refs/heads/main", {"sha": commit["sha"], "force": False})
print("PUSHED main ->", commit["sha"])
