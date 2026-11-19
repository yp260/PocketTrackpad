import SwiftUI
import UIKit

@main
struct PocketTrackpadApp: App {

    @StateObject private var hid = HIDPeripheral()
    /// 按键音播放器（单例注入）：键盘页与设置页共用同一份音量设置。
    @StateObject private var clicks = KeyClickPlayer.shared
    /// 按键振动播放器（单例注入）：键盘页、鼠标键、设置页共用同一份开关与强弱。
    @StateObject private var haptics = HapticPlayer.shared
    /// 键鼠宏存储（注入）：录制列表、编辑、回放共用同一份持久化数据。
    @StateObject private var macros = MacroStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(hid)
                .environmentObject(clicks)
                .environmentObject(haptics)
                .environmentObject(macros)
                .onAppear {
                    // 升级后一次性把默认开启的复合模式切回纯鼠标（iPad 上更稳定）。
                    hid.applyStartupMigration()
                    // 锁屏后 iOS 会停止 BLE 广播，因此使用期间保持屏幕常亮。
                    UIApplication.shared.isIdleTimerDisabled = true
                    // 广播改为 App 启动自动进行：原来的「开始广播」按钮对用户连接
                    // 成败毫无影响（iPad 是否发现/配对由系统层决定），且每次启动都要
                    // 手动点一次是多余的。延迟一点再启动，让界面先渲染完，即便蓝牙
                    // 初始化异常也不会拖垮 App 启动（历史上有过一打开就被杀的教训）。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if !hid.bridgeMode {
                            hid.start()
                        }
                    }
                }
                .onDisappear {
                    UIApplication.shared.isIdleTimerDisabled = false
                }
        }
    }
}
