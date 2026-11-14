// PocketTrackpad 硬件桥固件（ESP32-C3，NimBLE-Arduino 1.4.3）
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
// Appearance = HID Keyboard (0x03C1)：让主机把设备当键盘对待。
// iPad 上这样才可能隐藏软键盘、候选词带数字；Windows 上键盘类配对最成熟。
//
// 配套 iPhone 端：PocketTrackpad/HIDDescriptor.swift 的 compositeReportMap，
// 以及 PocketTrackpad/BridgeTransport.swift 的 UDP 协议（hello 0x5054 / welcome 0x5450）。

#include <Arduino.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <NimBLEDevice.h>
#include <NimBLEHIDDevice.h>

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

// 把一条 HID 报告发给已订阅的主机。
static void sendHidReport(const uint8_t* data, size_t len) {
    if (inputReportChar == nullptr) return;
    inputReportChar->setValue((uint8_t*)data, len);
    inputReportChar->notify();
}

void setup() {
    Serial.begin(115200);
    Serial.println("\nPocketTrackpad ESP32 硬件桥启动（键盘在前 / Appearance=Keyboard）");

    // ---- WiFi 热点：iPhone 连上来后通过 UDP 发输入报告 ----
    WiFi.softAP(AP_SSID, AP_PASS);
    Serial.print("AP SSID: ");
    Serial.print(AP_SSID);
    Serial.print("  IP: ");
    Serial.println(WiFi.softAPIP());
    udp.begin(UDP_PORT);
    Serial.printf("UDP 监听端口: %u\n", UDP_PORT);

    // ---- BLE HID：以标准键盘+鼠标复合设备被主机发现 ----
    // 关键：GAP Appearance = 0x03C1 (HID Keyboard)，这是 iOS 外设做不到、
    // 而 ESP32 可以做的。键盘类设备在 Windows / iPadOS 上的配对流程最成熟。
    // 注意：1.4.3 的 Appearance 只能设在广播对象上，NimBLEDevice 没有对应静态方法。
    NimBLEDevice::init("PT-Pad");
    // 不强制配对（bonding/mitm/secure 全 false）。Windows 可能仍弹出配对提示，配对一次即可。
    NimBLEDevice::setSecurityAuth(false, false, false);

    NimBLEServer* pServer = NimBLEDevice::createServer();
    hid = new NimBLEHIDDevice(pServer);
    hid->manufacturer("PocketTrackpad");
    hid->pnp(0x02 /*USB*/, 0x1234 /*VID*/, 0x0100 /*PID*/, 0x0100 /*版本*/);
    hid->hidInfo(0x00 /*国家码*/, 0x02 /*Normally Connectable*/);
    hid->reportMap((uint8_t*)reportMap, sizeof(reportMap));
    hid->startServices();
    // 我们的描述符不带 Report ID，因此 Report Reference 里写 0（与 iOS 端一致）。
    inputReportChar = hid->inputReport(0);
    hid->setBatteryLevel(100);

    NimBLEAdvertising* pAdv = NimBLEDevice::getAdvertising();
    pAdv->setAppearance(0x03C1);
    pAdv->addServiceUUID(NimBLEUUID((uint16_t)0x1812));  // HID Service
    pAdv->start();
    Serial.println("BLE HID 广播中：PT-Pad（键盘 + 鼠标，Appearance=Keyboard）");
}

void loop() {
    int len = udp.parsePacket();
    if (len > 0) {
        uint8_t buf[64];
        int n = udp.read(buf, sizeof(buf));
        if (n <= 0) return;

        if (n == 2 && buf[0] == 0x50 && buf[1] == 0x54) {
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
            sendHidReport(buf, 12);
        }
    }
    delay(1);
}
