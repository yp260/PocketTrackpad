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

msg = "fix: 撤销触控板模式——iPad 出现触控板菜单是 iOS 硬限制，三指切 App 改挂复合模式\n\n用户实测 v0.0.49：iPad 未出现「触控板」菜单、三指左右滑不能切 App，确认手动 Cmd+Tab 能切。\n研究确认触控板菜单做不到：1) GAP 服务(0x1800，含外观 2A01)是蓝牙规范要求、由 iOS 系统强制管理，\n第三方 App 无法真正注册/覆盖，写的 Touchpad(0x03C9) 主机根本读不到；2) Apple 官方明确 iPad「触控板」\n菜单与原生三指/四指手势只对 Magic Trackpad 私有协议开放，第三方 BLE 设备拿不到。上一版说「有机会」过于乐观。\n三指切 App 失效主因：触控板模式把 Appearance 声明成 Touchpad 后 iPad 按触控板归类，不再把键盘报告当系统\n快捷键处理，掐断了 Cmd+Tab 通道（手动全键盘能切证明链路本身是好的）。\n修复：\n- 彻底撤销 trackpadMode 开关及其持久化、互斥联动、applyTrackpadModeChange、诊断条角色标识；\n- HIDDescriptor 删除 appearanceTouchpad；case 2A01 恢复 Mouse/Keyboard/Combo 三态；\n- 三指左右滑切 App 保留，改挂「键鼠复合模式」（与三指上滑 goHome 同一条已验证的键盘通道），\n  switchApp 的 Cmd+Tab / Cmd+Shift+Tab 与 Tab 键码 0x2B 不变；\n- 设置页把「三指左右滑」并入复合模式「实验功能·全键盘与手势」分组，删触控板 Section；\n- 顶栏「触控板模式」改「触控区」避免与已撤销开关混淆；preview/ui-preview.html 同步。\n重要：撤销后 iPad 缓存的仍是旧 Touchpad 归类，必须按辅助触控路径忽略设备重配，才会重读回 Keyboard 声明。\n报告格式不变，配对流程不变。"

commit = gh("POST", "/git/commits", {
    "message": msg, "tree": tree["sha"], "parents": [BASE]
})
print("new commit =", commit["sha"])

gh("PATCH", "/git/refs/heads/main", {"sha": commit["sha"], "force": False})
print("PUSHED main ->", commit["sha"])
