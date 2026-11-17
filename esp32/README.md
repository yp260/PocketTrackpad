# PocketTrackpad 硬件桥固件（ESP32）

把 iPhone 采集到的触控板/键盘输入，通过 WiFi UDP 收进来，再以**标准 BLE HID**（带正确 GAP
Appearance = `0x03C1` HID Keyboard，v0.0.18 起键盘 Collection 排描述符最前）转发给
Windows / Android / iPad。解决两个 iOS 蓝牙外设的硬限制：
1. Windows 搜不到 / 配对失败（iOS 无法设置 GAP Appearance）；
2. iPad 不把复合设备当实体键盘（软键盘不隐藏、输入法候选词不能用数字选词）——
   描述符排列与 Appearance 都由 ESP32 补齐后，行为与实体键鼠一体键盘一致。

## 硬件

- **ESP32-S3-DevKitC-1**（原厂，ESP32-S3-WROOM-1 模组，512KB SRAM，无 PSRAM，双 USB 口）。
  其他带 WiFi + BLE 的 ESP32（C3 / 普通 ESP32）也能用，换板只需改 `platformio.ini` 的 `board`。
- 一根 USB 数据线：接板子**底部左边那个 USB-UART 口**（串口日志走 UART0，TX=GPIO43 / RX=GPIO44）。
  右边那个是原生 USB-OTG，本固件不用。

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
esptool.py --chip esp32s3 --port COMx write_flash 0x0 firmware.bin
```

## 使用流程

1. 上电后 ESP32 会发出名为 **`PT-Bridge`** 的开放 WiFi 热点（无密码）。
2. iPhone 在「设置 → 无线局域网」连上 `PT-Bridge`。
3. 打开 PocketTrackpad App，设置里开启「桥接（WiFi 转发）」，把地址填成热点网关 `192.168.4.1`
   （端口 5000，默认即是），再点右上角「连接桥接」。
4. 状态变「已连接桥接」后，在 Windows / Android 的蓝牙里搜索，会看到 **PT-Pad**，
   配对后即可像用鼠标+键盘一样控制。

## 与 iPhone 端的协议

- iPhone 每约 16ms 发送一条 **12 字节复合 HID 报告**，布局与 App 内 `HIDSpec.compositeReportMap`
  逐字节对应（v0.0.18 起键盘字段在前）：`[modifier, reserved, key1..key6, buttons, dx, dy, wheel]`。
- 连接建立前，iPhone 先发 2 字节 hello `[0x50,0x54]`（"PT"），本固件回 `[0x54,0x50]`（"TP"），
  iPhone 收到后判定为「已连接」。

## 注意

- 报告布局（12 字节顺序）与 iOS 端 `PocketTrackpad/HIDDescriptor.swift` 的 `compositeReportMap`
  必须保持一致；任一侧改动都要同步另一侧。
- Windows 首次配对可能弹提示，配对一次即可。
- ESP32-S3 同时跑 WiFi（AP）与 BLE（HID），芯片原生支持 2.4GHz 共存，无需额外配置。
- S3 有两个 USB 口：烧录与看日志请用底部**左边**的 USB-UART 口（原生 USB-OTG 那个口本固件不启用，接了不会有串口输出，容易误判为「烧录失败」）。如果第一次烧录没反应，换到左边口再试。
