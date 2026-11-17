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

msg = "feat: ESP32 硬件桥固件适配 ESP32-S3-DevKitC-1\n\n用户买了原厂 ESP32-S3-DevKitC-1（ESP32-S3-WROOM-1 模组，512KB SRAM 无 PSRAM，双 USB 口），把硬件桥固件从 ESP32-C3 迁到 S3。\n- platformio.ini：default_env / env 改为 esp32-s3-devkitc-1，board=esp32-s3-devkitc-1；串口走 UART0（TX=GPIO43/RX=GPIO44），不加 USB CDC flag；NimBLE-Arduino 锁 1.4.3（1.4.0 起支持 S3）。\n- esp32-build.yml：artifact 路径 esp32-c3 -> esp32-s3-devkitc-1。\n- main.cpp：头部注释去 C3 字样，代码逻辑通用无需改。\n- esp32/README.md：硬件说明、esptool --chip esp32s3、双 USB 口注意（用左边 USB-UART 口）、App 开关名统一为「桥接（WiFi 转发）」。\nApp 端无需改动，UDP 协议与 12 字节报告布局不变。"

commit = gh("POST", "/git/commits", {
    "message": msg, "tree": tree["sha"], "parents": [BASE]
})
print("new commit =", commit["sha"])

gh("PATCH", "/git/refs/heads/main", {"sha": commit["sha"], "force": False})
print("PUSHED main ->", commit["sha"])
