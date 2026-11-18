# PocketTrackpad 硬件桥固件（ESP32）

把 iPhone 采集到的触控板/键盘输入，通过 WiFi UDP 收进来，再以**标准 BLE HID**（带正确 GAP
Appearance = `0x03C0` Generic HID 复合设备，键盘 Collection 排描述符最前）转发给
Windows / Android / iPad。解决两个 iOS 蓝牙外设的硬限制：
1. Windows 搜不到 / 配对失败（iOS 无法设置 GAP Appearance）；
2. iPad 不把复合设备当实体键盘（软键盘不隐藏、输入法候选词不能用数字选词）——
   描述符排列与 Appearance 都由 ESP32 补齐后，行为与实体键鼠一体键盘一致。

## 硬件

- **ESP32-S3-DevKitC-1**（原厂，模组为 ESP32-S3-WROOM-1-N16R8：16MB Flash + 8MB 八线 PSRAM，双 USB 口）。
  其他带 WiFi + BLE 的 ESP32（C3 / 普通 ESP32）也能用，换板只需改 `platformio.ini` 的 `board`。
  本固件不启用 PSRAM（RAM 占用仅 16%，用不到），按默认 4MB/DIO 编译；16MB Flash 向下兼容，
  直接烧录即可正常启动。若将来要用到 PSRAM，需在 `platformio.ini` 配 `board_build.arduino.memory_type=qio_opi`
  + `board_upload.flash_size=16MB` + `board_build.partitions=default_16MB.csv` + `-DBOARD_HAS_PSRAM`，
  但本项目没有收益，不建议开启（PSRAM 模式配错反而会导致启动失败）。
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
到 Actions 页面下载固件产物。产物里有两种文件：

- **`PT-Bridge-ESP32S3-merged.bin`**（推荐）：bootloader + 分区表 + 固件打成的单个镜像，
  一条命令烧到 0x0 即可：

```bash
esptool.py --chip esp32s3 --port COMx write_flash 0x0 PT-Bridge-ESP32S3-merged.bin
```

- 分开的文件（`bootloader.bin` / `partitions.bin` / `firmware.bin`）：需要按各自地址烧录，
  不要只把 `firmware.bin` 烧到 0x0（那样缺引导程序，板子起不来）：

```bash
esptool.py --chip esp32s3 --port COMx write_flash \
  0x0 bootloader.bin 0x8000 partitions.bin 0x10000 firmware.bin
```

`COMx` 换成实际串口号（设备管理器里看，或用 `pio device list`）。烧完按 EN 复位。

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

- **Appearance 必须用 `0x03C0`（复合 HID），不可用 `0x03C1`（纯键盘）**：2026-11-18 真机实测——用 `0x03C1` 时 iPad 能配对成功但「完全没有指针」，因为 iPad 只把它当键盘、不创建鼠标指针通道。改成 `0x03C0`（Generic HID 复合设备）后 iPad 同时建键盘+鼠标通道。也不可退到 `0x03C2`（纯鼠标），那样键盘报告不再被当系统快捷键。Windows 11 从 2023-09 起只要求广播里「有」Appearance 元素、不挑具体值，`0x03C0` 同样能发现配对。改 Appearance 后 iPad 必须在「辅助功能→触控→辅助触控→设备」里忽略旧配对重新配，否则沿用缓存的旧声明。
- **platform 必须锁 `espressif32@6.13.0`（arduino-esp32 2.0.17 / IDF 4.4.7）**：NimBLE-Arduino 1.4.3 只兼容 arduino-esp32 2.x。若写成 `platform = espressif32` 不锁版本，CI 会拉到 8.x（arduino 3.3 / IDF 5.5），编译能过但运行时 `NimBLEDevice::init()` 空指针崩溃（串口 `Guru Meditation Error: Core 1 panic'ed (LoadProhibited)`, `EXCVADDR 0x5004c`），表现为 AP 打印出来后立刻无限重启、手机扫不到 `PT-Bridge`。2026-11-18 真机实测确认，已锁定版本修复。
- 报告布局（12 字节顺序）与 iOS 端 `PocketTrackpad/HIDDescriptor.swift` 的 `compositeReportMap`
  必须保持一致；任一侧改动都要同步另一侧。
- Windows 首次配对可能弹提示，配对一次即可。
- ESP32-S3 同时跑 WiFi（AP）与 BLE（HID），芯片原生支持 2.4GHz 共存，无需额外配置。
- S3 有两个 USB 口：烧录与看日志请用底部**左边**的 USB-UART 口（原生 USB-OTG 那个口本固件不启用，接了不会有串口输出，容易误判为「烧录失败」）。如果第一次烧录没反应，换到左边口再试。
