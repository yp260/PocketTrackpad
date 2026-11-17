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

msg = "feat: 默认参数调整与手势修正（v0.0.58）\n\n用户要求：三指上滑改为最小化当前程序/返回桌面（原 Command+H 在其 iPadOS 上表现为关闭程序）；指针默认 1.8x；按键音默认关；振动默认关；键鼠复合默认开；双指轻点 app 图标不要误拖动；触摸板左右边缘控制屏幕两侧滚动。\n- 默认值改用版本化新 key，老用户升级即生效：sensitivity.v2=1.8、keyClickEnabled.v2=false、hapticEnabled.v2=false、compositeDevice.v2=true。\n- 移除早期「首次运行强制切回纯鼠标」迁移，否则会把 composite v2 的 true 又改回 false。\n- 三指上滑 Command+H -> Command+M（keycode 0x0B -> 0x10），文案/日志/预览同步。\n- 双指拖拽加 8pt 阈值：累计位移超阈值才 setButton 按下左键，轻点不拖动图标。\n- 触摸板左右边缘滚动：单指起点落在边缘窄条则先把光标用饱和位移推到屏幕对应侧（独立计数、不进宏录制），再上下滑发 wheel；与底部滚轮键并存，方向约定一致。\n- 内联层：HIDDescriptor/HIDPeripheral/KeyClickPlayer/HapticPlayer/TrackpadSurface/ContentView + preview/README 同步（JS 语法已校验）。"

commit = gh("POST", "/git/commits", {
    "message": msg, "tree": tree["sha"], "parents": [BASE]
})
print("new commit =", commit["sha"])

gh("PATCH", "/git/refs/heads/main", {"sha": commit["sha"], "force": False})
print("PUSHED main ->", commit["sha"])
