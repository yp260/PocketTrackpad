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
    "feat: 滚动改右侧竖条 + 删除无效断开/停止广播（v0.0.59）\n\n"
    "用户实测反馈：边缘触发滚动不好用、宏录制面板整屏遮挡顶部状态栏、断开会自动回连且停止广播不起作用。\n"
    "- 删除 v0.0.58 的边缘滚动全部机制（edgeLocate 状态/tick 分支/movePointerToSide、TrackpadSurface 边缘分流），改为触摸板右侧画一条可见竖条滚轮：起点落在条上只发 wheel（方向倍率沿用底部滚轮键），不发指针位移，条上轻点/长按不触发点击。滚动入口由三种减为两种。\n"
    "- 宏录制 sheet 改 presentationDetents fraction 0.80，只占下部 80%，顶部露出齿轮/已连接，可下拉关闭。\n"
    "- 删除工具栏「断开」与「停止广播/开始广播」切换按钮（点了自动回连、不起作用）：已连接只显示绿点+已连接，未连接只留「开始广播」（桥接为「连接桥接」）入口；删 stopAdvertising()/disconnectBridge()、切换设备 alert 与 showSwitchHelp 状态。\n"
    "- HIDPeripheral/TrackpadSurface/ContentView + preview/README 同步（JS 语法已校验）。",
    ensure_ascii=False
)

commit = gh("POST", "/git/commits", {
    "message": msg, "tree": tree["sha"], "parents": [BASE]
})
print("new commit =", commit["sha"])

gh("PATCH", "/git/refs/heads/main", {"sha": commit["sha"], "force": False})
print("PUSHED main ->", commit["sha"])
