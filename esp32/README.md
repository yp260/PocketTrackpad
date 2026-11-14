# PocketTrackpad 硬件桥固件（ESP32）

把 iPhone 采集到的触控板/键盘输入，通过 WiFi UDP 收进来，再以**标准 BLE HID**（带正确 GAP
Appearance = `0x03C2`）转发给 Windows / Android。解决的是 iOS 蓝牙外设无法被 Windows 发现的问题。

## 硬件

- 任意带 WiFi + BLE 的 ESP32 开发板，推荐 **ESP32-C3**（如 `esp32-c3-devkitm-1`，约 9~20 元）。
  换板只需改 `platformio.ini` 的 `board`。
- 一根 USB 数据线（用于烧录与供电）。

## 编译与烧录（本地）

```bash
# 安装 PlatformIO（需要 Python 3）
pip install -U platformio

# 编译并烧录（自动选端口）
pio run -d esp32 -t upload

# 查看串口日志（确认 AP IP、UDP 端口、BLE 广播）
pio device monitor -b 115200
```

不想装本地工具链的话，推送本仓库后 GitHub Actions 的 `Build ESP32 firmware` 会自动编译，
到 Actions 页面下载 `firmware.bin` 产物，用 `esptool` 烧录：

```bash
esptool.py --chip esp32c3 --port COMx write_flash 0x0 firmware.bin
```

## 使用流程

1. 上电后 ESP32 会发出名为 **`PT-Bridge`** 的开放 WiFi 热点（无密码）。
2. iPhone 在「设置 → 无线局域网」连上 `PT-Bridge`。
3. 打开 PocketTrackpad App，设置里开启「启用硬件桥（ESP32）」，再点右上角「连接硬件桥」。
4. 状态变「已连接硬件桥」后，在 Windows / Android 的蓝牙里搜索，会看到 **PT-Pad**，
   配对后即可像用鼠标+键盘一样控制。

## 与 iPhone 端的协议

- iPhone 每约 16ms 发送一条 **12 字节复合 HID 报告**，布局与 App 内 `HIDSpec.compositeReportMap`
  逐字节对应：`[buttons, dx, dy, wheel, modifier, reserved, key1..key6]`。
- 连接建立前，iPhone 先发 2 字节 hello `[0x50,0x54]`（"PT"），本固件回 `[0x54,0x50]`（"TP"），
  iPhone 收到后判定为「已连接」。

## 注意

- 报告布局（12 字节顺序）与 iOS 端 `PocketTrackpad/HIDDescriptor.swift` 的 `compositeReportMap`
  必须保持一致；任一侧改动都要同步另一侧。
- Windows 首次配对可能弹提示，配对一次即可。
- ESP32 同时跑 WiFi（AP）与 BLE（HID），ESP32-C3 原生支持共存，无需额外配置。
