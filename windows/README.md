# PocketTrackpad 连 Windows —— 两种方式

目标：把 iPhone 变成 Windows 的鼠标 + 键盘。

- **方式 A（推荐 · 电脑零安装）**：iPhone 直接以 BLE 键鼠设备身份广播，Windows 在
  `设置 → 蓝牙和其他设备 → 添加设备` 里原生配对，**电脑端不装任何软件、不装驱动**。
- **方式 B（兜底 · 零硬件）**：电脑上跑一个脚本接收 WiFi 数据包并注入输入。需要装
  PowerShell（Windows 10/11 自带，不算安装）或 Python；仅当方式 A 在你的 Windows 版本
  上配不上时再用。

---

## 方式 A：系统原生添加（零安装，首选）

### 原理
App 开启「Windows 直连」后，iPhone 以标准 **HID over GATT** 组合设备（鼠标 + 键盘）身份广播。
Windows 的蓝牙栈会把它当成一台普通蓝牙键鼠，走系统自带的 HID 驱动，无需任何第三方程序。

### 步骤
1. **先断开 iPad。** iOS 作为 BLE 外设时，一旦被某台主机连接就会停止广播，Windows 因此搜不到。
   在 iPad「设置 → 辅助功能 → 触控 → 辅助触控 → 设备」里忽略本设备，并确认 iPhone 上 PocketTrackpad 当前没有连着 iPad。
2. 打开 PocketTrackpad → **设置** → 打开 **「Windows 直连（电脑零安装）**。
   开关会先断开现有连接、重建 GATT 服务（这一步是系统要求，无法热切换）。
3. **在 Windows 上**：`设置 → 蓝牙和其他设备 → 添加设备 → 其他设备（蓝牙）`，**保持这个窗口开着**。
4. 回到 iPhone，点右上角 **「开始广播」**。几秒后 Windows 列表里会出现你的 iPhone（设备名就是
   iPhone 的整机名，如 `iPhone` 或你改过的名字），点它完成配对。
5. 配对成功后即可用 iPhone 当触控板 + 键盘。

### 如果 Windows 列表里看不到 iPhone
Windows 11（尤其 24H2）的发现列表会按「设备类别（Appearance）」过滤，而 iOS **不允许 App 在
广播包里设置该字段**。两个解决办法：

- 在 Windows `设置 → 蓝牙和其他设备 → 设备` 的高级设置里，把 **「蓝牙设备发现」改为「高级」**；
- 或在「添加设备」页面点击 **「显示所有设备」**。

两种方式都能让没有标准 Appearance 的 iPhone 显示出来。打开高级发现后通常需要先取消再重新打开
「添加设备」窗口，让 Windows 重新扫描一轮。

### 注意
- 配对期间 App 必须**保持前台、屏幕常亮**。锁屏或切后台后 iOS 会停止 BLE 广播。
- 若要切回 iPad：先在 Windows 蓝牙里「移除」/「忽略」此设备，再回 iPhone 重新广播给 iPad。
- 部分 Windows 版本（尤其旧版或企业策略收紧的机器）对 iOS 外设的 HID over GATT 配对不完全兼容，
  可能搜到却卡在配对。此时请直接改用下方的**方式 B**。

---

## 方式 B：电脑端接收器（兜底，零硬件）

当方式 A 在你的 Windows 上配不上时，用这个。iPhone 不再广播 BLE，改为通过 WiFi 把输入发给
电脑上的接收器，由接收器用 `SendInput` 注入真实鼠标键盘事件。

### 零安装版（PowerShell，Windows 自带）
`pt_receiver.ps1` 用系统自带 PowerShell + 内置的 C# 编译能力，无需安装 Python 或任何运行时。

```powershell
cd <本仓库>\windows
# 双击 start_receiver.bat 也行
powershell -NoProfile -ExecutionPolicy Bypass -File .\pt_receiver.ps1
```

看到 `listening on UDP port 5000 ... Waiting for the iPhone` 即启动成功。
首次运行 Windows 防火墙若询问「是否允许访问网络」，选 **允许**。

### 手机端设置
1. PocketTrackpad → **设置** → 打开 **「桥接（WiFi 转发）」**。
2. **桥接端地址** 填电脑的局域网 IP（PowerShell 里 `ipconfig` 查 IPv4，形如 `192.168.1.100`），
   端口 `5000`，点 **「保存地址」**。
3. 回主页面点 **「连接桥接」**。电脑端出现 `handshake done` 即成功。

### 常用参数（PowerShell 版）
| 参数 | 作用 |
| --- | --- |
| `--port 5001` | 换端口（手机端端口同步改） |
| `--rel` | 鼠标改相对移动（默认绝对定位，手指与指针 1:1） |
| `--dry-run` | 只解析打印，不真的动鼠标 |
| `--selftest` | 自检本机 SendInput 是否可用 |
| `--verbose` | 打印每条收到的报告 |

> Python 版 `pt_receiver.py` 已移除；PowerShell 版功能与协议完全一致，且零安装。

---

## 键盘与选词
两种方式下，App 全键盘页发的是标准 USB HID 键码。Windows 上候选词本来就能用 **方向键 + 空格**
或 **数字** 直接选，不存在 iPad 那种需要实体键盘才出数字选词的问题。
`Win + D` 显示桌面（App 的三指上滑 `Command + H` 只对 iPadOS 有效）。
