# PocketTrackpad 连 Windows —— 桥接方案（零硬件、零安装）

目标：把 iPhone 变成 Windows 的鼠标 + 键盘。

由于 iOS 的 CoreBluetooth 外设无法在广播里设置 GAP Appearance（设备类别），而 Windows 11
（尤其 24H2）的蓝牙发现列表按类别过滤，原生 BLE 直连始终不稳定，**该方案已移除**。
目前连接 Windows 只有一种方式：**桥接** —— iPhone 不再广播 BLE，改为通过 WiFi 把输入发给
电脑上的接收器，由接收器用 `SendInput` 注入真实鼠标键盘事件。电脑端用系统自带的 PowerShell，
零安装、零硬件。

---

## 电脑端：运行接收器（PowerShell，Windows 自带）

`pt_receiver.ps1` 用系统自带 PowerShell + 内置的 C# 编译能力，无需安装 Python 或任何运行时。

```powershell
cd <本仓库>\windows
# 双击 start_receiver.bat 也行
powershell -NoProfile -ExecutionPolicy Bypass -File .\pt_receiver.ps1
```

看到 `listening on UDP port 5000 ... Waiting for the iPhone` 即启动成功。
首次运行 Windows 防火墙若询问「是否允许访问网络」，选 **允许**。
手机与电脑必须连同一个 WiFi。

---

## 手机端设置

1. PocketTrackpad → **设置** → 打开 **「桥接（WiFi 转发）」**。
2. **桥接端地址** 填电脑的局域网 IP（PowerShell 里 `ipconfig` 查 IPv4，形如 `192.168.1.100`），
   端口 `5000`，点 **「保存地址」**。
3. 回主页面点 **「连接桥接」**。电脑端出现 `handshake done` 即成功。

---

## 常用参数（PowerShell 版）

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

App 全键盘页发的是标准 USB HID 键码。Windows 上候选词本来就能用 **方向键 + 空格**
或 **数字** 直接选，不存在 iPad 那种需要实体键盘才出数字选词的问题。
`Win + D` 显示桌面（App 的三指上滑 `Command + H` 只对 iPadOS 有效）。

---

## 想用 ESP32 / Android 而非电脑？

桥接协议对接收端一致（12 字节复合 HID 报告 + `PT`/`TP` 握手），可改用 ESP32 固件
（见 `esp32/` 目录）：手机连 `PT-Bridge` 热点，地址填默认的 `192.168.4.1` 即可。
