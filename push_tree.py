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

msg = "feat: 删除 Windows 直连功能——连 Windows 统一走桥接方案\n\n用户反馈 Windows 直连（原生 BLE HID 双报告拓扑）没法用，要求直接删除。\n彻底移除 windowsMode 及其全部支撑代码，保留桥接（WiFi 转发）作为连 Windows 的唯一方式。\n实现：\n- HIDDescriptor：删除 win* 双报告描述符、Report ID 常量、winMouseReport/winKeyboardReport 组装函数、appearanceCombo。\n- HIDPeripheral：删除 windowsMode 持久化开关、inputReport2/keyboardSubscribed/databaseWindowsMode 字段、\n  GATT 双报告拓扑与模式迁移检查、switchToiPadMode、sendKey/flush/readValue/didReceiveRead/订阅回调的 windows 分支。\n- ContentView：删除设置页「Windows 直连」开关、未连接页 windowsMode 分支与一键切回按钮、各处引导文案，\n  改为引导桥接方案。\n- 文档：README.md、windows/README.md、BridgeTransport 注释同步，windows/README 重写为桥接单一方案。\n报告格式与 iPad 配对不变；纯鼠标 / 键鼠复合 / 桥接三种模式不受影响。"

commit = gh("POST", "/git/commits", {
    "message": msg, "tree": tree["sha"], "parents": [BASE]
})
print("new commit =", commit["sha"])

gh("PATCH", "/git/refs/heads/main", {"sha": commit["sha"], "force": False})
print("PUSHED main ->", commit["sha"])
