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

msg = "feat: 触控板模式开关——Appearance 声明 Touchpad + 三指左右滑切 App\n\n用户要求 iPad 把虚拟键鼠识别为触控板，且要可回退开关。研究确认：iPad「设置 → 通用」里「触控板」\n与「鼠标」是两个独立菜单，系统按 GAP Appearance 归类；标准 Appearance 有 Touchpad=0x03C9。\n实现：\n- HIDDescriptor 加 appearanceTouchpad(0x03C9) 与 Tab 键码 0x2B；\n- HIDPeripheral 加 trackpadMode 持久化开关（默认关、可回退），开启时 2A01 返回 Touchpad、\n  自动开复合模式（保证 Cmd+Tab 的键盘通道）、与 Windows/桥接模式互斥、切换断开重建 GATT 并\n  提示按辅助触控路径忽略重配；诊断条加角色标识；\n- 新增 switchApp(forward:) 发 Cmd+Tab / Cmd+Shift+Tab；\n- TrackpadSurface 加三指左右滑手势（与三指上滑按方向互斥），映射切 App，更新提示文案；\n- ContentView 设置页加「识别为触控板」开关和说明，preview/ui-preview.html 同步。\n重要限制已在 UI 说明：iPadOS 原生三指/四指手势只对 Magic Trackpad 2 私有协议开放，第三方 BLE\n拿不到；本 App 三指左右滑是 App 侧识别后转键盘快捷键的模拟实现，不是系统原生手势。\n报告格式不变（仍复合 12 字节，仅 Appearance 不同），配对流程不变。"

commit = gh("POST", "/git/commits", {
    "message": msg, "tree": tree["sha"], "parents": [BASE]
})
print("new commit =", commit["sha"])

gh("PATCH", "/git/refs/heads/main", {"sha": commit["sha"], "force": False})
print("PUSHED main ->", commit["sha"])
