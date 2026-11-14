import Foundation
import CoreBluetooth

/// HID over GATT (HOGP) 的 UUID 与报告描述符定义。
///
/// 关键点：CoreBluetooth 禁止 App 以「16 位短 UUID」形式注册蓝牙 SIG 采纳的服务，
/// 例如 CBUUID(string: "1812") 会在 didAdd service 时返回
/// CBError Code 8 "The specified UUID is not allowed for this operation."。
///
/// 但蓝牙规范里 16 位 UUID 本来就是 Bluetooth Base UUID 的缩写：
///     0x1812 == 00001812-0000-1000-8000-00805F9B34FB
/// 以完整 128 位形式注册时 CoreBluetooth 会放行，且空中数据仍被主机识别为 0x1812。
/// 这是本项目能成立的基础，属于非公开行为，需在每个 iOS 大版本上回归验证。
enum HIDSpec {

    static func sig(_ hex16: String) -> CBUUID {
        CBUUID(string: "0000\(hex16)-0000-1000-8000-00805F9B34FB")
    }

    /// 把 CBUUID 归一化为 4 位十六进制短码，便于比较 16 位 / 128 位两种写法。
    static func short(_ uuid: CBUUID) -> String {
        let s = uuid.uuidString.uppercased()
        if s.count == 4 { return s }
        if let head = s.split(separator: "-").first, head.count == 8, head.hasPrefix("0000") {
            return String(head.suffix(4))
        }
        return s
    }

    // MARK: - Services
    static let hidService        = sig("1812")   // HID Service
    static let deviceInformation = sig("180A")   // Device Information
    static let batteryService    = sig("180F")   // Battery Service

    // MARK: - 广播数据（必须用 16 位短 UUID）
    //
    // GATT 数据库注册用上面的 128 位形式（绕过 CBPeripheralManager.add 的 CBError 8），
    // 但广播包里必须用 16 位短形式，这是两件不同的事：
    //   - iPadOS / Windows 的蓝牙发现列表按 16 位服务 UUID 判断设备类别；
    //     128 位完整形式会被当成「自定义未知服务」直接屏蔽，设备不出现在列表里。
    //   - 128 位 UUID 占 18 字节，容易挤进 overflow 区域；Apple 文档说明
    //     overflow 中的 UUID 只有「显式扫描该服务的 iOS App」可见。
    static let advertisedServiceUUIDs: [CBUUID] = [
        CBUUID(string: "1812"),   // HID Service
        CBUUID(string: "180F"),   // Battery Service
        CBUUID(string: "180A")    // Device Information
    ]

    // 注意：标准 HID 设备还会在广播里带 GAP Appearance = 0x03C2 (Mouse)。
    // iOS 的 startAdvertising 只支持 LocalName 与 ServiceUUIDs 两个键，
    // App 无法设置 Appearance AD Type / Class of Device / 厂商数据，
    // 也无法改写整机共享外设的 GAP 服务。这是本方案的固有天花板：
    // 16 位 HID UUID 能让主机「看见」，但能否被归类为鼠标仍取决于系统实现。

    // MARK: - HID Characteristics
    static let hidInformation       = sig("2A4A")
    static let reportMap            = sig("2A4B")
    static let hidControlPoint      = sig("2A4C")
    static let report               = sig("2A4D")
    static let protocolMode         = sig("2A4E")
    static let bootMouseInputReport = sig("2A33")
    static let reportReference      = sig("2908")   // Report Reference Descriptor

    // MARK: - Device Information Characteristics
    static let manufacturerName  = sig("2A29")
    static let modelNumber       = sig("2A24")
    static let firmwareRevision  = sig("2A26")
    static let pnpID             = sig("2A50")

    // MARK: - Battery Characteristics
    static let batteryLevel      = sig("2A19")

    // MARK: - 报告格式开关
    //
    // 少数 iPadOS 版本对「无 Report ID」的报告描述符识别不稳定。
    // 如果 iPad 能配对但指针不动 / 点击无效，把它改成 true 后重新编译、重新配对。
    static let useReportID = false

    /// 标准相对鼠标：3 个按键（左/右/中）+ X + Y + 滚轮。
    /// 无 Report ID 时每条输入报告 4 字节： [buttons, dx, dy, wheel]
    /// 有 Report ID 时 5 字节：             [0x01, buttons, dx, dy, wheel]
    ///
    /// Apple DTS 明确说明：iOS 会审查 HID 配置，只有能被归类到
    /// 「iOS 直接支持的配置（Keyboard / Mouse）」的设备才会被接管。
    /// 因此这里必须是干净的标准鼠标描述符，不要混入触摸屏、消费控制等额外 Collection。
    static let mouseReportMap: Data = Data([
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
    ])

    /// 与上面相同，但在 Application Collection 内增加 Report ID 1。
    static let mouseReportMapWithID: Data = Data([
        0x05, 0x01,
        0x09, 0x02,
        0xA1, 0x01,
        0x85, 0x01,        // Report ID (1)
        0x09, 0x01,
        0xA1, 0x00,
        0x05, 0x09,
        0x19, 0x01,
        0x29, 0x03,
        0x15, 0x00,
        0x25, 0x01,
        0x75, 0x01,
        0x95, 0x03,
        0x81, 0x02,
        0x75, 0x05,
        0x95, 0x01,
        0x81, 0x03,
        0x05, 0x01,
        0x09, 0x30,
        0x09, 0x31,
        0x09, 0x38,
        0x15, 0x81,
        0x25, 0x7F,
        0x75, 0x08,
        0x95, 0x03,
        0x81, 0x06,
        0xC0,
        0xC0
    ])

    // MARK: - 键鼠复合设备（选项 B，实验性）
    //
    // 目标：三指上滑时发 Command + H（modifier 0x08 + keycode 0x0B），
    // 让 iPadOS 回到主屏幕。为此 Report Map 里要有 Keyboard Application Collection。
    //
    // 这里刻意 **不引入 Report ID、也不新增第二个 Report 特征**：
    // HID 1.11 允许一个描述符里有多个顶层 Collection 且不带 Report ID，
    // 此时所有 Input 字段按顺序拼成一条报告。这样做的三个好处：
    //   1. 鼠标部分前 4 字节与纯鼠标模式逐字节相同，主机即使不认键盘
    //      Collection，鼠标解析也和 v0.0.7 完全一致；
    //   2. GATT 结构（3 个服务 / 6 个特征）一行不用动，也不用处理
    //      两个同 UUID 的 2A4D 特征在订阅 / 读取时的歧义；
    //   3. 运行时关掉开关即可回到纯鼠标，无需重装 IPA。
    // Boot Mouse 0x2A33 仍是 3 字节；Boot Protocol 下键盘报告不可用。
    static let mouseReportBytes = 4
    static let keyboardReportBytes = 8
    static let compositeReportBytes = mouseReportBytes + keyboardReportBytes

    /// 标准 Boot Keyboard 的 modifier 位图（第 5 字节）。可按需按位或组合。
    static let modLeftControl: UInt8  = 0x01
    static let modLeftShift: UInt8    = 0x02
    static let modLeftAlt: UInt8      = 0x04   // iPad 上的 Option
    static let modLeftGUI: UInt8      = 0x08   // iPad / Mac 上的 Command
    static let modRightControl: UInt8 = 0x10
    static let modRightShift: UInt8   = 0x20
    static let modRightAlt: UInt8     = 0x40
    static let modRightGUI: UInt8     = 0x80

    /// Command(Left GUI) 位与 H 键的 HID 键码（三指上滑回桌面用）。
    static let commandModifier: UInt8 = modLeftGUI
    static let homeKeycode: UInt8 = 0x0B

    /// Report Map 里键盘字段声明的 Usage Maximum = 101 (0x65)。
    /// 超过这个范围的键码主机不会解析，全键盘布局只使用 0x00...0x65 内的键。
    static let maxKeyboardKeycode: UInt8 = 0x65

    /// 标准 Boot Keyboard 输入报告定义：modifier(1) + reserved(1) + 6 个键码。
    private static let keyboardCollection: [UInt8] = [
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
        0xC0               // End Collection (Application)
    ]

    /// Mouse Collection + Keyboard Collection，共用一条不带 Report ID 的输入报告。
    /// 复合报告固定 12 字节：
    ///   [buttons, dx, dy, wheel, modifier, reserved, key1, key2, key3, key4, key5, key6]
    static let compositeReportMap: Data =
        Data([UInt8](mouseReportMap) + keyboardCollection)

    static func reportMap(composite: Bool) -> Data {
        if composite { return compositeReportMap }
        return useReportID ? mouseReportMapWithID : mouseReportMap
    }

    /// 兼容旧的纯鼠标调用点。
    static var activeReportMap: Data { reportMap(composite: false) }

    /// HID Information: bcdHID 1.11 / Country 0 / Flags 0x02 (Normally Connectable)
    static let hidInformationValue = Data([0x11, 0x01, 0x00, 0x02])

    /// Report Reference Descriptor: [Report ID, Report Type=Input(0x01)]
    /// 复合模式也不带 Report ID，因此这里始终是 0x00。
    static var reportReferenceValue: Data {
        Data([useReportID ? 0x01 : 0x00, 0x01])
    }

    /// PnP ID: Vendor ID Source = USB(0x02), VID/PID/Version 为自定义占位值
    static let pnpIDValue = Data([0x02, 0x34, 0x12, 0x01, 0x00, 0x00, 0x01])

    static func emptyReport(composite: Bool = false) -> Data {
        if composite { return Data(repeating: 0, count: compositeReportBytes) }
        return useReportID ? Data([0x01, 0x00, 0x00, 0x00, 0x00])
                           : Data([0x00, 0x00, 0x00, 0x00])
    }

    /// 组装一条输入报告。
    /// - keycodes: 最多 6 个同时按下的键码（6KRO），不足补 0。
    ///   全键盘界面一次只发一个键，但接口保留多键能力，便于以后做组合键。
    static func makeReport(buttons: UInt8, x: Int8, y: Int8, wheel: Int8,
                           composite: Bool = false,
                           modifier: UInt8 = 0, keycodes: [UInt8] = []) -> Data {
        let bx = UInt8(bitPattern: x)
        let by = UInt8(bitPattern: y)
        let bw = UInt8(bitPattern: wheel)
        if composite {
            var slots = Array(keycodes.prefix(keyboardReportBytes - 2))
            slots += Array(repeating: 0,
                           count: (keyboardReportBytes - 2) - slots.count)
            return Data([buttons, bx, by, bw, modifier, 0x00] + slots)
        }
        return useReportID ? Data([0x01, buttons, bx, by, bw])
                           : Data([buttons, bx, by, bw])
    }
}
