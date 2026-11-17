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
    "fix: 修复断开后开始广播闪一下 + 蓝牙设置入口 + 复制日志 + 桥接置顶（v0.0.61）\n\n"
    "用户实测反馈：点断开连接后再点开始广播闪一下没用；要在开始广播右边加蓝牙图标跳系统蓝牙设置；连接日志加复制全部按钮；设置里桥接 ESP32 移到顶部。\n"
    "- 根因是 v0.0.60 的 8 秒避开窗口：断开后自动重播，旧 iPad 一回连就在 didSubscribeTo 里被拆链重播，反复重建 GATT 导致界面闪一下又断开、谁都连不上。\n"
    "- 彻底移除避让机制：删 avoidCentralID/avoidUntil/avoidRejectCount 字段、迁移清零、订阅拆链分支；selectNewDevice 改为只干净断开（拆 GATT+停广播、桥接断 UDP），不自动 start()；断开后右上角变「开始广播」，点它才重建广播。\n"
    "- ContentView 工具栏加蓝牙图标按钮（已连接/未连接常驻），点它跳 App-Prefs:root=Bluetooth，失败回退系统设置页。\n"
    "- 连接日志卡片标题行加「复制全部」，把 hid.logLines 拼成整段写入剪贴板，短暂显示「已复制」。\n"
    "- 设置页桥接（ESP32）Section 从实验功能之后移到 Form 最顶部。\n"
    "- HIDPeripheral/ContentView + preview/README 同步（JS 语法已校验）。",
    ensure_ascii=False
)

commit = gh("POST", "/git/commits", {
    "message": msg, "tree": tree["sha"], "parents": [BASE]
})
print("new commit =", commit["sha"])

gh("PATCH", "/git/refs/heads/main", {"sha": commit["sha"], "force": False})
print("PUSHED main ->", commit["sha"])
