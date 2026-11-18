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
    "fix: ESP32 桥改名 PT-Pad-S3 + 开 bonding，修复 iPad 假连接/不订阅报告\n\n"
    "诊断实测：report 一路涨到 1412（手机->ESP32 全通），但串口从无 [BLE] 主机已连接、subscribed 恒为 0。\n"
    "根因两个叠加：\n"
    "1) 设备名 PT-Pad 与旧 iPhone 软件方案同名，iOS 当已知 HID 自动重连旧记录、不扫新板 -> iPad 假「已连接」，根本没连到 ESP32。改名 PT-Pad-S3 强制重新发现配对。\n"
    "2) setSecurityAuth(false,false,false) 全关 bonding，iOS 对第三方 HID 不配对就不订阅 Input Report -> subscribed=0、连上也没输入。改 (true,false,false) Just Works 静默配对。\n"
    "- 保留诊断：onConnect 打 [BLE] 主机已连接，[STAT] 打 hello/report/subscribed。\n"
    "- esp32/README.md 记录此坑。iPad 需搜新名 PT-Pad-S3 重新配对。",
    ensure_ascii=False
)

commit = gh("POST", "/git/commits", {
    "message": msg, "tree": tree["sha"], "parents": [BASE]
})
print("new commit =", commit["sha"])

gh("PATCH", "/git/refs/heads/main", {"sha": commit["sha"], "force": False})
print("PUSHED main ->", commit["sha"])
