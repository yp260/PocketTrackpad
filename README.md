# 口袋触控板 PocketTrackpad

把 iPhone 虚拟成蓝牙触控板 / 鼠标，连接 iPad 后作为系统级指针使用。

---

## 一、结论先行

> **状态更新（2026-11-14，真机验证通过）：iPhone 侧载本 App 后，iPad 能搜到并成功配对 `PT-Pad`，指针、点击、滚动均可用。**
> 决定性修复是第十四节：广播包必须放 **16 位 SIG UUID `0x1812`**，不能用 128 位完整形式。
> 也就是说，iOS 虽不向 App 暴露 GAP Appearance 和系统级 HID 外设能力，但只要广播身份正确，
> iPadOS 的蓝牙 HID 主机栈仍会接管这套 HOGP GATT 数据库 —— 原先担心的「第二道天花板」在当前 iPadOS 上并未拦住。
> **纯软件路径成立**，不需要 ESP32 硬件桥，iPad 端也不用装任何软件。
> 保留风险：这是非公开通道，iOS / iPadOS 大版本升级后需重新回归验证。

以下是立项时的判断与真机结果的对照。

**结论：可以走一条非公开通道，但不是苹果支持的官方能力。**

| 判断 | 说明 | 真机验证 |
| --- | --- | --- |
| 官方 API 是否支持 | 不支持。Apple DTS 明确回复「Core Bluetooth doesn't expose HID peripheral service capabilities to apps」 | 已证实 |
| 实际能否实现 | 128 位完整 UUID 注册 HID Service 绕开 `add()` 封锁，广播改用 16 位 `0x1812` 让主机发现 | **已通过**：配对成功并可操控 |
| iPad 端是否需要装 App | 不需要。iPadOS 13.4+ 原生接管标准蓝牙 HID 鼠标 | 已证实，对端零安装 |
| 是否系统级指针 | 是。配对成功后 iPad 出现圆形指针，可跨 App 使用 | 已验证 |
| 主要风险 | 非公开行为，未来 iOS 版本可能封堵；App Store 审核存在不确定性 | 当前版本可用，需按版本回归 |

### 技术依据

| 事实 | 来源 |
| --- | --- |
| `CBPeripheralManager.add(0x1812)` 返回 `CBError Code 8: The specified UUID is not allowed for this operation` | Apple Developer Forums, thread 725238（2023） |
| 改用 `00001812-0000-1000-8000-00805F9B34FB` 可成功注册，主机识别为 HID 设备 | 同上，及 GitHub Gist `conath/c606d95d…` 的后续讨论 |
| 经典蓝牙 HID 服务 `0x1124` 即使能注册，主机也不会当 HID 设备连接 | Apple Developer Forums, thread 725238 |
| iOS 会审查 HID 配置，只接管能归类到「iOS 直接支持的配置（Keyboard / Mouse）」的外设 | Apple DTS, thread 773065（2025） |
| App Store 上的 Bluetouch 用户实测「iPhone 作为 iPad 的蓝牙键盘鼠标可用，iPad 无需装任何 App」 | App Store / AppRecs 用户评价 |
| Bluetouch、Tracepad、AirBoard 均宣称蓝牙 HID 直连，无需目标端软件或 Wi-Fi | 各应用商店页面 |

原理要点：蓝牙规范里 16 位 UUID 只是 Bluetooth Base UUID 的缩写，`0x1812` 与 `00001812-0000-1000-8000-00805F9B34FB` 在空中协议上等价。CoreBluetooth 只按字符串形式拦截短 UUID，所以完整写法能通过校验，主机侧仍能识别为 HID Service。

---

## 二、工程内容

```
PocketTrackpad/
├── project.yml                       XcodeGen 工程描述
├── README.md                         本文件
└── PocketTrackpad/
    ├── PocketTrackpadApp.swift       App 入口，保持屏幕常亮
    ├── ContentView.swift             主界面 / 设置子页面 / 底部按键条 / 滚轮键
    ├── TrackpadSurface.swift         UIKit 手势识别（单指移动、双指滚动、轻点、长按），支持全屏 / 紧凑两种样式
    ├── HIDPeripheral.swift           CoreBluetooth 外设 + HOGP GATT 数据库 + 报告上报 + 设置持久化
    ├── HIDDescriptor.swift           UUID 定义、HID Report Descriptor、报告打包
    └── Info.plist                    蓝牙权限（不含后台模式）
```

### GATT 结构

| 服务 | 特征 | 作用 |
| --- | --- | --- |
| HID `0x1812` | HID Information `2A4A` | bcdHID 1.11 / Normally Connectable |
| | Report Map `2A4B` | 50 字节标准相对鼠标描述符 |
| | HID Control Point `2A4C` | 挂起 / 恢复 |
| | Protocol Mode `2A4E` | Report / Boot 协议切换 |
| | Report `2A4D` | 输入报告（4 字节：buttons / dx / dy / wheel）+ 2908 Report Reference |
| | Boot Mouse Input Report `2A33` | Boot 协议下的 3 字节报告，iOS 可能走这条 |
| Device Info `180A` | Manufacturer / Model / Firmware / PnP ID | 让主机把设备归类为合规外设 |
| Battery `180F` | Battery Level `2A19` | 部分 HID 主机判定条件之一 |

几个容易踩的坑，代码里已经处理：

1. **所有 SIG 采纳 UUID 一律用 128 位形式**，包括 `180A`、`180F`、`2908`，否则同样报 Code 8。
2. **读请求必须处理 `CBATTRequest.offset`**。Report Map 有 50 字节，超过默认 ATT_MTU，主机会分段读取；忽略 offset 会让 iPad 拿到错乱描述符并直接放弃接管。
3. **加密权限触发配对**。HID 相关特征带 `.readEncryptionRequired`，未绑定时 iOS 返回 Insufficient Authentication 并拉起配对流程。
4. **报告描述符必须是干净的标准鼠标**。不要混入触摸屏、消费控制等 Collection，否则 Apple DTS 描述的「配置审查」会拒绝接管。
5. **广播包只有 31 字节**。128 位 UUID 占 18 字节，所以设备名压到 `PT-Pad`，且只广播 HID Service。
6. **60Hz 合帧**。触摸事件用 `CADisplayLink` 累积后统一 Notify，避免高频事件打满 BLE 队列；`updateValue` 返回 false 时缓存一包，等 `peripheralManagerIsReady(toUpdateSubscribers:)` 再补发。

---

## 三、运行环境

| 项目 | 要求 |
| --- | --- |
| 编译 | macOS + Xcode 15 或更高版本 |
| 运行 | **必须真机 iPhone**。iOS 模拟器不支持 BLE 外设广播 |
| 目标 | iPad，iPadOS 13.4+，建议 16.0+ |
| 签名 | Apple Developer 账号（免费账号可真机调试，签名 7 天有效） |
| 使用状态 | App 需保持前台且屏幕常亮 |

当前交付环境是 Windows，**源码未经 Xcode 编译、未经真机验证**。代码按 Swift 5 / iOS 16 API 编写，首次编译如需微调请对照 Xcode 报错处理。

---

## 四、构建步骤

### 方式 A：XcodeGen（推荐）

```bash
brew install xcodegen
cd PocketTrackpad
xcodegen generate
open PocketTrackpad.xcodeproj
```

在 Xcode 里把 `PRODUCT_BUNDLE_IDENTIFIER` 改成你自己的 Bundle ID，选中真机后 `Cmd + R` 运行。

### 方式 B：手动建工程（不装任何工具）

1. Xcode → Create a new Xcode project → iOS → App。
2. Product Name 填 `PocketTrackpad`，Interface 选 SwiftUI，Language 选 Swift。
3. 删除自动生成的 `ContentView.swift` 和 App 入口文件。
4. 把本目录 `PocketTrackpad/` 下的 5 个 `.swift` 文件拖进工程（勾选 Copy items if needed）。
5. 用本目录的 `Info.plist` 替换自动生成的，或在 Target → Info 里补齐 `NSBluetoothAlwaysUsageDescription`（不要加后台模式，见第十三节）。
6. Build Settings → Swift Language Version 设为 Swift 5，Deployment Target 设为 iOS 16.0。
7. 真机运行。

---

## 五、配对与使用

1. iPhone 打开 App，点**右上角的小按钮「开始广播」**（左上角齿轮是设置）。
2. iPad 打开 **设置 → 蓝牙**，保持蓝牙开启。
3. 在「其他设备」里选择 **PT-Pad**，按提示完成配对。
4. iPad 屏幕出现圆形指针即成功；iPhone 上会**自动出现全屏触控区**，顶部显示「已连接」。
5. 点顶部「停止广播」只停止被发现，当前连接仍在；要彻底断开当前主机以便切换到 Windows / Mac，点已连接时出现的「断开」，再点「开始广播」重建服务，详见第二十节。首次配对若失败，在 iPad 上「忽略此设备」，再点「开始广播」重新广播一次。
6. 指针速度、滚动速度、自然滚动在**左上角齿轮 → 设置**里调，设置会自动保存。

### iPad 侧推荐设置

| 设置项 | 路径 | 作用 |
| --- | --- | --- |
| 辅助触控（AssistiveTouch） | 设置 → 辅助功能 → 触控 → 辅助触控 | 部分非标准 HID 设备不开启时指针能动但点击无效，遇到点击失灵时打开 |
| 指针速度 | 设置 → 通用 → 触控板与鼠标 | 与 App 内「指针速度」配合调整 |
| 辅助点按（右键） | 设置 → 通用 → 触控板与鼠标 → 辅助点按 | 把右键映射到正确侧 |
| 自然滚动 | 设置 → 通用 → 触控板与鼠标 | iPad 侧也会反转方向；若与预期相反，先检查这里，再切 App 内「自然滚动」 |

### 手势

| 操作 | 效果 |
| --- | --- |
| 单指滑动 | 移动指针 |
| 单指轻点 | 左键单击 |
| 单指双击 | 左键双击 |
| 单指长按 0.5 秒 | 右键单击 |
| 双指上滑 | 滚轮下滑（负 wheel） |
| 双指下滑 | 滚轮上滑（正 wheel） |
| 底部「左键 / 右键」按住 | 按键按下 / 抬起，可拖选 |
| 底部「滚轮」向上拖动 | 滚轮下滑，与双指滚动共用倍率和方向 |
| 底部「滚轮」向下拖动 | 滚轮上滑，与双指滚动共用倍率和方向 |
| 底部「滚轮」双击 | 按下滚轮键（中键 0x04）；单击刻意不动作，避免滚动时误触 |
| 底部「滚轮」单击 | 无动作 |

---

## 六、故障排查

| 症状 | 原因 | 处理 |
| --- | --- | --- |
| 日志出现「HID 服务被系统拒绝」 | 当前 iOS 版本封堵了 128 位 UUID 绕过 | 改用现成 App 或 ESP32 硬件桥方案，见第八节 |
| iPad 和电脑都搜不到 PT-Pad，但 App 显示广播正常 | v0.0.3 之前的 bug：广播里放了 128 位完整 UUID，被主机按「自定义未知服务」屏蔽 | 已改为 16 位广播 UUID，真机验证可用；若仍不显示，用 nRF Connect 扫描确认，见第十四节 |
| iPad 蓝牙列表看不到 PT-Pad（偶发） | App 未前台 / 蓝牙未就绪 / 名称过长 | 点「停止广播」再点「开始广播」；保持前台；确认 iPhone 蓝牙已开启；设备名不要改长 |
| iPad 上显示的设备名不是 PT-Pad，而是手机名或别的名字 | iPad 显示的是整机 GAP Device Name，不是广播名，App 无法修改 | 在 iPad 蓝牙设置里重命名，或改 iPhone 名称后忽略此设备重新配对，见第十六节 |
| 能配对，但 iPad 不出现指针 | HID 配置未通过 iOS 归类审查 | 把 `HIDSpec.useReportID` 改为 `true` 重新编译配对；确认 Report Map 是纯鼠标；检查 2908 Report Reference |
| 指针能动，点击无效 | iPadOS 对非标准 HID 的按键映射 | 打开辅助触控；检查 `辅助点按` 设置；在 App 日志确认 Report 已被订阅 |
| 指针跳动 / 卡顿 | BLE Notify 队列溢出或事件频率过高 | 降低指针速度；确认 `updateValue` 补发逻辑生效；两台设备靠近 |
| 滚动方向相反 | App 内「自然滚动」被打开，或 iPad 侧系统设置反转了方向 | 关掉 App 内「自然滚动」；再检查 iPad 设置 → 通用 → 触控板与鼠标 → 自然滚动 |
| 锁屏后断开 | iOS 限制后台 BLE 广播 | 保持 App 前台、屏幕常亮（代码已设置 `isIdleTimerDisabled`） |
| macOS 能配对但不收报告 | 社区反馈 macOS 对软件 HID 设备识别不稳定 | 优先在 iPad / Windows 验证；用 Packet Logger 抓包确认订阅行为 |

---

## 七、已知边界与风险

| 风险 | 说明 |
| --- | --- |
| 非公开行为 | 128 位 UUID 绕过不在任何 Apple 文档中，属于实现细节，iOS 大版本更新后必须回归验证 |
| App Store 审核 | 未使用私有 API，全部是公开 CoreBluetooth 接口；但功能定位可能被审查质疑。Bluetouch、Tracepad、AirBoard 已上架，说明不是绝对禁止，但不构成通过保证 |
| 后台限制 | App 必须前台、屏幕常亮；锁屏或切后台后 iOS 会停止 BLE 广播，不能当常驻鼠标用 |
| 手势上限 | 纯鼠标模式下只能发标准 HID 鼠标事件（位移 / 三键 / 滚轮），无法发送 iPadOS 的三指、四指系统手势。启用「键鼠复合模式」后可发键盘报告 `Command + H` 回主屏幕（实验性，见第二十二节）；四指切换 App 等手势仍做不到 |
| GAP Appearance | CoreBluetooth 不公开设置 Appearance，本项目未声明 Mouse(0x03C2)。若某台 iPad 因此拒绝接管，只能改走硬件桥 |
| 测试状态 | 本工程在 Windows 上编写，未编译、未真机验证，需你在 Mac 上完成首次构建与联调 |

---

## 八、备选方案对比

| 方案 | 是否纯软件 | 能否达成「iPhone 控制 iPad 指针」 | 额外成本 | 可靠性 |
| --- | --- | --- | --- | --- |
| 本工程（HOGP 128 位 UUID 绕过） | 是 | 能，依赖当前 iOS 行为 | 0 | 中，需逐版本验证 |
| 现成 App：Bluetouch / Tracepad / AirBoard | 是 | 能，已有 iPad 可用评价 | 约 20 元买断 | 高，最适合先做 5 分钟验证 |
| ESP32 硬件桥：iPhone 作为 BLE 中央发指令 → ESP32 作为标准 BLE HID 鼠标连 iPad | 否 | 能，且 iPad 侧识别无争议 | ESP32-C3 约 9～20 元 | 最高 |
| Wi-Fi + 目标端服务程序（Remote Mouse 等） | 是 | **不能**。iPadOS 不允许 App 注入系统级触控事件，只适用于 Mac / PC | 0 | 目标换成电脑时高 |
| MFi / ExternalAccessory | 否 | 能，但要 MFi 认证与实体配件 | 高 | 高，不适合个人开发 |
| 越狱 + 私有事件注入 | 否 | 能 | 0 | 不可分发，不建议 |

**建议顺序（按真机结果更新）**：本工程纯软件方案已验证可用，直接编译侧载即可；若你的 iPadOS 版本拒绝配对，先按第十四节核对广播 UUID 与日志，仍不行再改走 ESP32 硬件桥（100% 可靠的路径），或用 Bluetouch 现成 App 快速判断主机侧是否正常。

ESP32 桥的固件侧可直接用 ESP32-BLE-Mouse 库（BLE HID 鼠标，iPadOS 13+ 免驱，通常需打开辅助触控才能点击），iPhone 侧把本工程的 `CBPeripheralManager` 换成 `CBCentralManager` 连接自定义 GATT 服务即可，改动集中在 `HIDPeripheral.swift` 一个文件。需要这条路径的完整工程我可以继续补。

---

## 九、合规与用途

本项目仅用于本人设备之间的输入控制。请勿用于未授权设备、公共电脑或任何形式的键鼠记录；蓝牙配对需双方确认，App 不收集、不上传任何输入数据。

---

## 十、打包成可安装的 .ipa

### 直接回答

**在当前这台 Windows 机器上，现在生成不了可安装的 .ipa。** 已实测环境：MINGW64 / Windows 10，没有 `xcodebuild`、`xcrun`、`codesign`、`swiftc`、`xcodegen`、`zip`，也没有 macOS Keychain 和任何 Apple 签名证书。iOS 应用必须用 Apple 工具链编译，且必须签名才能装进非越狱设备，这两条都不是脚本能绕过的。

但拿到 ipa 的路已经铺好了：

| 环境 | 能否拿到可安装 ipa | 做法 |
| --- | --- | --- |
| 当前 Windows（无 Mac） | **不能直接产出**，但可以两段式完成 | 云端 macOS 编译未签名 ipa → Windows 侧载工具用自己的 Apple ID 重签 |
| 有 Mac + Xcode | 能 | `scripts/build_ipa.sh` 一键出签名 ipa |
| 有 GitHub 账号、无 Mac | 能 | push 后 `.github/workflows/unsigned-ipa.yml` 自动出包并创建 Release 下载链接 |
| 只想马上用，不一定要自研 | 不需要打包 | 直接装 Bluetouch / Tracepad 现成 App |

关键事实：`.ipa` 本质是 zip，里面是 `Payload/PocketTrackpad.app`。**未签名的 ipa 装不进 iPhone**，但可以被 Sideloadly / AltStore 用你自己的 Apple ID 重签后安装，不需要 Mac、不需要付费账号。

### 工具链文件

| 文件 | 作用 |
| --- | --- |
| `scripts/make_unsigned_ipa.sh` | 编译未签名 archive 并打包成未签名 ipa |
| `scripts/build_ipa.sh` | Mac 本地自动签名，直接产出可安装的 ipa |
| `export/ExportOptions-Development.plist` | Development 导出配置 |
| `export/ExportOptions-AdHoc.plist` | Ad Hoc 导出配置 |
| `.github/workflows/unsigned-ipa.yml` | push 自动编译、创建 Release、输出 IPA 下载直链与 SHA256SUMS |
| `.github/workflows/signed-ipa.yml` | 可选：用付费账号证书在 CI 直接产出已签名、下载即可安装的 IPA |
| `scripts/make_installable_ipa.ps1` | Windows 端下载 Release IPA、校验 SHA256、自检签名环境、输出本机签名步骤 |
| `.gitignore` | 忽略 build/、ipa、xcarchive |

### 路径 A：Mac 本地出可安装 ipa

前置：Xcode 15+ 已登录 Apple ID；Target 勾选 Automatically manage signing；手机用数据线连过一次。

```bash
cd PocketTrackpad
brew install xcodegen && xcodegen generate
chmod +x scripts/*.sh

# 免费 Apple ID / Personal Team，装到已配对设备
./scripts/build_ipa.sh development

# 或：付费账号 + Ad Hoc，需先在开发者后台登记设备 UDID
DEVELOPMENT_TEAM=ABCDE12345 ./scripts/build_ipa.sh adhoc
```

产物在 `build/export/PocketTrackpad.ipa`。安装：Xcode → Window → Devices and Simulators → 选中 iPhone → 把 ipa 拖进去；或 Apple Configurator / Finder 拖入。

### 路径 B：完全没有 Mac（推荐给当前环境）

**阶段 1：push 后自动出包并生成 Release（无需手动点按钮）**

1. 把整个 `PocketTrackpad/` 推到 GitHub 仓库。公开仓库 macOS runner 免费；私有仓库按分钟计费（约为 Linux 的 10 倍）。
2. 每次 `git push origin main` / `master` 自动触发编译，约 10 分钟后生成一个 pre-release。
3. 打开该次 workflow run 的 **Summary** 页面，里面有 Release 页面链接和 IPA 直接下载链接；也可直接进仓库 Releases 页下载。
4. 想发正式版本：`git tag v1.0.0 && git push origin v1.0.0`。
5. 也支持在 Actions 页面手动 Run workflow，并填 `release_tag` 自定义 tag。

| 触发方式 | Release tag | 类型 |
| --- | --- | --- |
| push 到 main / master | `v0.0.<run_number>-<shortsha>` | pre-release |
| push `v*` 标签 | 标签名，如 `v1.0.0` | 正式 release |
| 手动 Run workflow，填 `release_tag` | 自定义值 | pre-release |

每个 Release 附带 `PocketTrackpad-unsigned-<tag>.ipa` 和 `SHA256SUMS`。下载直链格式：

```
https://github.com/<owner>/<repo>/releases/download/<tag>/PocketTrackpad-unsigned-<tag>.ipa
```

| 注意点 | 说明 |
| --- | --- |
| 权限 | 工作流已显式声明 `contents: write`（仅发布 job）。若仍报 `Resource not accessible by integration`，到仓库 Settings → Actions → General → Workflow permissions 勾选 Read and write permissions |
| 权限隔离 | 构建 job 只有 `contents: read`，发布单独一个 job 才授权写，避免把写权限暴露给编译脚本 |
| Release 会累积 | 每次 push 新建一个 pre-release。可选清理（**会删除 Release，谨慎执行**）：`gh release list --limit 100 \| grep 'v0.0.' \| tail -n +11 \| awk '{print $1}' \| xargs -r -n1 gh release delete --yes` |
| 想省 CI 分钟 | 删掉 workflow 里 `push.branches` 两行，只保留 `tags: ['v*']` 触发 |
| 重复 tag | 手动指定一个已存在的 tag 会让同名 asset 冲突，换新 tag 即可 |
| 递归触发 | Release 用 `GITHUB_TOKEN` 创建，不会再触发新的 workflow，不会死循环 |

**阶段 2：Windows 上重签安装**

1. 先卸载 Microsoft Store 版 iTunes / iCloud，改装**网页版 iTunes 与 iCloud**（Sideloadly 官方明确要求，商店版会导致驱动不匹配）。
2. 安装 Sideloadly Windows 版（支持 Windows 7+，支持到 iOS 27+）。
3. USB 连接 iPhone，Sideloadly 里选中设备，拖入从 Release 下载的 `PocketTrackpad-unsigned-<tag>.ipa`，填入 Apple ID，点 Start。建议单独注册一个专用 Apple ID 用于签名。
4. 首次打开前，在 iPhone 上：设置 → 通用 → VPN 与设备管理 → 点你的 Apple ID → 信任。
5. iOS 16+ 必须开启开发者模式：设置 → 隐私与安全性 → 开发者模式 → 打开 → 重启 → 二次确认。若该入口不显示，说明系统还没识别到开发签名 App，先完成一次安装再回来看。

如果不想维护每周重签，改用 AltStore（电脑在同一 Wi-Fi 下自动 Wi-Fi 续签）或 SideStore（首次配对后手机端自助续签）。

### 签名限制（2026 年现状）

| 项目 | 免费 Apple ID | 付费开发者账号（$99/年，约 ¥688） |
| --- | --- | --- |
| 签名有效期 | 7 天，需重签 | 1 年 |
| 同时可装侧载 App | 最多 3 个（AltStore 本身占 1 个） | 无此限制 |
| 每周可新建 App ID | 约 10 个 | 无此限制 |
| 推送 / App Group / 关联域名 | 申请不到，会被签名工具剥离 | 可用 |
| 开发者模式 | iOS 16+ 必须开启 | 同样必须开启 |
| 自动续签 | Sideloadly 后台守护 / AltStore Wi-Fi / SideStore 端上 | 基本不用管 |

### 对这个 App 的适配结论

- 蓝牙用途说明（`NSBluetoothAlwaysUsageDescription` / `NSBluetoothPeripheralUsageDescription`）都在 `Info.plist`，重签不会丢失，BLE 外设功能不受影响；`Info.plist` 刻意不声明 `UIBackgroundModes`，避免免费账号侧载的 entitlement 校验冲突（见第十三节）。
- 本工程没有使用推送、App Group、关联域名、Keychain Sharing 等付费 entitlement，所以免费账号重签**不会导致功能缺失**。
- Sideloadly 可能改写 Bundle ID，对蓝牙 HID 功能无影响。
- 后台限制依旧：锁屏或切后台后广播会停，与签名方式无关。
- 由于本 App 依赖 128 位 UUID 这条非公开通道，**自签侧载是最合适的分发方式**；为它专门上架 App Store 反而有审核风险，不建议为此付费买账号。

### 常见错误

| 报错 / 现象 | 处理 |
| --- | --- |
| `xcodegen: command not found` | `brew install xcodegen`；或按第四节方式 B 手动建工程 |
| `Scheme PocketTrackpad is not currently configured for the build action` | `xcodebuild -list -project PocketTrackpad.xcodeproj` 查实际 scheme 名，改脚本里的 `SCHEME` |
| 未签名 ipa 拖进设备无反应 / 提示无法验证 | 正常，未签名包必须经 Sideloadly 重签 |
| `需要启用开发者模式` | 按阶段 2 第 5 步开启，需重启并二次确认 |
| `不受信任的开发者` | 设置 → 通用 → VPN 与设备管理 → 信任自己的 Apple ID |
| `Maximum App ID limit has been reached` | 免费账号每周约 10 个额度，等一周或换一个 Apple ID |
| 安装成功但闪退 | 检查 Deployment Target（iOS 16.0）是否高于设备系统；确认真机是 arm64 |
| Sideloadly 找不到设备 | 确认装的是网页版 iTunes + iCloud，不是 Microsoft Store 版；换数据线、信任此电脑 |

---

## 十一、关于「直接可以安装的 .ipa」

### 直接回答

**给不了，而且这个文件不存在通用版本。**

不是流程没走完，是 iOS 的安装机制决定了「一个 ipa 发给谁都能装」只有 App Store 一条路。我在这台 Windows 机器上硬生成一个 `.ipa`，只会是一个改了后缀的 zip，里面没有 Mach-O 可执行文件和合法签名，装不进任何 iPhone —— 这种假包我不会做。

| 硬约束 | 说明 |
| --- | --- |
| 编译 | iOS 应用必须是 arm64 Mach-O，只能用 Apple 工具链在 macOS 上产出。本机无 Xcode、无 `xcodebuild`、无 `swiftc` |
| 签名 | 非越狱 iPhone 只接受 Apple 签发的证书签名。签名需要你的 Apple ID 凭证，本机没有，也不该由我代持 |
| 设备绑定 | 描述文件里写着允许安装的设备 UDID 白名单。免费账号只包含签名时连着的那台设备；别人装会在 99% 报「身份验证失败」 |

补充两点事实：中国区不适用欧盟 DMA 侧载（AltStore PAL 需要欧盟区 Apple ID 和当地网络）；企业证书和「超级签」虽然能做出任意设备可装的包，但违反 Apple 条款、随时会被吊销，且需要把你的 UDID 交给第三方，不建议也不在交付范围内。

### 能真正拿到「直接可安装 IPA」的三条路

| 路径 | 产物 | 哪些设备能装 | 有效期 | 前提 | 一次性成本 |
| --- | --- | --- | --- | --- | --- |
| **A. Sideloadly 导出签名 IPA**（推荐） | 本机生成的 `PocketTrackpad-signed.ipa` | 生成时 USB 连着的那台 iPhone | 免费账号 7 天 | 免费 Apple ID + Windows + 数据线 | 一次图形界面操作 |
| **B. 本仓库 `signed-ipa.yml`** | CI 直出的已签名 IPA，下载即装，还有 Release 直链 | Ad Hoc 描述文件里已登记 UDID 的设备 | 到证书 / 描述文件到期（付费账号通常 1 年） | 付费开发者账号 + `.p12` + Ad Hoc profile + 3 个 secrets | 配置一次，之后点一下 |
| C. App Store 上架 | 官方分发包 | 所有 iPhone | 长期 | 通过审核 | 上架流程；本 App 走非公开 HID 通道，有审核风险 |

路径 A 得到的就是你要的那个「ipa 后缀、直接可以安装」的文件，只是它必须由你自己的 Apple ID 和设备生成，不能由我预先做好。

### 路径 A：免费，最短步骤

**第 0 步：拿到未签名 IPA。** 用第十节的 GitHub Actions 出包，或者直接让脚本从 Release 下载并校验：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\make_installable_ipa.ps1 -Repo "你的用户名/PocketTrackpad" -OpenSideloadly
```

| 参数 | 作用 |
| --- | --- |
| `-Repo` | 必填，`owner/repo` 格式 |
| `-Tag` | 指定 Release tag，留空取最新（含 pre-release） |
| `-OutDir` | 输出目录，默认工程下 `build/` |
| `-OpenSideloadly` | 检查完后直接启动 Sideloadly |

脚本会下载 IPA 与 `SHA256SUMS`、比对哈希、检查网页版 iTunes 和 Sideloadly 是否就位，并打印后续步骤。脚本输出刻意全用 ASCII：Windows PowerShell 5.1 会把无 BOM 的 UTF-8 脚本按 ANSI 解析，写中文会乱码。

**正式步骤：**

1. 卸载 Microsoft Store 版 iTunes / iCloud，改装**网页版**（Sideloadly 官方要求，商店版驱动不兼容）。
2. 装 Sideloadly Windows 版，USB 连 iPhone，手机上点「信任此电脑」。
3. Sideloadly 里把下载的未签名 IPA 拖进 IPA 槽位。
4. 点 **Advanced Options → Signing Mode → 选 `Export IPA`**。这一步是关键：默认模式是签完直接装到手机，只有 `Export IPA` 会把签名后的包**写成文件**。
5. 填 Apple ID（建议单独注册一个专用小号），点 Start。首次需要密码和双重认证验证码。
6. Sideloadly 在源文件旁边产出一个已签名 IPA。**这就是可以直接安装的包**，用 Sideloadly 的 `Normal Install`、Apple Configurator、或 Xcode → Devices and Simulators 拖进去即可，不用再走重签。
7. 手机上：设置 → 通用 → VPN 与设备管理 → 信任你的 Apple ID；iOS 16+ 再开 设置 → 隐私与安全性 → 开发者模式 → 重启确认。

到期后用同一个 Apple ID 重新导出一次即可；想免维护就开 Sideloadly 的自动续签守护，或换 AltStore / SideStore 走 Wi-Fi 续签。

### 路径 B：CI 直出「下载即装」的 IPA

适合不想每次本机操作、且已有付费开发者账号的情况。

| 前置项 | 说明 |
| --- | --- |
| Apple Developer Program | 付费账号（$99/年，约 ¥688） |
| 目标设备 UDID | 在开发者后台 Devices 里登记要装的那台 iPhone |
| Ad Hoc Provisioning Profile | 包含该 UDID 与 App ID（精确 ID 或通配 `TEAMID.*` 均可，工作流会自动对齐 Bundle ID） |
| 签名证书 | `iPhone Distribution` 或 `Apple Distribution`，导出为 `.p12` 并记住密码 |

在仓库 **Settings → Secrets and variables → Actions** 里添加 3 个 repository secrets：

| Secret | 内容 |
| --- | --- |
| `IOS_P12_BASE64` | `.p12` 文件的 base64 字符串 |
| `IOS_P12_PASSWORD` | 导出 `.p12` 时设的密码 |
| `IOS_ADHOC_PROFILE_BASE64` | `.mobileprovision` 文件的 base64 字符串 |

生成 base64：

```bash
# macOS
base64 -i cert.p12 | pbcopy
base64 -i adhoc.mobileprovision | pbcopy
```

```bash
# Linux
base64 -w0 cert.p12
base64 -w0 adhoc.mobileprovision
```

```powershell
# Windows PowerShell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("cert.p12")) | Set-Clipboard
[Convert]::ToBase64String([IO.File]::ReadAllBytes("adhoc.mobileprovision")) | Set-Clipboard
```

触发：Actions 页面手动 **Run workflow**（可填 `release_tag`），或 `git tag signed-1.0.0 && git push origin signed-1.0.0`。刻意不做 push 自动触发，避免每次提交都消耗签名材料与 CI 分钟。

工作流会：编译未签名 IPA → 建临时钥匙串导入 `.p12` → 放入 Ad Hoc 描述文件 → 从描述文件提取 entitlements → 对齐 Bundle ID → `codesign` 重签并 `--deep --strict` 验证 → 重新打包 → 创建 Release。

产物与直链：

```
PocketTrackpad-signed-<tag>.ipa
https://github.com/<owner>/<repo>/releases/download/<tag>/PocketTrackpad-signed-<tag>.ipa
```

安全提示：Release 里是带你自己证书签名的包，**建议放在私有仓库**。公开仓库虽然不含私钥，但也没必要公开分发。

### 常见问题

| 问题 | 回答 |
| --- | --- |
| 为什么不能直接发我一个 ipa 文件 | 签名绑定你的 Apple ID 和这台 iPhone 的 UDID，我没有这两样，也没有 macOS 编译环境 |
| 网上卖的「直装 ipa」为什么能装 | 用的是企业证书或超级签，先采集你的 UDID 再单独签一个包；随时可能掉签，且把设备标识交给了第三方 |
| 换一台 iPhone 能装同一个包吗 | 不能，UDID 不同。路径 A 要重新导出，路径 B 要把新 UDID 加进描述文件后重新出包 |
| 7 天后 App 打不开 | 免费账号签名到期，用同一 Apple ID 重新导出 / 重签；路径 B 的到期时间取决于证书与描述文件 |
| 不连电脑能不能直接装 | 中国区不行。欧盟 DMA 第三方商店需要欧盟区 Apple ID 与当地网络，2026 年仍未对中国区开放 |
| iPad 上要装东西吗 | 不用。iPadOS 13.4+ 原生接管蓝牙 HID 鼠标 |
| 已签名 IPA 装上去提示「不受信任的开发者」 | 设置 → 通用 → VPN 与设备管理 → 信任；iOS 16+ 还要开开发者模式 |
| 安装到 99% 失败 | 设备 UDID 不在描述文件里，或证书 / 描述文件已过期，换路径 A 或重新生成描述文件 |

---

## 十二、只走侧载的一键流程

既然不要上架、不要付费账号、不要证书，链路可以压到最短。新增 `scripts/sideload_one_click.ps1`，把不需要凭证和不需要人手的步骤全部自动化。

| 脚本自动完成 | 必须你本人完成（Apple 强制） |
| --- | --- |
| 检查 / 安装 GitHub CLI | 在浏览器点一次 GitHub 登录授权 |
| 初始化 git 仓库、提交代码 | 在 Sideloadly 里输入 Apple ID 密码和 2FA 验证码 |
| 创建公开仓库并 push（公开仓库 macOS runner 免费） | USB 连 iPhone，手机上点「信任此电脑」 |
| 触发云端编译并轮询到成功 | 手机上信任描述文件、开启开发者模式 |
| 从 Release 下载 IPA、校验 SHA256 | |
| 检查 iTunes / Sideloadly 环境、打开下载页、启动 Sideloadly | |

用法：

```powershell
powershell -ExecutionPolicy Bypass -File scripts\sideload_one_click.ps1 -OpenDownloads
```

| 参数 | 作用 |
| --- | --- |
| `-RepoName` | 新建仓库名，默认 `PocketTrackpad`；重名时换一个 |
| `-OutDir` | IPA 保存目录，默认工程下 `build/` |
| `-OpenDownloads` | 自动在浏览器打开 iTunes / Sideloadly 下载页 |
| `-SkipGitHub` | 已完成云端出包、只跑本机环境检查时用 |

脚本跑完只剩三步：把 IPA 拖进 Sideloadly → USB 连手机并填 Apple ID → 手机信任描述文件并开开发者模式。

### 本机实测状态（2026-11-14）

| 项目 | 结果 |
| --- | --- |
| git / curl / unzip | Git 仅存在于 WorkBuddy 便携目录，**不在系统 PATH**；脚本现已能自动定位 |
| 系统代理 | IE 代理 `127.0.0.1:7898` 已启用，浏览器可用；命令行默认直连，脚本会自动注入 `HTTPS_PROXY` |
| GitHub CLI (`gh`) | 已通过 winget 安装 2.104.0，位于 `C:\Program Files\GitHub CLI\gh.exe` |
| GitHub 登录 / 仓库 | 未登录、未建仓；本地仓库已初始化并提交 |
| 网页版 iTunes | 未安装 |
| Microsoft Store 版 iTunes | **存在，必须先卸载**，否则 Sideloadly 找不到设备 |
| iCloud / Sideloadly / Apple 设备服务 | 均未安装 |
| USB 连接的 iPhone | 未检测到 |
| 本机 iOS 签名证书 | 0 个 |
| `gh` 授权状态 | **未授权**。网页登录 GitHub 与命令行授权是两回事，需跑一次 `gh auth login --web` |
| 直连 / 代理实测 | 直连 `github.com` 超时（000）；走 `127.0.0.1:7898` 返回 200；git 走代理 `ls-remote` 成功 |

也就是说：软件环境需要你装三样（网页版 iTunes、iCloud、Sideloadly），外加一次 GitHub 命令行授权。这三样都涉及系统安装或账号凭证，脚本已给出下载链接并自动打开页面，但不能代替你点确认。

> **网络根因（2026-11-14 实测并已修复）**：这台机器的 IE/系统代理为 `127.0.0.1:7898`，浏览器走它所以能打开 GitHub；但 `gh.exe` 和 `git.exe` 是原生程序，**不继承 IE 代理**，会直连 `github.com` 并超时报 `wsarecv`。一键脚本现已自动完成三件事：读取注册表里的系统代理 → 分别探测直连与代理哪条通 → 把可用代理写入 `HTTPS_PROXY` / `HTTP_PROXY`（当 `api.github.com` 直连可用时加入 `NO_PROXY`）。同时自动定位不在 PATH 上的 Git（含 WorkBuddy 便携版），并把 Git 与 GitHub CLI 目录加入 PATH，保证 `git push` 的凭据助手能调用 `gh`。
>
> 实测结果：`OK network via system proxy http://127.0.0.1:7898`、`Resolved git.exe: ...PortableGit\...\cmd\git.exe`、`NO_PROXY: api.github.com`。

### 两个典型报错

| 终端现象 | 原因 | 处理 |
| --- | --- | --- |
| `failed to authenticate via web browser: Post "https://github.com/login/device/code": ... wsarecv: A connection attempt failed...` | gh 直连被网络挡住，没走系统代理 | 直接重跑一键脚本，它会自动注入代理；**不需要**再手动跑 `gh auth login` |
| `git is required but not found. Install Git for Windows first.` | Git 只在 WorkBuddy 便携目录，不在 Windows PATH | 脚本现已自动搜索便携版路径并加入 PATH；无需另装 Git |
| 浏览器只显示 GitHub 首页、没有 Authorize | 打开的不是设备验证页 | 见下一节，手动输入 `https://github.com/login/device` |

若代理软件没启动，两条路都不通，脚本会打印 `WARN github.com is unreachable...`；先开代理软件再重跑。

### 没看到 Authorize 按钮

GitHub 首页（Dashboard）上**不会**出现 Authorize 按钮。授权是两步：先在终端拿一次性码，再去设备验证页输入，之后才会看到 `Authorize GitHub CLI` 按钮。

| 步骤 | 位置 | 做什么 |
| --- | --- | --- |
| 1 | 你自己的 PowerShell 窗口 | 运行下方命令，终端打印 `! First copy your one-time code: ABCD-1234` |
| 2 | 终端 | **先复制这 8 位码**，再按 Enter 让浏览器打开 |
| 3 | 浏览器 | 地址栏手动输入 `https://github.com/login/device`（浏览器若只打开了首页，必须手动改地址） |
| 4 | 该页面 | 粘贴 8 位码 → Continue → 点绿色 `Authorize GitHub CLI` |
| 5 | 终端 | 出现 `✓ Logged in as <你的用户名>` 即成功 |

授权已由一键脚本自动发起，**不需要单独运行下面这条**。只有在脚本之外手动授权时才用，且必须先设置代理，否则又会超时：

```powershell
$env:HTTPS_PROXY = "http://127.0.0.1:7898"
& "C:\Program Files\GitHub CLI\gh.exe" auth login --web --git-protocol https --scopes "repo,workflow"
```

如果终端里根本没出现 8 位码，或者报 `Bad Gateway`，改用 Personal Access Token：网页打开 `https://github.com/settings/tokens/new?scopes=repo,workflow&description=PocketTrackpad`，生成后把 token 存到本地文件，再执行 `Get-Content <文件> -Raw | gh auth login --with-token`，用完删掉文件。**不要把 token 贴进聊天窗口或提交进仓库。**

### 比一键更省事的选择

如果只是想让 iPhone 立刻变成 iPad 的鼠标，不需要自研包：在 iPhone 的 App Store 搜 **Bluetouch**、**Tracepad** 或 **AirBoard**，点安装即可，iPad 端不用装任何东西。这是唯一连电脑都不用开的做法。

## 十三、启动闪退修复（v0.0.2）

首个可用包 `v0.0.1-9c0ebf3` 在真机上「点开即退」。根因已定位并修复，不是签名问题。

**CoreBluetooth 的硬规则**：用 `CBMutableCharacteristic(type:properties:value:permissions:)` 创建特征时，只要 `value` 不是 `nil`，该特征就是「缓存值特征」，系统强制它只能只读。若同时声明 `.notify` 或 `.write`，`CBPeripheralManager.add(service)` 会抛

```
NSInternalInconsistencyException: "Characteristics with cached values must be read-only"
```

这是 Objective-C 异常，Swift 捕获不到，进程直接终止。v0.0.1 里 Report(2A4D)、Boot Report(2A33)、Protocol Mode(2A4E)、Control Point(2A4C) 以及 Device Info / Battery 的特征全都既传了 `value` 又带 notify/write；而 `.onAppear` 里自动调用 `hid.start()`，蓝牙一进 `poweredOn` 就注册服务，所以一打开就闪退。

| 修复项 | 做法 |
| --- | --- |
| 特征值 | `makeChar` 一律 `value: nil`，所有值由 `peripheralManager(_:didReceiveRead:)` 动态提供（已覆盖全部 10 个可读特征，Report Map 的 offset 分段读取也保留） |
| 启动方式 | 去掉 `.onAppear` 里的自动 `hid.start()`，改由界面「开始广播」按钮触发；即使某一步再出异常，App 也能停在界面上显示线索 |
| 诊断 | 每推进一个阶段就写入 `UserDefaults`，下次启动在顶部显示「上次运行记录」（阶段 1～7）；若每次都停在同一步，把那段文字发回即可定位 |
| 后台模式 | 从 `Info.plist` 删除 `UIBackgroundModes`。本 App 必须前台常亮，后台模式无用，且免费 Apple ID 侧载时某些后台模式会触发 entitlement 校验导致秒退 |

> 升级安装时建议先删掉旧 App 再装新包，避免旧的阶段记录干扰判断。

### 如果新包仍然闪退

优先拿系统崩溃日志，这是唯一能确定原因的证据：

1. iPhone：设置 → 隐私与安全性 → 分析与改进 → 分析数据，找以 `PocketTrackpad` 开头的 `.ips` 文件，点右上角分享导出。
2. Windows 端 Sideloadly 的高级选项里有 **View Device System Logs**，可实时查看终止原因。
3. 把 `.ips` 文件发回来即可解析（内含异常类型、终止原因与调用栈）。

同时确认三件事：开发者模式已开启、设置 → 通用 → VPN 与设备管理里证书已信任、签名未超过 7 天。

## 十四、广播正常但 iPad / 电脑都搜不到（v0.0.3）

### 现象

v0.0.2 安装后能正常打开，点「开始广播」显示「等待 iPad 配对」，`peripheralManagerDidStartAdvertising` 未返回错误 —— 广播确实在发。但 iPad 的 设置 → 蓝牙 与 Windows 的添加设备里都看不到 `PT-Pad`。

### 直接原因：广播里放了 128 位完整 UUID

旧版 `advertise()` 把 `HIDSpec.hidService`（`00001812-0000-1000-8000-00805F9B34FB`）直接塞进 `CBAdvertisementDataServiceUUIDsKey`。这在主机侧有两个独立后果：

| 后果 | 依据 |
| --- | --- |
| 发现列表按 16 位服务 UUID 判断设备类别，128 位完整形式被当成「自定义未知服务」屏蔽 | Nordic 官方论坛实测：广播里放 `0x1812` 设备可见，换成任意 128 位 UUID 立刻不可见；iOS 设置里的未配对设备列表只显示实现了系统原生支持 profile（HID、HRM、ANCS 等）的设备 |
| 单个 128 位 UUID 在空中占 18 字节，加设备名后容易挤进 overflow 区域 | Apple `startAdvertising(_:)` 文档：overflow 区域里的服务 UUID「只有显式扫描这些服务的 iOS 设备才能发现」，系统蓝牙设置与非 iOS 主机一律看不到 |

前台广播可用空间只有 28 字节（不含每种数据类型 2 字节头），这是硬约束。

### 本次修复

| 项 | 做法 |
| --- | --- |
| 广播 UUID | 改成 16 位短形式 `1812 / 180F / 180A`，三个共 6 字节数据，宽裕放进初始广播包 |
| GATT 数据库 | **保持不变，仍用 128 位**。广播数据与 GATT 注册是两件事：`CBPeripheralManager.add()` 禁止 16 位 SIG UUID（CBError Code 8），这个限制只作用于注册，不作用于广播 |
| 自动回退 | 若某 iOS 版本拒绝广播 16 位 SIG UUID，`didStartAdvertising` 收到 error 后自动改用 128 位重试，保证广播不中断 |
| 日志 | 明确写出当前是「16 位标准模式」还是「128 位回退模式」，回退时直接提示主机大概率不会显示 |

### 曾经担心的第二道天花板（真机未触发）

标准 BLE HID 设备的广播包还带 **GAP Appearance = 0x03C2（Mouse）** 和 Class of Device。iOS 的 `startAdvertising(_:)` 只支持 `CBAdvertisementDataLocalNameKey` 与 `CBAdvertisementDataServiceUUIDsKey` 两个键，App 无法设置 Appearance、厂商数据、发射功率；CoreBluetooth 的 GATT 服务也只是整机共享外设的一部分，App 不控制 GAP。

Apple 工程师在开发者论坛的正式回复是：**「Core Bluetooth doesn't expose HID peripheral service capabilities to apps.」** 系统 HID 主机栈由蓝牙守护进程管理，App 用户态提供的 GATT 服务未必会被注册成系统级 HID 设备。因此修复 16 位 UUID 能让主机「看见」，但能否被归类为鼠标，仍取决于系统实现，这一版没有真机把握。

App Store 上的 Bluetouch 宣称「对端无需装软件、纯蓝牙直连」且 2026 年仍在更新，本项目没有它的源码，无法反推其实现细节。

> **真机结果（2026-11-14）**：上述担心没有发生。v0.0.3 装上后，iPad 的蓝牙列表直接出现 `PT-Pad`，配对成功，系统级指针、点击、滚动均正常。说明当前 iPadOS 主要按广播里的 16 位服务 UUID 做发现与分类，App 无法设置 GAP Appearance 并不构成阻断。本小节保留作技术背景，不再作为方案否决依据。

### 诊断手段（备查）

用 **nRF Connect**（iOS / Android 免费，Windows 可用 nRF Connect for Desktop）扫描 `PT-Pad`，这是区分两类问题的唯一手段：

| 扫描结果 | 结论 | 下一步 |
| --- | --- | --- |
| 扫得到，广播里能看到 `0x1812` | 广播正常（真机已验证 iPad 能接管） | 直接用；若某系统版本仍不显示，再考虑 ESP32 硬件桥 |
| 扫得到，但只有 128 位 UUID | 触发了回退模式 | 看 App 日志里的拒绝原因，发回定位 |
| 完全扫不到 | 广播没真正发出 | 检查 `didStartAdvertising` 的 error 与蓝牙权限 |

### 方案结论

| 路径 | 可靠性 | 代价 |
| --- | --- | --- |
| 本工程纯软件方案 | **真机已验证可用**；属非公开通道，大版本升级后需回归 | 免费，自签侧载 7 天续签 |
| ESP32-C3 硬件桥 | 最稳。固件可自由设置 Appearance `0x03C2`、16 位 `0x1812` 广播、标准 HOGP | 约 10～20 元硬件；iPhone 通过 BLE 中央或 Wi-Fi 把触摸数据发给 ESP32，需新写两端代码 |
| 直接装 Bluetouch / Tracepad | 最省事，对端不用装软件 | 约 3 欧元去广告，代码不可控 |

一句话：**把广播 UUID 从 128 位改成 16 位 `0x1812` 之后，整条链路就通了。** 纯软件方案成立，硬件桥退为可选的高可靠性备选。

---

## 十五、界面改版（v0.0.4）

真机可用后按实际使用习惯重排了界面，全部改动集中在 `ContentView.swift`、`TrackpadSurface.swift`、`HIDPeripheral.swift` 三个文件，蓝牙链路一行未动。

| 需求 | 实现 |
| --- | --- |
| 指针速度、滚动速度移入设置子页面 | 主页面不再出现滑杆；左上角齿轮进入 `SettingsView`（`Form` 分页：指针 / 滚动 / 按键 / 关于）。自然滚动开关一并移入 |
| 设置能记住 | 三项参数加 `UserDefaults` 持久化，`didSet` 写盘，重开 App 不用重调 |
| 连接后触控区全屏 | 以 `hid.subscribers > 0` 判定连接；未连接时引导页不显示触控区，连接后才出现 `TrackpadSurface(edgeToEdge: true)`，用 `maxHeight: .infinity` 吃掉顶部栏与底部按键条之间的全部空间，并忽略左右安全区；连接后同时隐藏状态卡片、日志、诊断与提示 |
| 全屏样式 | `TrackpadSurface` 新增 `edgeToEdge` 参数：圆角 22 → 0、边框 1 → 0、灰底 → 系统背景色，避免边缘留白 |
| 停止广播放在顶部且变小 | 移到导航栏右侧，`.font(.caption2)` + `.buttonStyle(.bordered)` + `.controlSize(.mini)`；文案随状态在「开始广播 / 停止广播」间切换，左侧显示绿色小圆点与「已连接」 |
| 三个键固定在最下面 | `ButtonBar` 放在外层 `VStack` 最后一个元素，不随引导页 `ScrollView` 滚动，连接前后位置不变；底部背景延伸到 home indicator 安全区 |
| 中键改成滚轮 | `WheelButton` 取代中键：上下拖动发送 `wheel` 事件，单击不动作，避免滚动时误触中键 |
| 双击滚轮 = 按下滚轮键 | 双击（0.32 秒内两次轻点、位移小于 8pt）调用 `hid.click(0x04)`，产生一次中键按下/抬起，并给中等强度触感反馈 |

滚轮键与触控区双指滚动共用 `scrollSensitivity` 和 `naturalScrolling`，方向定义一致，不会出现两种滚动方向相反的情况。单击滚轮刻意不发按键，按钮上分两行标注「拖动滚动 / 双击按下」（第二十一节收窄滚轮键后由单行改为两行）。

顺带修正了触控区提示文案里一处重复词的笔误（第二项应为「双击左键」）。

**版本兼容性**：设置页和全屏布局用到的 `navigationDestination`、`Form`、`ToolbarItemGroup`、`.background { }` 均支持工程最低部署目标 iOS 16.0。

---

## 十六、iPad 上显示的蓝牙设备名（v0.0.5）

### 现象

App 广播里明确写了 `CBAdvertisementDataLocalNameKey: "PT-Pad"`，但 iPad 的 设置 → 蓝牙 里显示的是 `Xiaomi Smart Band 9Pro 44AE`（即这台 iPhone 的整机名称，或 iPad 缓存下来的旧 GAP 名称）。

### 原因：显示的是 GAP Device Name，不是广播名

蓝牙里有两个互不相干的名称：

| 名称 | 位置 | 谁控制 | 优先级 |
| --- | --- | --- | --- |
| Local Name | 广播包 AD Type 0x08 / 0x09 | App 通过 `CBAdvertisementDataLocalNameKey` 设置，本项目已设为 `PT-Pad` | 仅首次主动扫描时可见 |
| GAP Device Name | GATT `0x1800` 服务的 `0x2A00` 特征 | **iPhone 整机蓝牙栈**，等于 设置 → 通用 → 关于本机 → 名称 | **优先**，且连接后被系统缓存 |

Apple 开发者论坛（thread 72343）的官方回复：当外设同时有这两种名称时，`CBPeripheral.name` 返回 GAP 名称；首次发现时可显示广播 Local Name，一旦连接就会读取并缓存 GAP 名称，之后即使广播名改了也继续显示缓存值。

### 为什么 App 改不了这个名字

| 依据 | 结论 |
| --- | --- |
| Apple DTS（thread 35100）：「iOS restricts direct access to certain characteristics. The Device Name characteristic is one of them」，`CBPeripheral.name` 只读 | App 不能写 `0x2A00` |
| Apple DTS：iOS 对 App 隐藏 Generic Access（0x1800）服务 | App 读不到系统 GAP 服务 |
| Stack Overflow 42208870：App 的服务不是独立外设，只是「整机共享外设」的一部分；实测自己 `add(0x1800)` 后扫描列表仍显示系统值 | App 自建 GAP 服务会被忽略 |
| `UIDevice.current.name` 是只读属性，无公开 API 修改整机名称 | App 不能改 iPhone 名称 |

因此这不是代码缺陷，也无法靠改 `startAdvertising` 的参数绕过。`Xiaomi Smart Band 9Pro 44AE` 这类带地址后缀的名字，来自整机名称或被缓存的配对记录。

### 两条真正有效的改名路径

| 路径 | 操作位置 | 影响范围 | 是否需要重装 App |
| --- | --- | --- | --- |
| **A. iPad 侧重命名（推荐）** | iPad 设置 → 蓝牙 → 已连接设备旁的「更多信息」按钮 → 名称 → 输入 `PT-Pad` | 只改这台 iPad 上的显示，不动 iPhone 名称 | 不需要 |
| B. 改 iPhone 整机名称 | iPhone 设置 → 通用 → 关于本机 → 名称 → 改成 `PT-Pad` | 所有设备看到的名称都变（含 AirDrop、个人热点） | 不需要 |

路径 A 是 Apple 官方支持文档《更改蓝牙配件的名称》给出的做法，适用于已连接的键盘、鼠标、触控板。要求设备处于「已连接」状态，改完点完成即可。

路径 B 改完后，因为 iPad 会缓存旧的 GAP 名称，**必须先在 iPad 蓝牙设置里「忽略此设备」，再重新扫描配对**，否则仍显示旧名。

> 注意：走路径 A 改名之后，不要再点「忽略此设备」或取消配对，否则 iPad 会丢掉这个自定义名称、恢复成手机原名。

### 本次 App 侧改动

代码只做诊断增强，**蓝牙链路一行未动**（仍是 HID / Device Info / Battery 三个服务，广播 UUID 与报告逻辑全部不变）：

| 文件 | 改动 |
| --- | --- |
| `HIDPeripheral.swift` | 新增 `systemDeviceName`（`UIDevice.current.name`）供界面显示；广播时写两行日志，明确区分「广播 Local Name = PT-Pad」与「iPad 实际显示的整机 GAP 名称 = …」，名称不是 PT-Pad 时给出改名提示 |
| `ContentView.swift` | 设置 → 关于 里新增「系统设备名」一行，页脚写清两条改名路径（后续已改为不回显整机名，见第十七节） |
| `README.md` | 本节 |

如果不想为了看这段说明而重新签名安装，**不装这一版也完全可以改名**——直接在 iPad 的蓝牙设置里重命名即可，v0.0.4 的功能不受影响。

---

## 十七、设置页不再回显整机名

反馈：设置 → 关于 里的「系统设备名」仍显示 `Xiaomi Smart Band 9Pro 44AE`。该值来自
`UIDevice.current.name`（只读），App 无权改写；把它显示在界面里既不能改变 iPad 上的名字，
也容易被误认为是可修改的名称设置项。因此本次改为不再回显，并把改名步骤直接写进页脚：

| 文件 | 改动 |
| --- | --- |
| `HIDPeripheral.swift` | 移除 `systemDeviceName` 属性；广播日志改为固定说明，不再打印整机名 |
| `ContentView.swift` | 关于段改为「iPad 显示名称 / 跟随 iPhone 整机名」；页脚写清路径 A、B 的完整操作与「改完不要再忽略此设备」的注意事项 |
| `preview/ui-preview.html` | 界面预览同步，右侧元素清单第 15 项同步 |
| `preview/shot-3-settings.png` | 设置页静态截图重新生成 |
| `README.md` | 本节 |

蓝牙链路一行未动：仍是 HID / Device Information / Battery 三个服务、16 位广播 UUID、
相对鼠标报告与 Boot Mouse 报告。**真机上让 iPad 显示 `PT-Pad` 依旧按第十六节路径 A 或 B
操作，不需要重装 App，也不需要新 IPA。**

---

## 十八、引导页精简与参数入口（本轮界面微调）

| 调整 | 改动 |
| --- | --- |
| 删除「重新广播」按钮 | 顶部「开始广播／停止广播」已能完成同样的停止再启动，状态卡片里不再重复放一个按钮 |
| 未连接时不再显示缩小版触控区 | 删掉 `setupBody` 里的 `TrackpadSurface()`（原 240pt 高的灰底圆角区域）。未连接时发出的位移没有主机接收，留着只会误导；连接成功后才出现全屏触控区 |
| 引导页增加指针速度 / 滚动速度 | 用一张「指针与滚动」卡片填补删除触控区后的留白；两个滑块绑定同一个 `HIDPeripheral`，与设置子页面共用 `UserDefaults` 持久化。**设置子页面的同名控件保留**：连接后引导页会被全屏触控区替换，届时只能从设置页调整 |

状态卡片的两行引导文案也随之调整口径：连接成功后是「出现」全屏触控区，而不是「切换」。
两处都只改 `ContentView.swift` 的界面结构，**蓝牙链路、报告逻辑、广播 UUID 一行未动**；
界面预览 `preview/ui-preview.html` 与静态截图同步更新。
第二十八节起引导页三张卡片统一显式通栏，修掉连接日志初始宽度过窄的问题。

---

## 十九、滚动方向反转与按键条加高（本轮方向调整）

| 调整 | 改动 |
| --- | --- |
| 双指上滑改为滚轮下滑 | `naturalScrolling` 默认值由 `true` 改为 `false`。触控区 `handleScroll` 与底部 `WheelButton` 共用这个开关和方向公式，两处同时反转：上滑发负 wheel（滚轮下滑），下滑发正 wheel（滚轮上滑） |
| 滚轮按钮方向同步反转 | `WheelButton` 的 `direction` 与触控区完全一致，不需要单独分支；缩放倍率仍是触控区除以 6.0、滚轮键除以 4.0 |
| 持久化键换成 `PocketTrackpad.naturalScrolling.v2` | Sideloadly 覆盖安装会保留旧 `UserDefaults`。只改默认值的话，曾经动过开关的真机仍会沿用旧值、方向不变；换新键保证升级后一律采用新默认方向 |
| 三个按键高度翻倍 | `ButtonBar` 的 `.frame(height: 58)` 改为 `116`，左键 / 滚轮 / 右键同步变高（当时仍为三键等宽，宽度比例见第二十一节），上下 padding 不变 |

打开设置里的「自然滚动」开关会把方向整体取反，回到 v0.0.6 及以前的跟手方向。
方向换算仍集中在两处 `direction = naturalScrolling ? -1 : 1`，没有改动报告格式、
广播 UUID 或点击手势。设置页开关下方补了方向说明，预览页 `preview/ui-preview.html`
的开关默认值、滚轮拖动方向、按键条高度与三张截图同步更新。

---

## 二十、主动断开与切换主机

`CBPeripheralManager` 没有公开的 `disconnect(central:)` 接口：`stopAdvertising()` 只是不再被
新主机发现，已经建立的 BLE 连接仍然存在，iPad 会一直占着这台虚拟鼠标。想换到 Windows / Mac，
必须在 App 侧把当前链路拆掉。

| 项目 | 实现 |
| --- | --- |
| `HIDPeripheral.disconnect()` | 先 `stopAdvertising()`，再 `removeAllServices()`，把 `delegate` 置空并释放 `manager` 实例，由系统拆掉当前连接；随后清零 `subscribers`、订阅标志、待发位移、按键位，并重置 GATT 构建标志 |
| 为什么不自动重新广播 | 断开后保持停止广播，避免 iPad 立刻自动重连；由用户决定何时点「开始广播」 |
| 重新广播 | `start()` 发现 `manager == nil` 会重新创建 `CBPeripheralManager`，收到 `.poweredOn` 后重建 3 个 GATT 服务并广播 16 位 SIG UUID，其他主机即可发现 |
| 界面 | 已连接时顶部工具栏出现 mini 尺寸「断开」按钮（`DisconnectButton`）；点完 `subscribers` 归零，界面回到引导页 |
| 日志 | 断开时写三行提示：已断开、重新广播后其他主机可发现、iPad 可能自动重连需先忽略此设备 |

切换步骤：连接状态下点「断开」→ 点「开始广播」→ 在 Windows / Mac 的蓝牙设置里搜索并配对。
如果 iPad 仍在附近且保留配对记录，可能抢先自动重连；此时先在 iPad 设置 → 蓝牙里「忽略此设备」，
或暂时关闭 iPad 蓝牙。

**三指上滑回桌面**：本轮已按选项 B 实现为「键鼠复合模式」，默认开启，可在设置页一键关闭回退。
实现细节、风险与真机验证清单见第二十二节。

---

## 二十一、三键宽度改为 3 : 2 : 3

滚轮键只需要上下拖动，占满三分之一宽度没有必要；收窄后把宽度让给使用频率更高的左右键。

| 按键 | 调整前 | 调整后 | 390pt 屏宽下的实际宽度 |
| --- | --- | --- | --- |
| 左键 | 33.3% | 37.5% | 约 130pt |
| 滚轮 | 33.3% | 25.0% | 约 87pt |
| 右键 | 33.3% | 37.5% | 约 130pt |

计算口径：按键条可用宽度 = 屏宽 − 左右 padding 24pt − 两个间距 20pt，按 3 : 2 : 3 共 8 份分配。

**实现方式**：原来三个子视图都写 `.frame(maxWidth: .infinity)`，由 `HStack` 平均分配剩余空间，
没有可设置比例的参数（`layoutPriority` 只决定分配顺序，不能精确控制比例）。改为在 `ButtonBar`
外层用 `GeometryReader` 读取 padding 后的实际宽度，`keyWidths(for:)` 按权重算出三个宽度，
再用 `.frame(width: maxHeight: .infinity)` 逐个固定。这样在任意 iPhone 宽度、iPad 分屏下都保持
同一比例，且三键仍等高。滚轮键内的 9pt 副标题变窄后单行会被压到 7.2pt、几乎看不清，因此改成
两行「拖动滚动 / 双击按下」（`lineLimit(2)` + `multilineTextAlignment(.center)`），保留
`minimumScaleFactor(0.8)` 兜底，文案内容本身不变。

| 文件 | 改动 |
| --- | --- |
| `PocketTrackpad/ContentView.swift` | `ButtonBar` 增加权重常量、`keyWidths(for:)`、`keys(width:)` 与 `GeometryReader`，结束行由 275 推到 301；滚轮键副标题改两行再加 2 行，`WheelButton` 结束行 408 → 410，后续结构体共后移 28 行 |
| `preview/ui-preview.html` | 三键 `flex` 由等宽改 3:2:3、滚轮键小字缩小防溢出、元素清单第 9 项与所有受影响的代码行号同步 |
| `preview/shot-1/2/3-*.png` | 三张状态截图重新生成 |
| `README.md` | 第十九节「三键等宽」补注，新增本节 |

高度仍为 116pt（第二十六节起降为 76pt），间距仍为 10pt；手势映射、滚动方向、报告格式、广播 UUID 与断开功能一律未动。
本节改动已随 `v0.0.8-63bc75b` 出包，作为键鼠复合实验前的**可回滚基线**。

---

## 二十二、选项 B：键鼠复合设备与三指上滑回桌面（实验性）

### 结论与前提

标准 HID 鼠标没有通道上报 iPadOS 的「三指上滑」——那是妙控板硬件上报的多点触控数据。
确定可用的替代是键盘快捷键 `Command + H`（回主屏幕），所以要把设备扩展为 Mouse + Keyboard
复合 HID。**这是实验功能，存在让 iPad 拒绝接管整个设备、鼠标一起失效的风险。**

动手前先出了一版纯鼠标基线包 `v0.0.8-63bc75b`（未签名 IPA 已下载到 `build/`），
失败时重装即可回来；App 内也提供一键回退开关。

### 实现选择：单一复合报告，不引入 Report ID

原本计划「加 Report ID + 第二个 Report 特征」，实际改为**同一条报告里拼接两个 Collection**：

| 项目 | 纯鼠标模式 | 键鼠复合模式 |
| --- | --- | --- |
| Report Map | Mouse 一个 Application Collection | Mouse + Keyboard 两个 Application Collection |
| Report ID | 无 | 无（HID 1.11 允许多顶层 Collection 共用一条报告） |
| 2A4D 输入报告长度 | 4 字节 | 12 字节 |
| 报告内容 | `[buttons, dx, dy, wheel]` | `[buttons, dx, dy, wheel, modifier, reserved, k1..k6]` |
| 2A33 Boot Mouse | 3 字节 | 3 字节（不变） |
| GATT 结构 | 3 服务 / 6 特征 | **完全不变** |

改用单一复合报告的四个理由：

1. 鼠标部分前 4 字节逐字节不变，主机即使忽略 Keyboard Collection，鼠标解析也与基线版一致；
2. 不用改 GATT 结构，也不用处理两个同 UUID 的 `2A4D` 特征在订阅 / 读取时的歧义；
3. 所有鼠标事件天然带着键盘字段（全 0 = 无按键），不存在「按下报告被覆盖导致按键卡住」；
4. 运行时开关即可回退，无需 Report ID 前缀切换。

`Command + H` 对应 `modifier = 0x08`（Left GUI）+ `keycode = 0x0B`（H）。

### 键盘报告如何发送

`goHome()` 不直接发 BLE 包，只调用通用的 `sendKey(keycode:modifiers:)` 设置
`pendingModifier` / `pendingKeycode` 与约 0.06 秒的到期时间；
`tick()`（60Hz CADisplayLink）在到期前把键码和 modifier 合进每一帧的复合报告，
到期那一帧发一份键盘字段全 0 的报告完成释放，并连发几帧空报告兜底。
按下与释放都走同一条报告流，连按同一个键前会先补一帧「全松开」，
避免主机把第二次按下当成一直按住。三指手势用 `UIPanGestureRecognizer` 限制 3 指、
上滑 80pt 触发一次，与 1 指平移 / 2 指滚动靠触点数硬隔离。
本轮把固定的 `Command + H` 泛化成了任意键码 + 任意修饰键组合，全键盘界面共用这条链路。

### 运行时开关与回退步骤

设置 → 实验功能 · 全键盘与回桌面 → 「键鼠复合模式」，默认开启。切换开关会调用 `disconnect()`
移除整个 GATT 服务并停止广播（主机缓存了 Report Map，无法热更新）。

| 场景 | 操作 |
| --- | --- |
| 首次试用 | 装新包 → 保持开关开启 → iPad 蓝牙「忽略此设备」→ App 点「开始广播」→ 重新配对 |
| 鼠标失效 / iPad 拒绝接管 | 关掉「键鼠复合模式」→ iPad 蓝牙「忽略此设备」→ 重新广播并配对，即回到 4 字节纯鼠标 |
| 仍不恢复 | 重装基线 IPA `v0.0.8-63bc75b`（Sideloadly 重签），基线不含任何键盘代码 |

**必须重新配对**：不「忽略此设备」的话 iPad 会沿用缓存的旧 Report Map，
开关看起来切了但描述符没刷新。日志里会打印当前模式和这几步提示。

### 已知限制与真机验证清单

| 限制 | 说明 |
| --- | --- |
| iPad 可能按键盘配对 | 弹出「在键盘上输入验证码」之类的验证，或直接拒绝接管整个设备 |
| Boot Protocol | 主机若写 `2A4E` 切到 Boot 模式，报告固定 3 字节，滚轮和键盘都失效；日志会提示 |
| Command+H 只对 iPadOS 有效 | Windows 显示桌面是 `Win + D`、macOS 是 `F11`，本设备不发这两个组合 |
| 三指手势不是系统手势 | 只是 App 识别三指位移后发一个键盘组合键，没有妙控板那种跟手动画 |
| 复合设备识别 | Apple 会审查 HID 配置，带 Keyboard Collection 的设备可能被重新分类，需真机确认 |

真机上按顺序确认：① 蓝牙列表能否发现并配对；② 指针 / 左键 / 右键 / 滚轮是否仍正常；
③ 三指上滑是否回主屏幕；④ 日志里是否出现「三指上滑 → 发送 Command + H」；
⑤ 关掉开关重新配对后是否恢复纯鼠标。任一环节异常先按上表回退，不要反复重装。

| 文件 | 改动 |
| --- | --- |
| `HIDDescriptor.swift` | 新增 Keyboard Collection 描述符、`compositeReportMap`、12 字节 `makeReport` / `emptyReport`、`reportMap(composite:)` |
| `HIDPeripheral.swift` | 新增 `compositeDevice` 持久化开关与切换逻辑、`goHome()`、tick 合成键盘状态、flush 支持键盘字段、2A4B / 2A4D 按模式返回、Boot 模式提示 |
| `TrackpadSurface.swift` | 新增三指 pan 手势与 80pt 阈值；提示文字按模式显示第三行 |
| `ContentView.swift` | 设置页新增「实验功能 · 回桌面」分组 |
| `preview/ui-preview.html` | 开关、提示文字、状态面板、元素清单第 17 项、代码行号同步 |
| `README.md` | 第七节边界、第二十节结论更新，新增本节 |

广播 UUID、服务数量、Boot Mouse、点击手势、滚动方向、按键宽度与高度一律未动。

## 二十三、全键盘：触控区顶部一键切换

### 入口与交互

已连接（主机订阅 `2A4D`）后，触控区顶部新增一条 46pt 切换栏：左侧「触控板模式」，
右侧蓝色主按钮「全键盘」。点按钮把中间输入区从 `TrackpadSurface` 换成 `KeyboardPanel`；
底部左键 / 滚轮 / 右键三键保持常驻，打字时仍可点鼠标。键盘页顶部「‹ 触控板」返回。
断开连接时自动回到触控板，下次连接不会停在键盘页。
键盘未就绪（复合模式关闭、Boot Protocol 或未订阅输入报告）时，切换栏显示橙色「键盘未就绪」，
键盘页顶部给出具体原因提示。

### 两页布局（功能页已并入主键位，见第二十四节）

| 页面 | 行数 | 内容 |
| --- | --- | --- |
| 主键位 | 7 行 | F1~F12 一整行、数字行、QWERTY 三行、Esc / Tab / Caps / Del / Home / End + 四向方向键、常驻控制行（Ctrl / Opt / Cmd / Shift / Space / 退格 / 回车） |
| 符号 | 5 行 | 上档符号 `!@#$%^&*()`、US 标点两行、Ins / PrtSc / ScrLk / Pause / PgUp / PgDn / Menu、常驻控制行 |

两页统一 42pt 键帽（主键位 7 行时行距略收紧），键宽按权重分配。键区靠上排列，
其下剩余空间全部是小触控区，紧贴键区、无标题与提示文字（见第二十五、二十六节）。
功能键底色比字符键深，粘滞修饰键激活时变蓝。原「功能」页的所有键码都保留了，只是重新分配。

### 组合键：一次性粘滞修饰键

`Ctrl` / `Opt` / `Cmd` / `Shift` 四个键不单独发报告，点一下亮起（位图按位或），
下一次点普通键时把粘滞位图一起塞进报告的 modifier 字节，发完自动清零。
粘滞状态不再单独占一行：默认完全不显示任何提示，仅在激活时于顶部工具条右侧出现
「⌃ ⇧ ⌥ ⌘ 清除」短徽标，点一下即清除（第二十七节起；第二十六节曾把它放在独立状态条里）。

| 想发的组合 | 操作 |
| --- | --- |
| Command + C | 点 `Cmd` → 点 `C` |
| Command + Shift + 4 | 点 `Cmd` → 点 `Shift` → 点 `4` |
| 大写字母 Q | 点 `Shift` → 点 `Q` |

字母键帽显示大写，但报告里发的是小写键码；大小写完全由粘滞 Shift 决定，
避免「键盘显示大写就一直输出大写」。上档符号（`!`、`@` 等）自带 Shift 位。

### HID 链路

`KeyboardPanel` 只负责把按键解析成 `(keycode, modifier)`，交给
`HIDPeripheral.sendKey(_:modifiers:label:)`。报告仍是复合模式的 12 字节：
`[buttons, dx, dy, wheel, modifier, reserved, k1..k6]`，键盘部分只占第 5、7 字节。
每次按键按下约 0.06 秒，由 60Hz `tick()` 合帧发出，到期连发空键盘帧完成释放；
连按同一个键前先补一帧「全松开」，避免漏字。鼠标点击插入的报告会保留当前按下的键，
不会把键盘键提前松开。三指上滑的 `Command + H` 走同一条 `sendKey` 链路，
因此本轮没有新增任何 GATT 特征或 Report ID。

### 已知限制

| 限制 | 说明 |
| --- | --- |
| 键码范围 | Report Map 声明 Usage Maximum = 101 (`0x65`)，只发该范围内的 HID 键码；音量、亮度等多媒体键属 Consumer Page `0x0C`，未声明，无法发送 |
| 中文与 emoji | 只发键码、不写字符；中文输入依赖主机输入法，输入法切换键由主机定义 |
| 一次一键 | 界面一次只发一个普通键，未做 6 键同时按下（6KRO），组合键靠粘滞修饰键实现 |
| 依赖复合模式 | 关掉「键鼠复合模式」或主机切到 Boot Protocol 时按键不会发送，日志写明原因 |
| 配对缓存 | 开启复合模式后必须在 iPad 蓝牙里「忽略此设备」再重新配对，否则主机沿用旧 Report Map |
| 键盘布局 | 按 US ANSI 布局解析；主机若使用其它键盘布局，符号位置可能不同 |
| 系统输入法 | 这是 App 内自绘键盘，不调起 iOS 输入法，App 内也不显示候选词 |

### 真机验证清单

① 连接后顶部是否出现「全键盘」按钮；② 切到键盘页后底部三键是否仍可用；
③ 主键位连打 `hello` 是否为小写；④ 粘滞 `Cmd` + `C` 在 iPad 是否触发拷贝；
⑤ 主键位页 F1~F12、方向键与符号页 `!` / PgUp 是否正确；⑥ 日志是否打印对应 keycode 与 modifier；
⑦ 关掉「键鼠复合模式」后是否出现橙色警告且日志说明原因；
⑧ 返回触控板后单指 / 双指 / 三指手势是否照常。
任一环节异常，按第二十二节的回退表关掉复合开关、忽略设备重新配对，或重装 `v0.0.8-63bc75b` 基线包。

| 文件 | 改动 |
| --- | --- |
| `KeyboardView.swift`（新增） | HID 键码解析、两页布局、粘滞修饰键、键帽与顶部工具条 |
| `HIDPeripheral.swift` | 固定 `Command + H` 泛化为 `sendKey`；新增 `keyboardReady`、可变 modifier、连按补空帧、key-up 连发兜底 |
| `HIDDescriptor.swift` | 新增 8 个修饰键位常量、`maxKeyboardKeycode`，`makeReport` 支持多键码数组 |
| `ContentView.swift` | 新增 `TrackpadTopBar` 切换栏与 `showKeyboard` 状态；设置页两行说明与分组标题更新 |
| `preview/ui-preview.html` | 第五个状态「已连接 · 全键盘」、两页键盘与粘滞交互模拟、元素清单第 18~23 项、全部代码行号同步 |
| `preview/shot-*.png` | 重新生成 5 张状态截图：`shot-4-keyboard.png`（主键位）、`shot-5-keyboard-symbols.png`（符号） |
| `README.md` | 更新第二十二节链路描述与分组名称，新增本节 |

预览页支持 `?state=keyboard`（主键位）与 `?state=keyboard&page=symbols`（符号）直接打开对应页；
点任意键帽会在右侧事件记录里打印对应的 keycode 与 modifier，方便对照真机日志。
旧参数 `page=functions` 仍可解析，会落到合并后的主键位页。

## 二十四、主键位与功能页合并（本轮新增）

原三页键盘里，F1~F12 和方向键必须切到独立的「功能」页才能按到，打字和控制来回切页不方便。
本轮把功能页并入主键位，分段控件从三页减到两页。

### 键位重新分配

| 去向 | 键 |
| --- | --- |
| 主键位第 1 行 | `F1` ~ `F12`（12 个等宽键，标签字号缩到 10px 以容纳三字符 `F10` / `F11` / `F12`） |
| 主键位第 6 行 | `Esc` `Tab` `Caps` `Del` `Home` `End` `←` `↓` `↑` `→` |
| 符号第 4 行 | `Ins` `PrtSc` `ScrLk` `Pause` `PgUp` `PgDn` `Menu` |

`Menu` = `0x65` 是这一轮新放上界面的键（键码表本来就有，正好落在 Report Map 的
Usage Maximum = 101 边界内）。原功能页的 Esc / Tab / Caps / Del / Home / End / PgUp / PgDn
与四向方向键全部保留，**没有因为合并丢任何键码**。

### 行高与排版

主键位从 5 行变 7 行，`KeyboardPanel` 把行高做成可传参：两页统一 42pt，
而不是让主键位缩到 38pt、符号页保持 44pt——那样切页时键帽会忽大忽小。
`KeyRow` / `KeyCap` 新增 `height` 参数，行数不再隐式决定键帽高度。键区初期上下居中，
第二十五节起改为靠上排列、下方留弹性间隔与固定高度小触控区；
第二十六节起弹性间隔和说明文字全部去掉，触控区撑满键区以下空间并贴住键区。
预览页用 `.kb-rows.compact` 收紧 7 行页面的行距与功能键字号，和 Swift 端保持一致。

### 未改动

HID 报告格式（12 字节复合报告）、`sendKey` 链路、粘滞修饰键、键码表、GATT 服务、
广播 UUID、三指上滑、触控区手势、底部三键一律未动；只改了界面布局与文案。

| 文件 | 改动 |
| --- | --- |
| `KeyboardView.swift` | `KeyboardPage` 删 `functions`；`KeyboardLayout.rows` 重排两页；`KeyRow` / `KeyCap` 支持 `height`；footer 与顶部注释更新 |
| `ContentView.swift` | 设置页「全键盘」说明改为「主键位（含 F 键 / 方向键）与符号，共两页」 |
| `preview/ui-preview.html` | 两页分段控件、`kbRows()` 重写、42pt 与 compact 样式、状态键值 / 事件日志 / 元素清单 / 全部代码行号同步 |
| `preview/shot-*.png` | 删除 `shot-5-keyboard-functions.png`，新增 `shot-5-keyboard-symbols.png`，其余 4 张重新生成 |
| `README.md` | 第二十三节改为两页布局，新增本节 |

### 真机验证补充

① 分段控件只有「主键位」「符号」两项；② 主键位 7 行在真机上无裁切、键帽不重叠；
③ `F12`、四向方向键、`Menu` 按下后日志打印的 keycode 分别为 `0x45` / `0x50` `0x51` `0x52` `0x4F` / `0x65`；
④ 主键位与符号页来回切换时键帽高度无跳变；⑤ 底部三键、返回触控板与三指上滑仍正常。
若小屏上 7 行显得过挤，回退方式是把 `KeyboardPanel` 的 `rowHeight` 调到 38pt 再出包，
不需要改键位表或 HID 链路。

## 二十五、Esc / ↑ 移到 Z / M 两侧，键盘页下方加小触控区

> 演进记录：本节的 120pt 固定高度、键区下方弹性间隔、compact 三行提示文字与底部 footer
> 已在第二十六节全部移除；键位调整部分（`Esc` / `↑` 贴 Z / M 两侧）仍然有效。

### 键位调整

主键位第 5 行原来左右各 1.5 权重的空白 spacer 换成按键：`Esc` 在 Z 左侧贴键区左边缘，
`↑` 在 M 右侧贴键区右边缘；第 6 行去掉已移走的这两个键，剩
`Tab` `Caps` `Del` `Home` `End` `←` `↓` `→`（8 键，键帽比原来宽）。
键码不变（`Esc` = `0x29`、`↑` = `0x52`），四向方向键仍齐全，只是 ↑ 换了位置；
符号页未动。

### 键区上移与小触控区

`KeyboardPanel` 去掉键区上方的弹性间隔，7 行键区紧跟粘滞状态条；下方用一个弹性间隔
把 120pt 的小触控区推到底部 footer 之上。小触控区直接复用 `TrackpadSurface`，
新增 `compact` 参数：提示文字精简为三行、圆角 22 → 12、字号 footnote → caption2。
手势完全不变——单指移动、轻点左键、双击、长按右键、双指滚动、三指上滑 80pt 都能用，
打字时也能移动指针和点击，不必来回切「触控板 / 全键盘」。

> 后续演进：第二十六节删掉弹性间隔与 120pt 固定高度，小触控区改为撑满键区以下全部空间；
> 第二十七节再删掉键区上方的独立状态条，键区继续上移约 30pt。
全屏触控板仍用 `TrackpadSurface(edgeToEdge: true)`，`compact` 默认 false，行为不受影响。

120pt 高度下三指上滑的 80pt 阈值仍可达但较局促；若真机上难触发，
把 `miniTrackpad` 的 `frame(height:)` 调到 140pt 即可，不用改手势逻辑。

### 预览与截图

`preview/ui-preview.html` 同步两行键位、键区靠上布局，新增 `miniPadHTML()` 与
`.kb-minipad` / `.pad-mini` 样式；方向键改用 14~15px 字号（真机单字符是 16px，
预览原来按功能键压到 10px 会把 `←` `→` 显示成横线）；footer 缩短避免与卡片下缘重叠。
元素清单新增第 24~25 项，`KeyboardView.swift` 与 `TrackpadSurface.swift` 的全部行号重新同步。
5 张截图全部重新生成，主键位与符号页都能看到底部小触控区。

### 真机验证

① Esc 是否紧贴 Z 左侧、↑ 是否紧贴 M 右侧，字母键有没有被挤窄；
② 第 6 行不再出现 Esc / ↑，`←` `↓` `→` 是否清晰可辨；
③ 键区是否明显上移，底部小触控区能否拖动指针并点击；
④ 小触控区里双指滚动与三指上滑是否仍触发；
⑤ 切回触控板页后全屏样式（无圆角、无边框、无灰底）是否照旧。

| 文件 | 改动 |
| --- | --- |
| `KeyboardView.swift` | 第 5 / 6 行键位重排；`body` 去掉上方 Spacer、键区靠上；新增 `miniTrackpad`（120pt）；footer 文案缩短 |
| `TrackpadSurface.swift` | 新增 `compact` 参数：精简提示、小圆角、小字号；`hintText` / `applyStyle` 同步；全屏行为不变 |
| `ContentView.swift` | 设置页「全键盘」说明改为「两页键位 + 下方小触控区（可移动指针）」 |
| `preview/ui-preview.html` | 键位、布局、小触控区、方向键字号、元素清单 24~25、两个 Swift 文件全部行号同步 |
| `README.md` | 第二十三 / 二十四节布局描述更新，新增本节 |

---

## 二十六、底部三键降高、小触控区撑满、键盘页说明文字精简（本轮新增）

### 三项改动

| 项目 | 之前 | 现在 |
| --- | --- | --- |
| 底部三键条 | `frame(height: 116)`，上下 padding 8 / 10 | `frame(height: 76)`，padding 6 / 8 |
| 小触控区 | 固定 `frame(height: 120)`，上方有 `Spacer`，下方有 footer | 去掉 Spacer 与 footer，`frame(maxHeight: .infinity)` 吃掉键区以下全部空间，紧贴键区 |
| 键盘页文字 | 粘滞长句、小触控区标题、触控区内三行提示、底部 footer | 四处说明文字全部删除 |

`ContentView.swift` 只改了 `ButtonBar` 的高度与 padding，三键 3:2:3 宽度比、按住 / 抬起、
滚轮拖动与双击中键逻辑完全没动；变矮后滚轮键的两行小字仍能完整显示。

`KeyboardView.swift` 的 `body` 里删掉 `Spacer(minLength: 6)` 与 `footer`，
`miniTrackpad` 从「标题 + 120pt 固定卡片」改成单个 `TrackpadSurface(compact: true)`
加 `maxHeight: .infinity`，左右 10pt、上下 6pt padding。符号页只有 5 行键，
触控区相应更高，两页的紧贴关系一致。

### 删除的文字与保留的文字

| 位置 | 内容 | 处理 |
| --- | --- | --- |
| 键区上方 | 粘滞状态条「修饰键：点一下临时按住，随下一次按键自动释放」+「键盘」图标标签 | 删除；仅在粘滞激活时显示简短组合名（第二十七节起整条状态行删除） |
| 键区上方 | 状态条右侧常驻的禁用「清除」按钮 | 改为仅粘滞激活时出现（第二十七节起并入工具条短徽标） |
| 小触控区上方 | 「小触控区 · 手势与全屏触控板一致」标题 | 删除 |
| 小触控区内部 | compact 三行手势提示 | 删除；`hint.isHidden = compact`，`hintText` 不再有 compact 分支 |
| 小触控区下方 | 「Esc / ↑ 贴 Z / M 两侧……」footer | 删除整个 `footer` 属性 |
| 全屏触控板 | 三行手势提示 | 保留（`compact = false`） |
| 条件性错误 | 橙色「键盘暂不可用」警告 | 保留，属于错误提示不是说明文案 |
| 按键 / 控件 | 键帽文字、分段控件、返回按钮、底部三键标签 | 保留 |

`TrackpadSurface.swift` 的 `makeUIView` / `updateUIView` 在 `compact` 时把 hint label 隐藏，
全屏触控板仍显示完整手势说明。`warning` 只在键盘不可用时出现，不算说明文字，予以保留。

### 未改动

HID 报告格式（12 字节复合报告）、`sendKey`、粘滞修饰键位图、键码表、两页键位、
Esc / ↑ 位置、GATT 服务、广播 UUID、三指上滑 80pt 阈值、所有触控手势、
全屏触控板 `edgeToEdge` 样式一律未动；只改了尺寸、布局与文案。

### 预览与截图

`preview/ui-preview.html` 同步：`.buttonbar` 150px → 100px、`.kb-sticky` 28px → 24px、
`.kb-minipad` 固定 120px 改为 `flex:1 1 auto`，删除 `.kb-minipad-title` / `.kb-footer` /
`.pad-mini .pad-hint` / `.kb-gap` 样式；`miniPadHint()` 与标题 DOM 删除，
`padInner(..., true)` 不再输出提示，`kb-clear` 与粘滞状态仅在激活时渲染。
元素清单新增第 26 项，第 7 / 9 / 20 / 23 / 25 项同步，`KeyboardView.swift`、
`TrackpadSurface.swift`、`ContentView.swift` 的全部代码行号重新核对。
5 张截图重新生成。

### 真机验证

① 底部三键明显变矮且仍能按住 / 拖动，滚轮键两行小字未被裁切；
② 键盘页小触控区是否紧贴键区、面积是否明显变大；
③ 小触控区里单指移动、点击、双指滚动、三指上滑是否都正常（80pt 阈值现在更容易触发）；
④ 键盘页默认无任何说明文字，点 `Cmd` 后是否出现简短状态与「清除」；
⑤ 切回触控板页后全屏三行提示是否仍在。

| 文件 | 改动 |
| --- | --- |
| `ContentView.swift` | `ButtonBar` 高度 116pt → 76pt，padding 收紧 |
| `KeyboardView.swift` | `body` 去掉 Spacer / footer；`miniTrackpad` 撑满剩余空间；`stickyBar` 与「清除」改为条件显示；footer 属性删除 |
| `TrackpadSurface.swift` | compact 隐藏 hint label；`hintText` 简化为单一全屏文案；全屏提示不变 |
| `preview/ui-preview.html` | 样式、DOM、交互、元素清单与全部代码行号同步 |
| `preview/shot-*.png` | 5 张状态截图重新生成 |
| `README.md` | 第二十一 / 二十三 / 二十四 / 二十五节描述更新，新增本节 |

---

## 二十七、键盘区再往上挪一点点（本轮新增）

用户反馈：主键位键区上方还留着一点空间，要求再往上挪。定位后发现那点空间是
`KeyboardPanel` 里工具条下方的整行粘滞状态条（默认无内容，但仍占 24pt），
外加键区顶部 8pt、小触控区顶部 6pt 的间距。

### 具体改动

| 位置 | 之前 | 现在 |
| --- | --- | --- |
| 工具条下方 | 独立 `stickyBar`，固定 `frame(height: 24)`，默认一行空白 | 整行删除；`body` 里不再插入 `stickyBar` |
| 粘滞状态 | 状态条左侧组合名 + 右侧「清除」按钮 | 并入顶部 `toolbar` 右侧的短徽标「⌃ ⇧ ⌥ ⌘ 清除」，仅 `sticky != 0` 时出现，点击即清零 |
| 键区顶部间距 | `.padding(.top, 8)` | `.padding(.top, 2)` |
| 小触控区顶部间距 | `.padding(.top, 6)` | `.padding(.top, 4)` |
| 小触控区高度 | 吃掉键区以下剩余空间 | 再多约 30pt（键区上移的 24 + 6 + 2 = 32pt，其中 2pt 用于贴合） |

工具条高度固定，粘滞徽标只是横向占一小段宽度，不会把键区往下推；
切页、按下 / 释放粘滞键时键区都不会垂直跳动。徽标用 `⌃ ⇧ ⌥ ⌘` 单字符表示，
完整组合名仍保留在 `accessibilityLabel`（「清除粘滞修饰键：Ctrl + Shift + …」）里，
避免把两页分段控件挤窄。`stickyNames` 保留供无障碍标签与调试使用。

### 未改动

两页键位与键帽高度（42pt）、键码表、`sendKey`、粘滞位图逻辑、12 字节复合报告、
三指上滑 80pt 阈值、全部触控手势、全屏触控板 `edgeToEdge` 样式、
底部三键 76pt 与 3:2:3 宽度比、橙色 `warning`（条件性错误提示）一律未动。
本轮只动了键盘页的垂直间距与粘滞状态呈现方式。

### 预览与截图

`preview/ui-preview.html`：删除 `.kb-sticky` 整块样式与 DOM，新增工具条内 `.kb-badge`
及 `stickyBadge()`；`.kb-rows.top` 顶部 6px → 2px，`.kb-minipad` 顶部 6px → 4px；
元素清单第 19 / 20 / 25 / 26 项描述与行号同步，新增第 27 项；
所有 `KeyboardView.swift:NNN` 行号按新文件重新核对（工具条 242-282、
徽标 262-276 / 287-303、键区 205-228、小触控区 232-238）。
`shot-1` ~ `shot-5` 五张截图全部重新生成：主键位页工具条与 F1 行之间只剩约 2pt 间距，
小触控区明显增高；符号页因只有 5 行键，触控区更高。

### 真机验证

① 主键位页键区是否紧贴工具条、下方空白是否消失；
② 小触控区是否相应变高，单指移动 / 轻点 / 双指滚动 / 三指上滑仍可用；
③ 点 `Cmd` 后工具条右侧是否出现短徽标、点徽标是否立即清除粘滞；
④ 徽标出现时「主键位 / 符号」分段控件是否仍可点；
⑤ 切回全屏触控板页样式与手势提示是否照旧。

| 文件 | 改动 |
| --- | --- |
| `KeyboardView.swift` | `body` 删除 `stickyBar`；键区顶部 8→2pt；`miniTrackpad` 顶部 6→4pt；`toolbar` 增加粘滞徽标；新增 `stickyBadge`，删除 `stickyBar` 属性 |
| `preview/ui-preview.html` | 状态条样式 / DOM 改为工具条徽标，间距与元素清单、全部 Swift 行号同步 |
| `preview/shot-*.png` | 5 张状态截图重新生成 |
| `README.md` | 第二十三 / 二十五 / 二十六节补注，新增本节 |

---

## 二十八、引导页连接日志卡片通栏对齐（本轮新增）

用户反馈：App 刚打开时连接日志的初始宽度很窄，不好看，要求对齐其他卡片。

### 原因

`setupBody` 是一个 `ScrollView { VStack(spacing: 14) { ... } }`。SwiftUI 的 `VStack`
默认按最宽子视图决定自身宽度，且子视图默认居中对齐；状态卡片和「指针与滚动」卡片
因为有两行长文案、滑块和 `Spacer()`，自然被撑到接近屏宽，而连接日志卡片只有标题
「连接日志」和一行短日志（`-- 尚未开始广播…`），没有 `maxWidth: .infinity`，
于是按内容宽度缩成一条窄卡片并居中，左右边缘与上面两张卡片都不齐。
网页预览里的 `.card` 是块级元素会自动撑满，所以截图看不出这个差异，真机才暴露。

### 改动

| 位置 | 处理 |
| --- | --- |
| 状态卡片 | 在 `.padding(14)` 之前加 `.frame(maxWidth: .infinity, alignment: .leading)` |
| 指针与滚动卡片 | 同上（显式锁定，避免以后改文案时又缩回去） |
| 连接日志卡片 | 同上；这是本次要修的那张 |
| 日志内部 `VStack` | 加 `.frame(maxWidth: .infinity, alignment: .leading)`，日志行铺满卡片宽度 |
| 日志 `ScrollView` | 加 `.frame(maxWidth: .infinity)`，高度仍固定 108pt |

`frame` 必须放在 `padding` / `background` **之前**，否则背景仍按原来的窄宽度绘制，
只在外层留白，看起来还是一张窄卡片。三张卡片现在左右各留 16pt，圆角 14pt，
与底部说明文字、诊断卡片一起严格对齐。日志内容、日志行数上限 10 行、
108pt 高度、等宽字体、连接状态判定一律未动。

### 未改动

蓝牙链路、GATT 服务、广播 UUID、HID 报告、三指上滑、全键盘、底部三键、
设置子页面、连接后的全屏触控区全部未动。本轮只改引导页三张卡片的宽度约束。

### 预览与真机验证

`preview/ui-preview.html` 给 `.card` / `.diag` / `.logbox` 加 `width:100%`
与 `box-sizing:border-box`，显式对应 SwiftUI 的通栏约束；元素清单第 8 项描述更新，
新增第 28 项，`ContentView.swift` 全部代码行号按新文件重算（引导页 100-125 / 126-156 /
158-180 / 182-185，其后的设置页与按键条整体 +6 行）。5 张截图重新生成，
实际视觉变化集中在 `shot-1-setup.png`。

真机看三点：① 刚打开时连接日志卡片左右边缘是否与状态卡片、指针与滚动卡片齐平；
② 点「开始广播」后多行日志是否铺满卡片宽度、长日志仍可滚动查看；
③ 连接成功后全屏触控区、底部三键是否照旧。

| 文件 | 改动 |
| --- | --- |
| `ContentView.swift` | 引导页三张卡片与日志内层各加 `maxWidth: .infinity` 约束；补两行注释 |
| `preview/ui-preview.html` | `.card` / `.diag` / `.logbox` 显式通栏；元素清单与全部行号同步 |
| `preview/shot-*.png` | 5 张状态截图重新生成 |
| `README.md` | 第十八节补注，新增本节 |

## 二十九、iPad 中文拼音选词（本轮新增）

用户反馈：用本 App 当键盘，在 iPad 系统自带中文拼音输入法上能打字，但打好的中文字词
**没法选择**（候选词选不中）。

### 原因

本 App 的键盘走标准 USB HID 键盘报告（12 字节复合报告的键盘部分：`modifier + reserved +
6 键码`），键码表与字母键完全相同——字母能打出来，证明键盘报告被正确解析，数字键 `1-9`、
空格、回车在 HID 层都能正确送到 iPad。

但 **iPadOS 系统自带拼音输入法的候选条，对「BLE 复合键鼠外设」的键盘选词经常不触发**：
数字 `1-9`、空格、方向键虽然进了系统，却被输入法路由到了文本而不是候选 UI，表现为「按了没反应」。
这是 iPadOS 对这类 HID 设备的输入法处理差异（非本 App 报告格式问题，也非键码错误）。

**真正稳的选词路径只有一条——用鼠标链路点选候选条**：

1. **点选候选条（推荐）**：键盘页下方那块小触控区（复用 `TrackpadSurface`）控制的就是
   iPad 系统指针。单指移动指针到 iPad 屏幕**顶部/底部的候选条**上，轻点左键即选词。
   这是指针事件，走鼠标链路，完全绕开输入法的键盘选词差异，任何输入法、任何机型都稳。
2. 备选 `←/→` 移动高亮 + `空格`/`回车` 确认，与第 1 条共用同一套 IME 键盘路径，
   在某些配置下可用，但不如点选可靠。

另外，原 `sendKey` 把按键按住 60ms 就松键。iPad 中文输入法在组合态下对选词按键的采样更挑剔，
过短的按下时间可能让 IME 漏掉该次击键，故持续延长按住时长（0.06s → 0.09s → 0.12s）。

### 改动

| 位置 | 处理 |
| --- | --- |
| `HIDPeripheral.swift` | `sendKey` 的 `keyReleaseAt` 由 0.09s 延长到 0.12s，进一步确保 IME 能稳定收到选词按键 |
| `KeyboardView.swift` | 选词提示改写为以「触控区移动指针点候选条」为主路径：`选词：用下方小触控区移动指针，点 iPad 顶部候选条最稳；或 ←/→ + 空格/回车` |
| `preview/ui-preview.html` | 键盘渲染 `.kb-imehint` 同步改写；元素清单第 29 项更新 |

蓝牙链路、HID 报告格式、键码表、底部三键、小触控区手势一律未动。

### 真机验证（待用户反馈）

重点看：① 拼音组合态下用**下方小触控区移动指针到 iPad 候选条、左键点选**能否稳定选词；
② 键盘页下方那行选词提示是否显示且没挤乱布局；③ `←/→` + 空格/回车是否也能选词（作为备选）。

## 三十、断开后切换其他设备（Windows / Android）（本轮新增）

用户反馈：按「断开」后「重新连接」总是直接连回自己的 iPad，想连 Windows PC 或安卓平板
连不上。

### 原因（BLE HID 的固有天花板）

蓝牙 HID 的**配对信息（绑定/LTK）存在主机侧**。一旦 iPad 与本 App 配对，iPad 会**主动回连**
已绑定的 HID 外设——这个重连由 iPad（中央设备）发起，本 App 作为外设（周边设备）无能为力：
CoreBluetooth 既没有「断开指定中央」的公开接口，也不提供删除对端配对的方法。所以只要 iPad
仍保留配对，本 App 一广播，iPad 就会抢先连上，Windows/Android 根本没机会。

结论：**要切到别的设备，必须先在 iPad 蓝牙里「忽略此设备」**，这是 iOS 限制，不是 App bug。
本 App 侧能做的只是「断开后保持停止广播、让用户决定何时重新广播」，避免 iPad 立刻自动回连。

### Windows 实测结论（硬平台限制）

用户按上述流程（iPad 忽略本设备 → 回 App 点「开始广播」）后，**Windows 蓝牙「添加设备 → 蓝牙」
窗口仍搜不到 PT-Pad**。根因不是操作问题，而是 **iOS HID 外设与 Windows BLE HID 配对流程不兼容**：

- `CBPeripheralManager` 把 iPhone 注册成 BLE HID 外设，iPadOS / macOS / 多数 Android 能接管，
  但 **Windows 的 BLE HID 配对（SMP 配对 / 服务发现）与 iOS 外设实现不匹配**，Nordic 官方论坛与
  GitHub 实测均显示 Windows 连 iOS HID 外设时要么搜不到、要么连上后不做服务发现 / 卡在配对。
- 这是系统级限制，**纯 iOS App 代码无法绕过**：广播包已是标准 16 位 `0x1812` HID UUID + 名称，
  没有更多可调整的广播字段（`CBPeripheralManager` 只允许 LocalName 与 ServiceUUIDs 两项）。

### 出路：ESP32 硬件桥（针对 Windows / 安卓）

要让 Windows / 安卓稳定使用，可靠路径是 **ESP32 硬件桥**：

1. iPhone 跑本 App 收集触摸/按键，通过 WiFi（或 BLE 串口）把指针位移、点击、键码发给 ESP32；
2. ESP32 以**标准 BLE HID 外设**身份连接 Windows / 安卓（ESP32 的 HID 实现与 Windows 完全兼容）；
3. 这样 iPhone 仍当「输入采集端」，ESP32 当「标准 HID 发射端」，Windows / 安卓把它当普通蓝牙键鼠。

ESP32 固件与 iPhone 端透传是另一个独立子项目，代码里已在多处注释埋下该方向；需要的话可单开分支实现。

### 改动

| 位置 | 处理 |
| --- | --- |
| `ContentView.swift` | 「断开」按钮点击后 `disconnect()`，再弹一次性「切换设备」指引：先在 iPad 蓝牙忽略本设备 → 目标设备搜索配对 PT-Pad → 回 App 点「开始广播」 |
| `ContentView.swift` | 设置新增「切换设备」分组：iPad 自动重连 / 切到 Windows / 切到 Android / 本 App 操作；并写明 **Windows 时序要点**（先开电脑添加窗口再点开始广播、发现窗口短）与局限（Windows / 部分 Android 与 iOS HID 外设配对不完全兼容，可能需 ESP32 硬件桥） |
| `ContentView.swift` | 断开弹窗同步加入 Windows 时序要点与 ESP32 出路提示 |
| `disconnect()` | 行为不变（停广播 + 移除 GATT 服务 + 释放 manager），只是这次把切换指引补进了提示与弹窗 |
| `preview/ui-preview.html` | 断开时复刻真机弹窗；设置加「切换设备」分组（含 Windows 时序）；元素清单第 30 项更新 |

`disconnect()` 在 v0.0.7 起就是「停止广播 + 移除服务」的实现，本身不自动重连；
之前日志里也写过「若 iPad 仍在附近且保留配对，可能自动重连」，只是用户没注意到，
这次把它前置成断开后的弹窗和设置独立章节。

### 真机验证（待用户反馈）

重点看：① 断开后是否弹出切换指引；② iPad「忽略此设备」后本 App 重广播，Android 能否搜索并配对
（iOS 外设对 Android 兼容性好于 Windows）；③ 若目标是 Windows，确认是否仍搜不到 —— 若是，
走 ESP32 硬件桥方案，不要在本 App 内继续耗；④ 用下方小触控区点选 iPad 候选条能否稳定选词。

| 文件 | 改动 |
| --- | --- |
| `ContentView.swift` | 断开弹窗 +「切换设备」设置分组（含 Windows 时序与 ESP32 出路）；`DisconnectButton` 改为接收 `onDisconnected` 回调（alert 挂常驻视图） |
| `KeyboardView.swift` | 选词提示改写为触控区点选为主路径 |
| `HIDPeripheral.swift` | 按键按住 0.09s → 0.12s |
| `preview/ui-preview.html` | IME 提示、切换设备分组（Windows 时序）、断开弹窗复刻、元素清单 29/30 项 |
| `preview/shot-3-settings.png` / `shot-4-keyboard.png` / `shot-5-keyboard-symbols.png` | 重新生成 |
| `README.md` | 新增本节与第二十九节，并随本轮反馈修订 |

## 三十一、硬件桥（ESP32）：让 Windows / Android 真正连上（本轮新增）

### 背景：为什么需要它

v0.0.17 真机确认两点：

1. **iPad 拼音选词**：BLE 复合键鼠外设上，iPadOS 输入法对数字/空格/方向键选词经常不触发，只有「用下方小触控区移动指针去点候选条」最稳（已在 v0.0.17 改为默认路径）。
2. **Windows 搜不到**：iOS 的 `CBPeripheralManager` 外设**无法设置 GAP Appearance（0x03C2, Mouse）**，而 Windows 等主机的蓝牙发现列表依赖这个字段判定设备类别，因此即使广播了标准 16 位 `0x1812`，Windows 也搜不到或卡在配对。**这是系统级硬限制，纯 iOS 软件无解。**

出路：把「被主机发现」这一步交给 ESP32——它能在广播里设置正确的 GAP Appearance，从而被 Windows / Android 当作标准蓝牙鼠标/键盘。

### 架构

```
iPhone（PocketTrackpad App）
  采集手势 / 键盘  →  组装 12 字节复合 HID 报告
        │  WiFi UDP（连 ESP32 的 PT-Bridge 热点，端口 5000）
        ▼
ESP32-C3（本仓库 esp32/ 固件）
  收到 12 字节  →  以标准 BLE HID（Appearance=0x03C2）notify 给主机
        │  BLE HID over GATT
        ▼
Windows / Android（标准蓝牙鼠标 + 键盘）
```

关键点：**iPhone 端那 12 字节复合报告的布局，与 ESP32 端 HID 描述符逐字节对应**（都源自 `HIDSpec.compositeReportMap`：鼠标 4 字节 + 键盘 8 字节）。App 里手势、键盘、三指上滑、粘滞修饰键等逻辑**完全不用改**，只是 `flush()` 在桥模式下改走 UDP 而不是本地 BLE。

协议（见 `esp32/src/main.cpp` 与 `BridgeTransport.swift`）：

- iPhone 周期发送 2 字节 hello `[0x50,0x54]`（"PT"），ESP32 回 `[0x54,0x50]`（"TP"）作为「已连接」确认。
- 12 字节报告直接原样转发。

### 用法

1. 烧录固件：本地 `pio run -d esp32 -t upload`，或到 GitHub Actions 的 `Build ESP32 firmware` 下载 `firmware.bin` 用 esptool 烧录（波特率 921600）。
2. ESP32 启动后发出名为 **`PT-Bridge`** 的开放 WiFi 热点（无密码）。
3. iPhone 在「设置 → 无线局域网」连上 `PT-Bridge`。
4. App 设置里打开「**启用硬件桥（ESP32）**」（会停掉本机 BLE 广播）。
5. 右上角按钮变为「**连接硬件桥**」，点一下；状态变「已连接硬件桥」后即可像控制 iPad 一样控制 Windows / Android。

### 本轮改动

| 文件 | 改动 |
| --- | --- |
| `PocketTrackpad/BridgeTransport.swift` | 新增：Network.framework UDP 传输层，连接/hello/welcome 状态机，12 字节报告发送 |
| `PocketTrackpad/HIDPeripheral.swift` | 新增 `bridgeMode` / `bridgeActive` / `isLinkActive`；`flush()` 桥模式下改走 UDP；`sendKey` 放行桥模式；新增 `startBridge()` / `disconnectBridge()`；`refreshKeyboardReady` 适配桥模式 |
| `PocketTrackpad/ContentView.swift` | 右上角按钮在桥模式下变为「连接/断开硬件桥」；引导页与设置新增桥模式指引；设置新增「硬件桥（ESP32）」分组 |
| `PocketTrackpad/TrackpadSurface.swift` | 三指上滑提示在桥模式下也显示（Command+H 同样有效） |
| `PocketTrackpad/Info.plist` | 新增 `NSLocalNetworkUsageDescription`（iOS 14+ 局域网 UDP 必需，弹窗需点允许） |
| `esp32/src/main.cpp` | 新增：ESP32-C3 固件，WiFi AP + UDP 服务 + BLE HID 复合设备（Appearance 0x03C2） |
| `esp32/platformio.ini` | 新增：PlatformIO 构建配置（board=esp32-c3-devkitm-1） |
| `.github/workflows/esp32-build.yml` | 新增：ESP32 固件编译并上传 `firmware.bin` 产物 |
| `README.md` | 新增本节 |

### 注意

- **iOS 局域网权限**：首次走桥模式时系统会弹「本地网络」授权，必须点允许，否则 UDP 发不出去（App 内状态会卡在「等待硬件桥应答」）。
- **ESP32 AP 是开放的**：默认无密码，仅用于本地转发，不要把它当长期热点。
- **Windows 配对**：首次连接 Windows 可能弹蓝牙配对提示，配对一次即可；之后即插即用。
- **报告布局必须保持一致**：若以后改了 iOS 端 `compositeReportMap`，ESP32 端 `reportMap[]` 要同步改，否则按键/位移错位。
- 本机（Windows）无 ESP32 工具链，固件**未实机烧录验证**，仅靠 PlatformIO CI 编译通过；iPhone↔ESP32↔Windows 的端到端链路待你拿到开发板后真机确认。
