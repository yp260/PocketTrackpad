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

msg = "fix: 宏回放落点偏移且每次不同——逐帧复现位移序列 + 合并回放调度到同一 tick\n\n用户反馈 v0.0.46 后仍偏移且每次偏移量不同。真根因是帧序列不匹配 + iPadOS 非线性指针加速：\n1) 录制时 enqueue 的位移按 30ms 合并成大值存进宏，回放一次性注入、一帧发出；而 iPadOS 对 HID 相对位移有非线性加速——同样总位移，逐帧小增量发出与合成一个大帧发出，屏幕实际移动距离不同，落点必然偏移。\n2) 回放调度用独立 playbackLink，与负责发送的 tick 相位不定，同一位移每次被拆成的帧序列都不同，叠加指针加速就表现为「每次偏移量都不一样」。\n修复：\n- 录制改为在 flush() 里记录「本帧真正发出的位移值」（已 clamp 的 x/y/w，逐帧），不再在 enqueue 记手势原始增量，去掉 30ms 合并；\n- 删除独立 playbackLink，回放注入并入 tick()（pumpPlayback），注入与发送同帧；\n- pumpPlayback 每帧最多注入一条位移事件，强制把位移摊到多帧，一比一复现录制帧序列；非位移事件可同帧注入。\n注意：录制格式变更，旧宏需重新录制才能受益。录制/回放仍走同一 BLE HID 链路，报告格式与配对不变。"

commit = gh("POST", "/git/commits", {
    "message": msg, "tree": tree["sha"], "parents": [BASE]
})
print("new commit =", commit["sha"])

gh("PATCH", "/git/refs/heads/main", {"sha": commit["sha"], "force": False})
print("PUSHED main ->", commit["sha"])
