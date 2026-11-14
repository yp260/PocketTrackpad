import SwiftUI
import UIKit

@main
struct PocketTrackpadApp: App {

    @StateObject private var hid = HIDPeripheral()
    /// 按键音播放器（单例注入）：键盘页与设置页共用同一份音量设置。
    @StateObject private var clicks = KeyClickPlayer.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(hid)
                .environmentObject(clicks)
                .onAppear {
                    // 锁屏后 iOS 会停止 BLE 广播，因此使用期间保持屏幕常亮。
                    UIApplication.shared.isIdleTimerDisabled = true
                    // 不自动启动蓝牙，改由界面上的「开始广播」按钮触发。
                    // 万一某一步仍触发系统异常，App 至少能停在界面上显示上次
                    // 运行到哪个阶段，而不是一打开就被杀掉、什么线索都看不到。
                }
                .onDisappear {
                    UIApplication.shared.isIdleTimerDisabled = false
                }
        }
    }
}
