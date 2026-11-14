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

    static var activeReportMap: Data { useReportID ? mouseReportMapWithID : mouseReportMap }

    /// HID Information: bcdHID 1.11 / Country 0 / Flags 0x02 (Normally Connectable)
    static let hidInformationValue = Data([0x11, 0x01, 0x00, 0x02])

    /// Report Reference Descriptor: [Report ID, Report Type=Input(0x01)]
    static var reportReferenceValue: Data {
        Data([useReportID ? 0x01 : 0x00, 0x01])
    }

    /// PnP ID: Vendor ID Source = USB(0x02), VID/PID/Version 为自定义占位值
    static let pnpIDValue = Data([0x02, 0x34, 0x12, 0x01, 0x00, 0x00, 0x01])

    static func emptyReport() -> Data {
        useReportID ? Data([0x01, 0x00, 0x00, 0x00, 0x00])
                    : Data([0x00, 0x00, 0x00, 0x00])
    }

    static func makeReport(buttons: UInt8, x: Int8, y: Int8, wheel: Int8) -> Data {
        let bx = UInt8(bitPattern: x)
        let by = UInt8(bitPattern: y)
        let bw = UInt8(bitPattern: wheel)
        return useReportID ? Data([0x01, buttons, bx, by, bw])
                           : Data([buttons, bx, by, bw])
    }
}
