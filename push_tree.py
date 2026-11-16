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

msg = "feat: 主键位三键循环换位 + 修复宏回放点击位置整体偏移\n\n用户两项反馈：\n1) 主键位 ↓(下) / ⌫(退格) / ↑(上) 三键循环换位——下键移到控制行原退格位、退格键移到 M 行末尾原上键位、上键移到导航行原下键位。KeyboardView.swift 的 controlRow 与 rows(for:.letters) 调整，preview/ui-preview.html 同步并补两条变更记录。\n2) 宏录制/回放点击位置整体偏移。根因：flush 用 Int8(clamping:) 后立即把 pendingX/pendingY 清零，超 1 字节范围的位移被直接丢弃。录制时位移逐帧小增量不超限，但 recordEvent 30ms 合并后宏里存的是累加的大位移，回放时一次性 enqueue 超过 127 的部分被截断丢掉，轨迹逐段缩短、点击落点整体偏移。修复：改为 pendingX -= Int(x) 发多少减多少，余数留到下一帧续发，录制/回放走完全相同的位移总量。好处是改发送端，已保存的旧宏回放也自动正确，无需重录。无报告格式/协议变更。"

commit = gh("POST", "/git/commits", {
    "message": msg, "tree": tree["sha"], "parents": [BASE]
})
print("new commit =", commit["sha"])

gh("PATCH", "/git/refs/heads/main", {"sha": commit["sha"], "force": False})
print("PUSHED main ->", commit["sha"])
