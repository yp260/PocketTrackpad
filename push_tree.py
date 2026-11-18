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
    "fix: 修正 inputReport 创建顺序 —— 报告特征未进 GATT 是真凶\n\n"
    "真机串口决定性证据：[BLE] 主机已连接 + subscribe event attr_handle=26 subscribed:true，\n"
    "但 [STAT] subscribed=0 —— iPad 订阅的是别的特征，我们 notify 的是幽灵特征。\n"
    "- 根因：main.cpp 先 startServices() 再 inputReport(0)。NimBLE 1.4.3 的 inputReport() 内部是 createCharacteristic()，\n"
    "  而 startServices() 只注册调用那一刻已存在的特征（源码 NimBLEService::start 的 'Adding %d characteristics'）。\n"
    "  晚创建的报告特征不在 GATT 数据库，主机无法订阅，notify 全丢 -> 连上却键鼠无反应。\n"
    "- 修复：把 inputReport(0)+setCallbacks 移到 startServices() 之前，顺序 reportMap->inputReport->setBatteryLevel->startServices。\n"
    "- 加 ReportCharCallbacks::onSubscribe 与 [DIAG] handle 打印，下轮可确认句柄一致。\n"
    "- 保留上轮改名 PT-Pad-S3 + bonding 修复（均已生效：这次 iPad 真连上了）。",
    ensure_ascii=False
)

commit = gh("POST", "/git/commits", {
    "message": msg, "tree": tree["sha"], "parents": [BASE]
})
print("new commit =", commit["sha"])

gh("PATCH", "/git/refs/heads/main", {"sha": commit["sha"], "force": False})
print("PUSHED main ->", commit["sha"])
