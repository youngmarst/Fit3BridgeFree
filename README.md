# Fit3BridgeFree

免费的 iPhone 应用，连接 **Samsung Galaxy Fit3（SM-R390）**。

核心功能：**iPhone 来电时手环立即持续震动，接听 / 挂断 / 拒接 / 对方取消后停止震动**；
附加功能：步数与心率自动同步到 Apple Health。完全免费、无订阅、无账号、无云服务器。

本项目基于 [GokulArumugam/Fit3Bridge](https://github.com/GokulArumugam/Fit3Bridge) 开发，
蓝牙协议（Samsung SAP over BLE GATT 0x1A1A）移植自 [yuriyurin/Fit3-App](https://github.com/yuriyurin/Fit3-App)。
两者均为 **GPL-3.0-only** 许可证，本项目同样以 **GPL-3.0-only** 发布（完整文本见 [LICENSE](LICENSE)）。
本项目与 Samsung 无关，健康数据协议同时参考了 Samsung 官方 Fit3 插件的逆向研究成果（见原项目 docs/PROTOCOL.md）。

## 功能状态

| 功能 | 状态 |
|---|---|
| 蓝牙连接、握手、首次配对设置 | ✅ 原项目已在真机验证（2026-10-17，iPhone 17 + Fit3） |
| 来电持续震动（SAP 服务 3，Samsung call agent） | ✅ 原项目已在真机验证；本项目沿用同一协议代码 |
| 接听 / 挂断 / 拒接 / 取消 → 停止震动 + 未接来电 | ✅ 同上 |
| 断线自动重连、iOS 状态恢复（state restoration） | ✅ 原项目已验证；本项目未改动该逻辑 |
| 电量显示、时间同步 | ✅ 原项目已验证 |
| **步数 / 心率 → Apple Health**（SAP 服务 10） | 🆕 本项目新增，协议经真实抓包向量自测（94 项检查全过），**待真机验证** |
| 中文界面、权限说明、调试日志 | 🆕 本项目新增 |
| 表盘切换、测试通知、快捷指令转发短信 | ✅ 原项目实现（短信转发未真机验证） |
| 安装新表盘 | ❌ 需要蓝牙经典 RFCOMM，iOS 应用无法使用 |
| WhatsApp/微信等第三方应用消息转发 | ❌ iOS 系统限制（无法读取其他应用的通知） |

## 已知 iOS 限制（如实说明）

- **CXCallObserver 只在应用运行时触发**。应用退到后台后 iOS 会暂停它，因此来电提醒需要
  开启「保持后台运行」（播放无声音频，个人侧载可用，App Store 不会接受此做法），耗电略增。
- **用户从后台划掉（强制退出）应用后**，iOS 不会唤醒它，来电提醒失效，直到重新打开应用。
- iOS 不向第三方应用提供来电号码/联系人姓名，手环只显示「来电」。
- 无法从手环拒接 iPhone 的电话（只能让手环停止震动）。
- 应用被系统强制结束后无法保证 100% 恢复；CoreBluetooth 状态恢复可覆盖大部分场景（BLE 断连、
  系统回收内存后重新唤醒），但没有系统能力可以让应用「永久常驻」。

## 安装到 iPhone（免费 Apple ID）

### 方式一：本机 Xcode（推荐，可自动续签）

1. App Store 安装 **Xcode**，打开一次并接受许可。
2. Xcode → Settings → Accounts → **+** → 登录你的免费 Apple ID。
3. 用 Xcode 打开 `Fit3BridgeFree.xcodeproj`。
4. 选中 **Fit3BridgeFree** target → Signing & Capabilities → Team 选你的 Personal Team。
   如果 Bundle ID 提示被占用，在 `project.yml` 中改一个唯一的（例如 `com.你的名字.fit3bridgefree`），
   然后运行 `xcodegen generate` 重新生成工程。
5. iPhone 用数据线连接并点「信任」；手机上打开 设置 → 隐私与安全性 → **开发者模式** → 开启
   （若没有该开关：先用数据线连着手机打开 Xcode → Open Developer Tool → Device Hub，再强制关闭
   设置应用并重新插线）。
6. 顶部运行目标选择你的 iPhone，按 **▶︎ Run**。
7. 首次启动若提示不受信任：手机 设置 → 通用 → VPN 与设备管理 → 信任你的开发者证书。

免费账号签名 **7 天过期**，过期后重新插线按 ▶︎ 或运行 `./scripts/reinstall.sh` 即可。

### 方式二：云端构建 IPA + SideStore（无需本机 Xcode）

1. GitHub Actions 每次 push 都会构建**未签名**的 `Fit3BridgeFree.ipa` 并发布到 release `latest`
   （见 .github/workflows/build.yml）。
2. iPhone 上安装免费的 **SideStore**（首次需任意电脑配合创建配对文件，见 https://docs.sidestore.io ）。
3. SideStore → My Apps → **+** → 选择下载的 IPA。SideStore 会在手机上用你的免费 Apple ID 签名并自动续签。

## 快速测试（不安装也能验证协议）

原项目的 Web Bluetooth 测试页保留在 `web/` 目录：在 iPhone 免费的 **Bluefy** 浏览器中打开
（本地起服务或部署到任意静态托管），即可前台测试连接、通知与来电响铃。

## 验证步骤（需真机）

1. **来电震动**：用另一部手机拨打 iPhone —— 手环应持续震动。
2. **接听**：接听后手环停止震动。
3. **挂断/拒接**：手环停止震动并显示未接来电。
4. **对方取消**：手环停止震动。
5. **前台/后台**：分别在应用在前台与后台（已开「保持后台运行」）时重复 1–4。
6. **断连恢复**：手环离开蓝牙范围再回来，或关闭再打开手环蓝牙，验证自动重连后来电提醒恢复。
7. **健康同步**：戴手环走动 → 打开应用等待同步 → 查看「健康」App 中的步数与心率。

以上任何一项未在真机执行前，均不得视为已验证成功。

## 工程结构

```
Fit3BridgeFree.xcodeproj   由 project.yml 通过 xcodegen 生成
App/                       SwiftUI 应用
  BandManager.swift        CoreBluetooth 中央 + SAP 会话（握手/设置/重连/状态恢复）
  CallMonitor.swift        CXCallObserver → 手环响铃（SAP 服务 3）
  HealthSyncManager.swift  🆕 健康会话 + HealthKit 写入（步数/心率，去重）
  KeepAlive.swift          可选的后台保活（静音音频）
  SendToBandIntent.swift   快捷指令「发送到手环」
  ContentView.swift        中文界面
Fit3Kit/                   纯协议代码（无 CoreBluetooth，可在 macOS 上测试）
  Fit3Health.swift         🆕 健康协议移植（来自 Fit3-App，GPL-3.0）
  SapCodec / SAMessage / CallCodec / NotificationCodec / SetupCodecs / WatchFaceCodec
  Sources/Fit3KitChecks/   `swift run Fit3KitChecks` —— 94 项协议自测（真实抓包向量）
docs/PROTOCOL.md           协议参考（GATT、SAP、各服务消息、来源）
docs/STATUS.md             原项目进度与已验证事项
web/                       Web Bluetooth 测试页（Bluefy 用）
scripts/reinstall.sh       7 天续签：构建 + 签名 + 安装 + 启动
```

## 协议自测

```bash
cd Fit3Kit && swift run Fit3KitChecks    # 期望输出: 94 passed, 0 failed
```

向量来自 Fit3-App 的单元测试与真实 AZA3 固件抓包，覆盖：SAP 分帧/CRC/分片、OOBE、电量、
通知、通话、表盘、以及新增的健康协议（GM capability、wearable capability、SYNC_DATA 确认、
步数区间解析与去重、大块传输重组、心率记录解析）。

## 修改与再分发

按 GPL-3.0 要求：分发本应用（或其修改版）时必须同时提供完整源码并保留 GPL-3.0 许可证与
原作者版权声明。请勿移除 LICENSE 文件。
