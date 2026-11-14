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
    ├── TrackpadSurface.swift         UIKit 手势识别（单指移动、双指滚动、轻点、长按），支持全屏样式
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
4. iPad 屏幕出现圆形指针即成功；iPhone 上的触控区会**自动切换成全屏**，顶部显示「已连接」。
5. 想断开点顶部小按钮「停止广播」；首次配对若失败，在 iPad 上「忽略此设备」，App 里点「重新广播」后再试一次。
6. 指针速度、滚动速度、自然滚动在**左上角齿轮 → 设置**里调，设置会自动保存。

### iPad 侧推荐设置

| 设置项 | 路径 | 作用 |
| --- | --- | --- |
| 辅助触控（AssistiveTouch） | 设置 → 辅助功能 → 触控 → 辅助触控 | 部分非标准 HID 设备不开启时指针能动但点击无效，遇到点击失灵时打开 |
| 指针速度 | 设置 → 通用 → 触控板与鼠标 | 与 App 内「指针速度」配合调整 |
| 辅助点按（右键） | 设置 → 通用 → 触控板与鼠标 → 辅助点按 | 把右键映射到正确侧 |
| 自然滚动 | 设置 → 通用 → 触控板与鼠标 | 与 App 内开关保持一致，否则方向相反 |

### 手势

| 操作 | 效果 |
| --- | --- |
| 单指滑动 | 移动指针 |
| 单指轻点 | 左键单击 |
| 单指双击 | 左键双击 |
| 单指长按 0.5 秒 | 右键单击 |
| 双指滑动 | 滚轮滚动 |
| 底部「左键 / 右键」按住 | 按键按下 / 抬起，可拖选 |
| 底部「滚轮」上下拖动 | 滚轮滚动，与双指滚动共用倍率和方向设置 |
| 底部「滚轮」双击 | 按下滚轮键（中键 0x04）；单击刻意不动作，避免滚动时误触 |
| 底部「滚轮」单击 | 无动作 |

---

## 六、故障排查

| 症状 | 原因 | 处理 |
| --- | --- | --- |
| 日志出现「HID 服务被系统拒绝」 | 当前 iOS 版本封堵了 128 位 UUID 绕过 | 改用现成 App 或 ESP32 硬件桥方案，见第八节 |
| iPad 和电脑都搜不到 PT-Pad，但 App 显示广播正常 | 广播里放了 128 位完整 UUID，被主机按「自定义未知服务」屏蔽；且 iOS 不允许 App 设置 GAP Appearance | v0.0.3 已改为 16 位广播 UUID；用 nRF Connect 扫描确认；若仍不显示即为系统限制，见第十四节 |
| iPad 蓝牙列表看不到 PT-Pad（偶发） | App 未前台 / 蓝牙未就绪 / 名称过长 | 点「重新广播」；保持前台；确认 iPhone 蓝牙已开启；设备名不要改长 |
| 能配对，但 iPad 不出现指针 | HID 配置未通过 iOS 归类审查 | 把 `HIDSpec.useReportID` 改为 `true` 重新编译配对；确认 Report Map 是纯鼠标；检查 2908 Report Reference |
| 指针能动，点击无效 | iPadOS 对非标准 HID 的按键映射 | 打开辅助触控；检查 `辅助点按` 设置；在 App 日志确认 Report 已被订阅 |
| 指针跳动 / 卡顿 | BLE Notify 队列溢出或事件频率过高 | 降低指针速度；确认 `updateValue` 补发逻辑生效；两台设备靠近 |
| 滚动方向相反 | 自然滚动设置不一致 | 统一 App 内开关与 iPad 系统设置 |
| 锁屏后断开 | iOS 限制后台 BLE 广播 | 保持 App 前台、屏幕常亮（代码已设置 `isIdleTimerDisabled`） |
| macOS 能配对但不收报告 | 社区反馈 macOS 对软件 HID 设备识别不稳定 | 优先在 iPad / Windows 验证；用 Packet Logger 抓包确认订阅行为 |

---

## 七、已知边界与风险

| 风险 | 说明 |
| --- | --- |
| 非公开行为 | 128 位 UUID 绕过不在任何 Apple 文档中，属于实现细节，iOS 大版本更新后必须回归验证 |
| App Store 审核 | 未使用私有 API，全部是公开 CoreBluetooth 接口；但功能定位可能被审查质疑。Bluetouch、Tracepad、AirBoard 已上架，说明不是绝对禁止，但不构成通过保证 |
| 后台限制 | App 必须前台、屏幕常亮；锁屏或切后台后 iOS 会停止 BLE 广播，不能当常驻鼠标用 |
| 手势上限 | 只能发标准 HID 鼠标事件（位移 / 三键 / 滚轮），无法发送 iPadOS 的三指、四指系统手势 |
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
| 连接后触控区全屏 | 以 `hid.subscribers > 0` 判定连接；切换后隐藏状态卡片、日志、诊断与提示，`TrackpadSurface(edgeToEdge: true)` 用 `maxHeight: .infinity` 吃掉顶部栏与底部按键条之间的全部空间，并忽略左右安全区 |
| 全屏样式 | `TrackpadSurface` 新增 `edgeToEdge` 参数：圆角 22 → 0、边框 1 → 0、灰底 → 系统背景色，避免边缘留白 |
| 停止广播放在顶部且变小 | 移到导航栏右侧，`.font(.caption2)` + `.buttonStyle(.bordered)` + `.controlSize(.mini)`；文案随状态在「开始广播 / 停止广播」间切换，左侧显示绿色小圆点与「已连接」 |
| 三个键固定在最下面 | `ButtonBar` 放在外层 `VStack` 最后一个元素，不随引导页 `ScrollView` 滚动，连接前后位置不变；底部背景延伸到 home indicator 安全区 |
| 中键改成滚轮 | `WheelButton` 取代中键：上下拖动发送 `wheel` 事件，单击不动作，避免滚动时误触中键 |
| 双击滚轮 = 按下滚轮键 | 双击（0.32 秒内两次轻点、位移小于 8pt）调用 `hid.click(0x04)`，产生一次中键按下/抬起，并给中等强度触感反馈 |

滚轮键与触控区双指滚动共用 `scrollSensitivity` 和 `naturalScrolling`，方向定义一致，不会出现两种滚动方向相反的情况。单击滚轮刻意不发按键，按钮上用小字标注「拖动滚动 · 双击按下」。

顺带修正了触控区提示文案里一处重复词的笔误（第二项应为「双击左键」）。

**版本兼容性**：设置页和全屏布局用到的 `navigationDestination`、`Form`、`ToolbarItemGroup`、`.background { }` 均支持工程最低部署目标 iOS 16.0。
