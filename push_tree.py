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
    "feat(ios): 添加用户指定的鼠标 App 图标\n\n"
    "此前项目没有任何 AppIcon 资源，生成的 IPA 桌面图标为空。\n"
    "- Assets.xcassets/AppIcon.appiconset/: 新增 Icon-1024.png + Contents.json。\n"
    "  图标为用户提供的深灰鼠标图（带弯曲线缆/滚轮/按键分割线）。原图 201x239\n"
    "  的透明底被拍平成棋盘格，已用边缘泛洪抠除棋盘格、保留内部白色分隔线，\n"
    "  再居中铺到 1024x1024 浅灰底上。\n"
    "- project.yml: Assets.xcassets 显式进 Resources 构建阶段；设置\n"
    "  ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon，避免自定义 Info.plist 下\n"
    "  actool 不知道哪个是主图标。\n"
    "- Info.plist: 新增 CFBundleIconName=AppIcon。\n"
    "- 功能代码、Report Map、ESP32 桥接、GATT 拓扑全部不动。",
    ensure_ascii=False
)

commit = gh("POST", "/git/commits", {
    "message": msg, "tree": tree["sha"], "parents": [BASE]
})
print("new commit =", commit["sha"])

gh("PATCH", "/git/refs/heads/main", {"sha": commit["sha"], "force": False})
print("PUSHED main ->", commit["sha"])
