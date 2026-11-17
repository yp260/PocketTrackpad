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

msg = "docs: 纠正硬件说明——模组为 ESP32-S3-WROOM-1-N16R8（16MB Flash + 8MB PSRAM）\n\n用户看商品页纠正：模组实为 N16R8，非此前误判的「无 PSRAM」版。\nesp32/README.md：硬件说明改为 N16R8，并补充 PSRAM 兼容结论——本固件不启用 PSRAM\n（按 4MB/DIO 编译，16MB Flash 向下兼容、DIO 最保守），直接烧录正常；列出将来启用 PSRAM\n所需的 qio_opi/16MB 分区表配置，但说明本项目无收益不建议开。\n固件二进制内容不变，仅文档纠正。"

commit = gh("POST", "/git/commits", {
    "message": msg, "tree": tree["sha"], "parents": [BASE]
})
print("new commit =", commit["sha"])

gh("PATCH", "/git/refs/heads/main", {"sha": commit["sha"], "force": False})
print("PUSHED main ->", commit["sha"])
