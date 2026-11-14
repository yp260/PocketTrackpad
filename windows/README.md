# PocketTrackpad Windows 接收器（零硬件方案）

让 iPhone 变成 Windows 的鼠标 + 键盘，**不需要 ESP32、不需要蓝牙配对、只需要一台 Windows 电脑**。

## 为什么需要它

iPhone 通过 CoreBluetooth 把自己伪装成蓝牙键鼠外设时，iOS 不允许 App 设置广播包里的
**GAP Appearance**（设备类别标识）。Windows 11 的蓝牙发现会过滤掉没有标准类别标识的
外设，所以「蓝牙设备」列表里根本看不到本机——这是**平台限制，不是 App 的 Bug**，iOS 侧
无论怎么改描述符都绕不过去。

这个接收器把「蓝牙」这一环整个去掉：

```
iPhone 采集输入
   │  WiFi / UDP（局域网）
   ▼
Windows 上的 pt_receiver.py
   │  Win32 SendInput 注入
   ▼
Windows 看到的就是一个真实的鼠标 + 键盘
```

协议与仓库里的 ESP32 固件**完全一致**（12 字节复合 HID 报告 + `PT`/`TP` 握手），
两种桥接端可以随时互换。

## 前提

- Windows 10 / 11
- Python 3.8 或更新版本（[python.org](https://www.python.org/downloads/) 安装时勾选
  **Add python.exe to PATH**）
- iPhone 与电脑连**同一个 WiFi**

不需要管理员权限，不需要安装任何第三方包（只用 Python 标准库 + ctypes）。

## 三步连上

### 1. 电脑上启动接收器

在 PowerShell 或 CMD 里：

```powershell
cd <本仓库>\windows
py -3 pt_receiver.py
```

看到这样的输出就说明启动好了：

```
PocketTrackpad receiver listening on UDP port 5000
  mouse mode : absolute (1:1)
  output     : real input via SendInput
Waiting for the iPhone...
```

> 首次运行时 Windows 防火墙会弹窗询问「是否允许 Python 访问网络」，
> **必须选「允许」**，否则手机发过来的包会被防火墙拦掉。

### 2. 查电脑的局域网 IP

```powershell
ipconfig
```

找「无线局域网适配器 WLAN」或「以太网适配器」下面的 **IPv4 地址**，
形如 `192.168.1.100`。

### 3. 手机上设置地址

1. 打开 PocketTrackpad → **设置**
2. 打开 **「桥接（WiFi 转发）」** 里的 **「启用桥接（WiFi 转发）」** 开关
3. **桥接端地址** 填电脑的 IP（如 `192.168.1.100`），端口保持 `5000`
4. 点 **「保存地址」**
5. 回到主页面，点右上角 **「连接桥接」**

电脑端窗口里出现 `[hello] 192.168.1.x:xxxxx -- handshake done` 即握手成功，
手机顶部显示「已连接」。之后手指在手机上滑动，Windows 的鼠标指针就会跟着动。

> 如果手机先连、电脑后启动接收器：在设置页点一下 **「重新握手」** 即可立刻建立链路。

## 常用参数

| 参数 | 作用 |
| --- | --- |
| `--port 5001` | 换端口（手机端地址里的端口要同步改） |
| `--rel` | 鼠标改用**相对**移动（默认是绝对定位，手指与指针 1:1，不受 Windows 指针加速影响） |
| `--dry-run` | 只解析并打印收到什么，不真的动鼠标（排查用） |
| `--selftest` | 自检：验证本机 `SendInput` 是否可用 |
| `--verbose` | 打印每一条收到的报告 |

## 键盘

App 的全键盘页发送的是标准 USB HID 键码，接收器会转换成 Windows 虚拟键码，
因此：

- 字母、数字、符号（含 Shift 组合）都能正常输入
- 方向键、Home / End / PageUp / PageDown、F1–F12、Tab、Esc、Backspace、Enter 都有
- **Win + D** 可以显示桌面（App 的三指上滑是 Command + H，只对 iPadOS 有效）

App 侧的中文输入法选词问题在 Windows 上不存在——Windows 上的候选词本来就可以直接用
方向键 + 空格选中。

## 常见问题

**Q：手机显示「已连接」，但电脑鼠标不动？**
A：检查 Windows 防火墙是否允许 Python 访问「专用网络」。可以临时关掉防火墙验证：
```powershell
# 需要管理员权限的 PowerShell
Set-NetFirewallProfile -Profile Private -Enabled False
```
验证完记得改回来。

**Q：接收器显示 `[skip] N bytes`？**
A：说明收到的不是 12 字节报告，通常是 iPhone 还没连上桥接端，或地址填错了。

**Q：鼠标移动太快 / 太慢？**
A：鼠标速度在 App 的「设置 → 指针 → 指针速度」里调（默认 1.4×）。
绝对定位模式下这个倍率直接对应像素比例。

**Q：能让 Android 平板也用吗？**
A：Android 平板需要真的 BLE HID 外设，走 ESP32 那条路（手机连 `PT-Bridge` 热点，
地址填 `192.168.4.1`）。这个 Python 接收器只对 Windows 有效。

**Q：电脑休眠后还能用吗？**
A：不能。休眠会中断 WiFi，接收器进程也会被挂起。唤醒后重新运行接收器，
手机端点一下「重新握手」。

## 安全性

接收器只监听 UDP 5000 端口，只处理本仓库定义的两种报文（2 字节握手、12 字节报告），
不做任何网络请求、不落盘、不上传数据。数据全程在你自己的局域网内。
