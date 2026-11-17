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

msg = "refactor: 彻底删除电脑端软件接收器（ps1/Python），连电脑统一走 ESP32 硬件桥\n\n用户要求任何新电脑零安装直接连接，明确选择彻底删掉 ps1 那条路。\n- 删除 windows/ 整个目录：pt_receiver.ps1、start_receiver.bat、ble_scan.ps1、README.md。\n- ContentView / HIDPeripheral / BridgeTransport / Info.plist：所有引导文案、注释、日志改为\n  ESP32 硬件桥单一方案——手机连 PT-Bridge 热点、地址 192.168.4.1、电脑系统蓝牙配对 PT-Pad，\n  电脑端零安装（只需自带蓝牙）。\n- README.md：当前连接章节改 ESP32；删除整节历史「电脑端软件接收器」开发日志（33 节末尾）。\n- preview/ui-preview.html：设置页、元素清单、交互日志同步。\n保留 scripts/ 下的 make_installable_ipa.ps1 / sideload_one_click.ps1（那是给 IPA 签名装手机的，\n与电脑连接键鼠无关）。bridge UDP 协议、12 字节报告格式、宏录制回放全部不变。"

commit = gh("POST", "/git/commits", {
    "message": msg, "tree": tree["sha"], "parents": [BASE]
})
print("new commit =", commit["sha"])

gh("PATCH", "/git/refs/heads/main", {"sha": commit["sha"], "force": False})
print("PUSHED main ->", commit["sha"])
