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

msg = "feat: 双指手势改为拖拽（按住左键+移动）——滚动移到底部滚轮键\n\n用户要求把双指滑动改成「在 iPad 上双指按住并拖动」；确认目标是拖拽对象（拖 App 图标 / 选中文字），\n并确认滚动只保留底部滚轮键。\n实现：\n- TrackpadSurface：2 指 pan 由 handleScroll(wheel) 改为 handleDrag——began 按下左键(setButton 0x01)、\n  changed 发指针位移（用 pointer sensitivity、跟手方向，与自然滚动无关）、抬手/取消松开左键；\n  移除双指滚动的 lastScroll/residualWheel 状态。\n- 底部滚轮键的 SwiftUI DragGesture 保持独立，继续发 wheel，滚动速度/自然滚动只作用于它。\n- 宏录制：buttonDown / 逐帧 move / buttonUp 走既有 recordEvent 链路，回放可复现拖拽。\n- 触控区提示、滚动设置说明、设置页手势列表、preview/ui-preview.html 同步。\n报告格式与配对不变。注意：翻页/滚网页现在要用底部滚轮键，双指改为拖拽。"

commit = gh("POST", "/git/commits", {
    "message": msg, "tree": tree["sha"], "parents": [BASE]
})
print("new commit =", commit["sha"])

gh("PATCH", "/git/refs/heads/main", {"sha": commit["sha"], "force": False})
print("PUSHED main ->", commit["sha"])
