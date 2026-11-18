// PocketTrackpad 硬件桥固件（ESP32-S3-DevKitC-1，NimBLE-Arduino 1.4.3）
//
// 角色：iPhone 把 12 字节复合 HID 报告通过 WiFi UDP 发给本设备，
// 本设备以「标准 BLE HID」转发给 Windows / Android / iPad。
//
// 为什么需要它：iOS 的 CoreBluetooth 外设无法设置 GAP Appearance，
// Windows 等主机因此搜不到 / 配对失败。ESP32 能在广播里设置 Appearance，
// 所以把「被主机发现」这一步交给它，iPhone 只负责采集输入。
//
// 报告布局（12 字节，与 iOS 端 HIDSpec.compositeReportMap 逐字节对应，
// v0.0.18 起键盘字段在前——与实体键鼠一体键盘的描述符排列一致）：
//   [modifier, reserved, key1..key6, buttons, dx, dy, wheel]
// 其中 buttons: bit0=左 bit1=右 bit2=中；dx/dy/wheel 为有符号 8 位相对量。
//
// Appearance = Generic HID / 复合设备 (0x03C0)：同时声明键盘 + 鼠标。
// 注意不可用 0x03C1（纯键盘）——iPad 会把设备只当键盘、不创建鼠标指针；
// 也不可用 0x03C2（纯鼠标）——部分主机不再把键盘报告当系统快捷键。
// 0x03C0 是键盘+鼠标复合设备的标准外观值，iPad 出指针、windows 11 也认
// （Win11 只要求广播里「有」Appearance 元素，不挑具体值）。
//
// 配套 iPhone 端：PocketTrackpad/HIDDescriptor.swift 的 compositeReportMap，
// 以及 PocketTrackpad/BridgeTransport.swift 的 UDP 协议（hello 0x5054 / welcome 0x5450）。

#include <Arduino.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <NimBLEDevice.h>
#include <NimBLEHIDDevice.h>
// NimBLE 的 HIDTypes.h 定义了宏 HID_SUBCLASS_NONE (0)，而 TinyUSB 的 hid.h 里有同名枚举值，
// 两者同时编译会让 hid_subclass_enum_t 声明崩坏（error: expected identifier）。
// 本固件不用 NimBLE 的 HID 类枚举（只用 report map 字节数组），undef 掉这个污染宏即可共存。
#undef HID_SUBCLASS_NONE
// USB HID（ESP32-S3 原生 USB-OTG 口）：给 Windows 做有线键鼠。
// 用官方 boot 协议类，Windows 原生免驱。与 BLE HID 互不干扰：
//   - 右边 USB-OTG 口（GPIO19/20）-> USB HID -> Windows 有线
//   - BLE 广播 -> iPad 无线（iPad 那条链路完全不动）
//   - 左边 USB-UART 口（TX43/RX44）-> Serial 日志（ARDUINO_USB_CDC_ON_BOOT 保持 0）
// 只有 CONFIG_TINYUSB_HID_ENABLED=1 时这些类才存在（platformio.ini 里开启）。
#include "USB.h"
#include "USBHID.h"
#include "USBHIDKeyboard.h"
#include "USBHIDMouse.h"

// 编译期把 ARDUINO_USB_MODE 的最终生效值打进构建日志，用于确认板级 =1 是否已被 build_unflags 剔除。
// 期望看到 "USB MODE FINAL = 0"（TinyUSB/USB-OTG，HID 走这条）；若为 1 则是 JTAG 串口、HID 失效。
#ifndef USBCHECK_STR2
#define USBCHECK_STR2(x) #x
#define USBCHECK_STR(x) USBCHECK_STR2(x)
#endif
#ifndef ARDUINO_USB_MODE
#pragma message("[USB-CHECK] ARDUINO_USB_MODE NOT DEFINED (defaults to 0 = TinyUSB)")
#else
#pragma message("[USB-CHECK] ARDUINO_USB_MODE FINAL = " USBCHECK_STR(ARDUINO_USB_MODE))
#endif

// ---- 网络 ----
static const char* AP_SSID = "PT-Bridge";   // iPhone 在「无线局域网」里连接此热点
static const char* AP_PASS = "";            // 开放网络，无需密码
static const uint16_t UDP_PORT = 5000;
static WiFiUDP udp;

// ---- BLE HID 描述符 ----
// 与 iOS 端 compositeReportMap（Keyboard Collection + Mouse Collection，无 Report ID）完全一致：
//   Keyboard: modifier(8) + reserved(8) + 6 个键码(各 8)
//   Mouse:   按钮(3bit)+填充(5bit) + X(8) + Y(8) + Wheel(8)
static const uint8_t reportMap[] = {
    // ---------- Keyboard Collection（在前，v0.0.18）----------
    0x05, 0x01,        // Usage Page (Generic Desktop)
    0x09, 0x06,        // Usage (Keyboard)
    0xA1, 0x01,        // Collection (Application)
    0x05, 0x07,        //   Usage Page (Keyboard/Keypad)
    0x19, 0xE0,        //   Usage Minimum (Left Control)
    0x29, 0xE7,        //   Usage Maximum (Right GUI)
    0x15, 0x00,        //   Logical Minimum (0)
    0x25, 0x01,        //   Logical Maximum (1)
    0x75, 0x01,        //   Report Size (1)
    0x95, 0x08,        //   Report Count (8)
    0x81, 0x02,        //   Input (Data, Var, Abs) -> modifier 位图
    0x75, 0x08,        //   Report Size (8)
    0x95, 0x01,        //   Report Count (1)
    0x81, 0x03,        //   Input (Const) -> 保留字节
    0x15, 0x00,        //   Logical Minimum (0)
    0x25, 0x65,        //   Logical Maximum (101)
    0x19, 0x00,        //   Usage Minimum (0)
    0x29, 0x65,        //   Usage Maximum (101)
    0x95, 0x06,        //   Report Count (6)
    0x81, 0x00,        //   Input (Data, Array) -> 6 个键码
    0x05, 0x08,        //   Usage Page (LEDs)
    0x19, 0x01,        //   Usage Minimum (Num Lock)
    0x29, 0x05,        //   Usage Maximum (Kana)
    0x15, 0x00,        //   Logical Minimum (0)
    0x25, 0x01,        //   Logical Maximum (1)
    0x75, 0x01,        //   Report Size (1)
    0x95, 0x05,        //   Report Count (5)
    0x91, 0x02,        //   Output (Data, Var, Abs) -> LED 位
    0x75, 0x03,        //   Report Size (3)
    0x95, 0x01,        //   Report Count (1)
    0x91, 0x03,        //   Output (Const) -> 3 位填充
    0xC0,              // End Collection (Application)
    // ---------- Mouse Collection ----------
    0x05, 0x01,        // Usage Page (Generic Desktop)
    0x09, 0x02,        // Usage (Mouse)
    0xA1, 0x01,        // Collection (Application)
    0x09, 0x01,        //   Usage (Pointer)
    0xA1, 0x00,        //   Collection (Physical)
    0x05, 0x09,        //     Usage Page (Button)
    0x19, 0x01,        //     Usage Minimum (Button 1)
    0x29, 0x03,        //     Usage Maximum (Button 3)
    0x15, 0x00,        //     Logical Minimum (0)
    0x25, 0x01,        //     Logical Maximum (1)
    0x75, 0x01,        //     Report Size (1)
    0x95, 0x03,        //     Report Count (3)
    0x81, 0x02,        //     Input (Data, Var, Abs)  -> 3 个按键位
    0x75, 0x05,        //     Report Size (5)
    0x95, 0x01,        //     Report Count (1)
    0x81, 0x03,        //     Input (Const, Var, Abs) -> 5 位填充
    0x05, 0x01,        //     Usage Page (Generic Desktop)
    0x09, 0x30,        //     Usage (X)
    0x09, 0x31,        //     Usage (Y)
    0x09, 0x38,        //     Usage (Wheel)
    0x15, 0x81,        //     Logical Minimum (-127)
    0x25, 0x7F,        //     Logical Maximum (127)
    0x75, 0x08,        //     Report Size (8)
    0x95, 0x03,        //     Report Count (3)
    0x81, 0x06,        //     Input (Data, Var, Rel)  -> X / Y / Wheel
    0xC0,              //   End Collection (Physical)
    0xC0               // End Collection (Application)
};

// NimBLE 1.4.3 的 HID 外设对象；inputReportChar 在 setup 里一次性创建并缓存。
static NimBLEHIDDevice* hid = nullptr;
static NimBLECharacteristic* inputReportChar = nullptr;

// ---- USB HID（Windows 有线）对象 ----
// 键盘用 sendReport(KeyReport) 直接发原始 8 字节报告（与 BLE 报告前 8 字节同布局）；
// 鼠标用 move() + press/release 同步 buttons，避免内部状态与主机不同步。
#if CONFIG_TINYUSB_HID_ENABLED
static USBHIDKeyboard usbKeyboard;
static USBHIDMouse usbMouse;
static uint8_t g_usbMouseButtons = 0;  // 我们自己跟踪 buttons，避免与 USBHIDMouse 内部状态打架
#endif

// ---- 运行时诊断计数：定位「两端都显示已连接但没反应」卡在哪一环 ----
static uint32_t g_helloCount = 0;   // 收到 iPhone 的 "PT" hello 次数
static uint32_t g_reportCount = 0;  // 收到 12 字节 HID 报告次数
static unsigned long g_statAt = 0;

// 连接回调： iPad 上「PT-Pad 已连接」可能只是旧配对缓存，实际 BLE 链路未必连到本板。
// 这行日志能确认主机是否真的连上 ESP32 的 GATT 服务。
class BridgeServerCallbacks : public NimBLEServerCallbacks {
    void onConnect(NimBLEServer* pServer) override {
        Serial.println("[BLE] 主机已连接（GATT 链路建立）");
    }
    void onDisconnect(NimBLEServer* pServer) override {
        Serial.println("[BLE] 主机已断开");
    }
};

// 报告特征的订阅回调：打印真实句柄与 subValue，确认 iPad 订阅的 attr_handle=26
// 是否就是我们的 inputReportChar（还是发错了对象）。
class ReportCharCallbacks : public NimBLECharacteristicCallbacks {
    void onSubscribe(NimBLECharacteristic* pChar, ble_gap_conn_desc* desc, uint16_t subValue) override {
        Serial.printf("[SUB] reportChar handle=%u subValue=%u\n", pChar->getHandle(), subValue);
    }
};

// 把一条 12 字节复合 HID 报告同时发给两条通道：
//   1) BLE -> iPad（无线，已订阅才发）
//   2) USB HID -> Windows（有线，主机枚举后才发）
// 报告布局：[modifier, reserved, key1..key6, buttons, dx, dy, wheel]
static void sendHidReport(const uint8_t* data, size_t len) {
    // ---- 通道 1：BLE（iPad）----
    if (inputReportChar != nullptr && inputReportChar->getSubscribedCount() > 0) {
        inputReportChar->setValue((uint8_t*)data, len);
        inputReportChar->notify();
    }

#if CONFIG_TINYUSB_HID_ENABLED
    // ---- 通道 2：USB HID（Windows）----
    // 报告前 8 字节正好是 KeyReport {modifiers, reserved, keys[6]}，逐字段拷贝。
    // Windows 键鼠是两条独立报告（键盘 report id=1 / 鼠标 report id=2），
    // 由 USBHIDKeyboard/USBHIDMouse 各自发送，主机原生识别。
    KeyReport kr;
    kr.modifiers = data[0];
    kr.reserved  = data[1];
    memcpy(kr.keys, data + 2, 6);
    usbKeyboard.sendReport(&kr);

    // 后 4 字节是鼠标：[buttons, dx, dy, wheel]
    // buttons: bit0=左 bit1=右 bit2=中（与 Arduino MOUSE_LEFT/RIGHT/MIDDLE 一致）
    uint8_t want = data[8] & 0x07;
    // 只在按钮变化时 press/release，避免每包都触发按钮事件。
    if ((want & MOUSE_LEFT)   != (g_usbMouseButtons & MOUSE_LEFT))   { if (want & MOUSE_LEFT)   usbMouse.press(MOUSE_LEFT);   else usbMouse.release(MOUSE_LEFT); }
    if ((want & MOUSE_RIGHT)  != (g_usbMouseButtons & MOUSE_RIGHT))  { if (want & MOUSE_RIGHT)  usbMouse.press(MOUSE_RIGHT);  else usbMouse.release(MOUSE_RIGHT); }
    if ((want & MOUSE_MIDDLE) != (g_usbMouseButtons & MOUSE_MIDDLE)) { if (want & MOUSE_MIDDLE) usbMouse.press(MOUSE_MIDDLE); else usbMouse.release(MOUSE_MIDDLE); }
    g_usbMouseButtons = want;
    // 相对位移：dx=data[9], dy=data[10], wheel=data[11]
    usbMouse.move((int8_t)data[9], (int8_t)data[10], (int8_t)data[11], 0);
#endif
}

void setup() {
    Serial.begin(115200);
    Serial.println("\nPocketTrackpad ESP32 硬件桥启动（键盘在前 / Appearance=Composite 0x03C0）");

    // ---- WiFi 热点：iPhone 连上来后通过 UDP 发输入报告 ----
    WiFi.softAP(AP_SSID, AP_PASS);
    Serial.print("AP SSID: ");
    Serial.print(AP_SSID);
    Serial.print("  IP: ");
    Serial.println(WiFi.softAPIP());
    udp.begin(UDP_PORT);
    Serial.printf("UDP 监听端口: %u\n", UDP_PORT);

    // ---- BLE HID：以标准键盘+鼠标复合设备被主机发现 ----
    // 关键：GAP Appearance = 0x03C0 (Generic HID / 复合)，这是 iOS 外设做不到、
    // 而 ESP32 可以做的。必须用复合值：0x03C1 纯键盘会让 iPad 不出指针，
    // 实测「连上了但完全没有指针」即此因。Report Map 里键盘 Collection 在前，
    // 符合 iPad 对复合设备的排列要求（Nordic 官方针对 iPad 的 workaround）。
    // 注意：1.4.3 的 Appearance 只能设在广播对象上，NimBLEDevice 没有对应静态方法。
    // 设备名带 S3 后缀：iOS 会把同名 HID 当作「已知设备」自动重连旧记录、
    // 不再扫描新板子，导致「显示已连接实际没连」。换名强制 iPad 重新发现配对。
    NimBLEDevice::init("PT-Pad-S3");
    // 必须开 bonding：iOS/iPadOS 对第三方 BLE HID 要求先配对存长期密钥，
    // 才会订阅 Input Report 特征（否则 subscribed=0、连上却收不到任何输入）。
    // mitm=false：ESP32 无屏幕/键盘无法输 PIN，用 Just Works 静默配对。
    NimBLEDevice::setSecurityAuth(true /*bonding*/, false /*mitm*/, false /*sc*/);

    NimBLEServer* pServer = NimBLEDevice::createServer();
    pServer->setCallbacks(new BridgeServerCallbacks());  // 打印主机连接/断开
    hid = new NimBLEHIDDevice(pServer);
    hid->manufacturer("PocketTrackpad");
    hid->pnp(0x02 /*USB*/, 0x1234 /*VID*/, 0x0100 /*PID*/, 0x0100 /*版本*/);
    hid->hidInfo(0x00 /*国家码*/, 0x02 /*Normally Connectable*/);
    hid->reportMap((uint8_t*)reportMap, sizeof(reportMap));
    // 【关键顺序】inputReport() 内部是 createCharacteristic()，必须在 startServices()
    // 之前创建，否则报告特征不进 GATT 数据库 —— 主机看到的是别的特征、订阅数恒为 0，
    // notify 发到幽灵特征，表现为「连上却完全没反应」。这是本次「假连接」的真正根因。
    // 描述符不带 Report ID，因此 Report Reference 里写 0（与 iOS 端一致）。
    inputReportChar = hid->inputReport(0);
    inputReportChar->setCallbacks(new ReportCharCallbacks());  // 打印订阅句柄
    hid->setBatteryLevel(100);
    hid->startServices();  // 必须在所有 createCharacteristic 之后
    Serial.printf("[DIAG] inputReportChar handle=%u\n", inputReportChar->getHandle());

    NimBLEAdvertising* pAdv = NimBLEDevice::getAdvertising();
    pAdv->setAppearance(0x03C0);  // 0x03C0 复合 HID（键盘+鼠标）；0x03C1 纯键盘会让 iPad 不出指针
    pAdv->addServiceUUID(NimBLEUUID((uint16_t)0x1812));  // HID Service
    pAdv->start();
    Serial.println("BLE HID 广播中：PT-Pad-S3（键盘 + 鼠标，Appearance=Composite 0x03C0，bonding 开）");

    // ---- USB HID（Windows 有线）----
    // native USB 口（S3 的 USB-OTG，GPIO19/20）枚举成标准键鼠，Windows 免驱。
    // 键盘/鼠标共用一个 TinyUSB HID 接口，两个 begin() 只幂等创建信号量，安全。
    Serial.printf("[USB-DIAG] ARDUINO_USB_MODE=%d (需为0=TinyUSB)，CONFIG_TINYUSB_HID_ENABLED=%d\n",
                  (int)ARDUINO_USB_MODE, (int)CONFIG_TINYUSB_HID_ENABLED);
#if CONFIG_TINYUSB_HID_ENABLED
    usbKeyboard.begin();
    usbMouse.begin();
    Serial.println("USB HID 已就绪（VID=303A/PID=0002，Windows 应识别为 HID 键鼠，不再是 JTAG 串口）");
#else
    Serial.println("[警告] CONFIG_TINYUSB_HID_ENABLED 未开启，USB HID 不可用（仅 BLE 工作）");
#endif
}

void loop() {
    int len = udp.parsePacket();
    if (len > 0) {
        uint8_t buf[64];
        int n = udp.read(buf, sizeof(buf));
        if (n <= 0) return;

        if (n == 2 && buf[0] == 0x50 && buf[1] == 0x54) {
            g_helloCount++;
            // iPhone 的 hello 包（"PT"）：回 welcome（"TP"）确认链路，
            // 这样 iPhone 端才会把状态切到「已连接硬件桥」。
            IPAddress rip = udp.remoteIP();
            uint16_t rport = udp.remotePort();
            udp.beginPacket(rip, rport);
            udp.write(0x54);
            udp.write(0x50);
            udp.endPacket();
        } else if (n == 12) {
            // 12 字节复合 HID 报告（键盘在前），原样转发给主机。
            g_reportCount++;
            sendHidReport(buf, 12);
        }
    }
    // 每 3 秒打印一次诊断计数，定位链路卡点：
    //   hello 不涨              -> iPhone 没发握手 / UDP 不通
    //   hello 涨 report 不涨     -> App 没在发 HID 报告
    //   report 涨 subscribed=0   -> 主机没连上/没订阅报告特征（iPad 端问题）
    //   report 涨 subscribed>0   -> 报告已发出，问题在 iPad 解析报告内容
    if (millis() - g_statAt >= 3000) {
        g_statAt = millis();
        size_t subs = inputReportChar ? inputReportChar->getSubscribedCount() : 0;
        // USB HID（Windows）枚举状态看 Windows 设备管理器最直接；
        // USBHIDKeyboard 不暴露 ready()（它内部持有私有 USBHID），故这里只报 BLE 订阅数。
        Serial.printf("[STAT] hello=%u report=%u bleSubs=%u\n",
                      g_helloCount, g_reportCount, (unsigned)subs);
    }
    delay(1);
}
