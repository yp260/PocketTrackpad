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
    "fix: 彻底移除断联自动重播 + 蓝牙图标与跳转修复（v0.0.63）\n\n"
    "用户实测反馈：断联和重播还是老问题不断；蓝牙设置入口图标没显示，点了只进本 App 设置页，要的是系统蓝牙页。\n"
    "- 根因：ensureAdvertisingAfterDisconnect 在订阅归零/连接断开时做 stopAdvertising → 0.6s → startAdvertising 自动重播；iPad HID 主机频繁瞬断瞬连，每次都触发一轮重播，界面反复闪跳，延时闭包还和手动开始广播打架。\n"
    "- 删除 ensureAdvertisingAfterDisconnect 与 advertisingResumeScheduled 字段及复位；新增 handleHostDisconnected 只更新状态、绝不自动重播；重连必须显式点「开始广播」。\n"
    "- 蓝牙图标：.footnote Image 在拥挤工具栏被压成不可见，改固定 24x24 蓝色圆徽标。\n"
    "- 跳转：App-Prefs:root=Bluetooth 新版 iOS 失效，改链式尝试 App-Prefs:Bluetooth → App-Prefs:root=Bluetooth → openSettingsURLString，用 open completion.success 判断。\n"
    "- HIDPeripheral/ContentView + preview/README 同步（JS 语法已校验）。",
    ensure_ascii=False
)

commit = gh("POST", "/git/commits", {
    "message": msg, "tree": tree["sha"], "parents": [BASE]
})
print("new commit =", commit["sha"])

gh("PATCH", "/git/refs/heads/main", {"sha": commit["sha"], "force": False})
print("PUSHED main ->", commit["sha"])
