# PocketTrackpad 硬件桥固件（ESP32）

把 iPhone 采集到的触控板/键盘输入，通过 WiFi UDP 收进来，转成标准 HID，同时走**两条通道**发给目标设备：

- **BLE HID**（无线）：Appearance = `0x03C0` Generic HID 复合设备，键盘 Collection 排描述符最前，
  给 **iPad**（这台老 Broadcom 4.0 适配器的 Windows 搜不到纯 BLE HID，所以 Windows 改走下面这条）。
- **USB HID**（有线）：ESP32-S3 原生 USB-OTG 口枚举成标准键鼠（boot 协议，Windows 免驱），
  给 **Windows**。收到一条 12 字节报告时两条通道同时发，iPad/Windows 各自解析。

解决两个 iOS 蓝牙外设的硬限制：
1. iPad 不把复合设备当实体键盘（软键盘不隐藏、输入法候选词不能用数字选词）——
   描述符排列与 Appearance 都由 ESP32 补齐后，行为与实体键鼠一体键盘一致。
2. Windows 端：ESP32-S3 是 BLE-only 芯片（硬件不支持经典蓝牙 BR/EDR），而这台 Windows 的
   老 Broadcom 4.0 适配器搜不到纯 BLE HID。改用原生 USB HID 后 Windows 免驱、零延迟。

## 硬件

- **ESP32-S3-DevKitC-1**（原厂，模组为 ESP32-S3-WROOM-1-N16R8：16MB Flash + 8MB 八线 PSRAM，双 USB 口）。
  其他带 WiFi + BLE 的 ESP32（C3 / 普通 ESP32）也能用，换板只需改 `platformio.ini` 的 `board`。
  本固件不启用 PSRAM（RAM 占用仅 16%，用不到），按默认 4MB/DIO 编译；16MB Flash 向下兼容，
  直接烧录即可正常启动。若将来要用到 PSRAM，需在 `platformio.ini` 配 `board_build.arduino.memory_type=qio_opi`
  + `board_upload.flash_size=16MB` + `board_build.partitions=default_16MB.csv` + `-DBOARD_HAS_PSRAM`，
  但本项目没有收益，不建议开启（PSRAM 模式配错反而会导致启动失败）。
- **两根 USB 数据线**（或两个口同时接）：
  - **底部左边 USB-UART 口**（TX=GPIO43 / RX=GPIO44）：烧录 + 看串口日志，接电脑任意 USB 口。
  - **右边原生 USB-OTG 口**（GPIO19/20）：USB HID 键鼠，接 **Windows** 那台电脑，免驱识别为键鼠。
  - 注意：烧录必须走左边口（upload 用 UART，不走 native USB）；Windows 键鼠必须接右边口（左边是串口芯片，不会出 HID）。

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

- **【最关键的坑】`inputReport(0)` 必须在 `startServices()` 之前调用**：NimBLE 1.4.3 里 `inputReport()` 内部是 `createCharacteristic()`（源码 NimBLEHIDDevice.cpp:145），而 `startServices()`→`NimBLEService::start()` 只把调用那一刻 `m_chrVec` 里已有的特征注册进 GATT 数据库（源码打日志 `Adding %d characteristics`）。若像早期版本那样先 `startServices()` 再 `inputReport(0)`，报告特征不在 GATT 里，主机看到的是别的特征（实测 attr_handle=26）、`getSubscribedCount()` 恒为 0、notify 全发到幽灵特征——表现就是「iPad 显示已连接、连上了，但键鼠完全没反应」。2026-11-18 真机串口抓到 `[BLE] 主机已连接` + `subscribe event attr_handle=26` 但 `[STAT] subscribed=0` 的矛盾后定位。正确顺序：`reportMap()` → `inputReport(0)` → `setBatteryLevel()` → `startServices()`。
- **设备名用 `PT-Pad-S3`，且必须开 bonding（`setSecurityAuth(true,false,false)`）**：2026-11-18 真机实测——原名 `PT-Pad` 与之前 iPhone 纯软件方案同名，iOS 把同名 HID 记为「已知设备」自动重连旧记录、不再扫描新板，iPad 上显示「已连接」却是假象（串口无 `[BLE] 主机已连接`、`subscribed=0`）。换名 `PT-Pad-S3` 强制重新发现配对。同时 iOS/iPadOS 对第三方 BLE HID 要求先配对存长期密钥才订阅 Input Report 特征，原 `setSecurityAuth(false,false,false)` 全关导致 `subscribed=0`、连上却收不到任何输入；改 `true,false,false`（bonding 开、无 MITM、Just Works 静默配对）后 iPad 才会订阅。诊断依据：`main.cpp` 每 3 秒打印 `[STAT] hello/report/subscribed`，及 `onConnect` 打印 `[BLE] 主机已连接`。
- **Appearance 必须用 `0x03C0`（复合 HID），不可用 `0x03C1`（纯键盘）**：2026-11-18 真机实测——用 `0x03C1` 时 iPad 能配对成功但「完全没有指针」，因为 iPad 只把它当键盘、不创建鼠标指针通道。改成 `0x03C0`（Generic HID 复合设备）后 iPad 同时建键盘+鼠标通道。也不可退到 `0x03C2`（纯鼠标），那样键盘报告不再被当系统快捷键。Windows 11 从 2023-09 起只要求广播里「有」Appearance 元素、不挑具体值，`0x03C0` 同样能发现配对。改 Appearance 后 iPad 必须在「辅助功能→触控→辅助触控→设备」里忽略旧配对重新配，否则沿用缓存的旧声明。
- **platform 必须锁 `espressif32@6.13.0`（arduino-esp32 2.0.17 / IDF 4.4.7）**：NimBLE-Arduino 1.4.3 只兼容 arduino-esp32 2.x。若写成 `platform = espressif32` 不锁版本，CI 会拉到 8.x（arduino 3.3 / IDF 5.5），编译能过但运行时 `NimBLEDevice::init()` 空指针崩溃（串口 `Guru Meditation Error: Core 1 panic'ed (LoadProhibited)`, `EXCVADDR 0x5004c`），表现为 AP 打印出来后立刻无限重启、手机扫不到 `PT-Bridge`。2026-11-18 真机实测确认，已锁定版本修复。
- 报告布局（12 字节顺序）与 iOS 端 `PocketTrackpad/HIDDescriptor.swift` 的 `compositeReportMap`
  必须保持一致；任一侧改动都要同步另一侧。
- **【Windows 走 USB HID，不走蓝牙】ESP32-S3 硬件不支持经典蓝牙 BR/EDR**（乐鑫官方文档明确：S3 只有 BLE，Bluedroid/NimBLE 都仅支持 LE，任何固件/库都加不出经典蓝牙），而这台 Windows 的老 Broadcom BCM20702（BT4.0）适配器搜不到纯 BLE HID。2026-11-18 实测 iPad 走 BLE 完全正常、Windows 死活搜不到后确认。解决：用 S3 原生 USB-OTG 口做 **USB HID**（真正的有线键鼠，Windows 免驱、零延迟）。`platformio.ini` 必须加 `-D ARDUINO_USB_MODE=1 -D CONFIG_TINYUSB_ENABLED=1 -D CONFIG_TINYUSB_HID_ENABLED=1`，缺一个则 `USBHIDKeyboard/USBHIDMouse` 类被 `#if CONFIG_TINYUSB_HID_ENABLED` 剔除、USB HID 失效。`ARDUINO_USB_CDC_ON_BOOT` 必须保持 0，否则 `Serial` 被改成 USB CDC、左边 UART 口就没日志了。收到报告时 BLE 与 USB 两条通道同时发：`[STAT]` 里 `bleSubs` 是 iPad 订阅数；Windows USB HID 是否枚举成功，看 Windows 设备管理器里是否出现「HID-compliant mouse/keyboard」最直接。
- **两个 USB 口分工**：左边 USB-UART = 烧录 + 日志；右边 USB-OTG = Windows 键鼠。Windows 键鼠线必须接右边口；接左边口只会出现串口、不会被识别为键鼠。
- ESP32-S3 同时跑 WiFi（AP）+ BLE（HID）+ USB HID，三者互不冲突：BLE 用射频、USB 用有线、WiFi 用射频，芯片原生支持 2.4GHz 共存。
- iPad 首次配对需在「辅助功能→触控→辅助触控→设备」里忽略旧记录重配；Windows 走 USB HID 无需配对，插线即用。
- S3 有两个 USB 口：烧录与看日志请用底部**左边**的 USB-UART 口（原生 USB-OTG 那个口本固件不启用，接了不会有串口输出，容易误判为「烧录失败」）。如果第一次烧录没反应，换到左边口再试。
