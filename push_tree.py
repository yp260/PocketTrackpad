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
    "feat: 竖条收窄 + 宏面板上移 + 宏编辑全面可改 + 断开重连回主界面（v0.0.60）\n\n"
    "用户实测反馈：右侧竖条还是太宽、宏面板太靠下、宏编辑页要能改坐标/替换/插入动作、断开并重新广播要移回主界面原断开位置、断开好像不起作用。\n"
    "- 右侧滚轮竖条宽度减半：26pt→13pt（compact 20→10），圆角 13→6、箭头图标同步缩小；命中范围仍外扩 10pt。\n"
    "- 宏面板 presentationDetents fraction 0.80→0.90，顶边盖住「触控区/全键盘」切换栏，导航条仍露出。\n"
    "- 重写 MacroView 宏编辑器：每个动作可改类型（移动/滚轮/按键/按下/抬起/点击）与参数（dx/dy、绝对到达坐标换算、滚轮量、键位+修饰键、鼠标键+连击次数），「插」在中间插入、「改」编辑、左滑删除；本地副本点完成才回写。\n"
    "- 「断开并重新广播」从设置页移回右上角原断开位置（按钮名「断开重连」）；selectNewDevice 拆 GATT 重建重播（桥接模式断 UDP 重握手），新增 8 秒限时避开窗口（旧设备抢连则拆链重播、最多 8 次，超时放行），解决断开被自动回连抵消的问题；applyStartupMigration 清 avoidUntil。\n"
    "- TrackpadSurface/ContentView/HIDPeripheral/MacroView + preview/README 同步（JS 语法已校验）。",
    ensure_ascii=False
)

commit = gh("POST", "/git/commits", {
    "message": msg, "tree": tree["sha"], "parents": [BASE]
})
print("new commit =", commit["sha"])

gh("PATCH", "/git/refs/heads/main", {"sha": commit["sha"], "force": False})
print("PUSHED main ->", commit["sha"])
