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
    "fix(esp32): 显式调用 USB.begin()，修复 TinyUSB 栈未启动导致 Windows 只认 JTAG\n\n"
    "现象：ARDUINO_USB_MODE=0 已确认编译生效、串口也打印 'USB HID 已就绪'，\n"
    "但 Windows OTG 口仍是 'USB JTAG/serial debug unit' (303A:1001)，没有 HID 键鼠。\n"
    "根因（串口实证）：usbKeyboard.begin()/usbMouse.begin() 内部只创建信号量，\n"
    "不启动 TinyUSB 栈。arduino-esp32 2.0.17 的 main.cpp 仅在\n"
    "ARDUINO_USB_ON_BOOT(=CDC/MSC/DFU_ON_BOOT 任一为1) && !ARDUINO_USB_MODE 时自动 USB.begin()。\n"
    "我们 CDC_ON_BOOT=0（Serial 走 UART0），所以 USB.begin() 从未被调用，\n"
    "TinyUSB 没接管 GPIO19/20，USB 口停留在 ROM 的 JTAG 角色。\n"
    "- main.cpp: setup() 里在 usbKeyboard/usbMouse.begin() 之前显式调用 USB.begin()。\n"
    "- 其余配置（USB_MODE=0、build_unflags、TinyUSB 开关、BLE 侧代码）全部不动。",
    ensure_ascii=False
)

commit = gh("POST", "/git/commits", {
    "message": msg, "tree": tree["sha"], "parents": [BASE]
})
print("new commit =", commit["sha"])

gh("PATCH", "/git/refs/heads/main", {"sha": commit["sha"], "force": False})
print("PUSHED main ->", commit["sha"])
