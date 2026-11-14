import SwiftUI
import UIKit

@main
struct PocketTrackpadApp: App {

    @StateObject private var hid = HIDPeripheral()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(hid)
                .onAppear {
                    // 锁屏后 iOS 会停止 BLE 广播，因此使用期间保持屏幕常亮。
                    UIApplication.shared.isIdleTimerDisabled = true
                    hid.start()
                }
                .onDisappear {
                    UIApplication.shared.isIdleTimerDisabled = false
                }
        }
    }
}
