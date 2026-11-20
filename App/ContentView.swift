import SwiftUI

struct ContentView: View {
    @EnvironmentObject var band: BandManager
    @EnvironmentObject var health: HealthSyncManager
    @State private var showingScanner = false
    @State private var callsEnabled = CallMonitor.shared.enabled
    @State private var missedCalls = CallMonitor.shared.notifyMissed
    @State private var keepAlive = KeepAlive.shared.enabled

    var body: some View {
        NavigationStack {
            List {
                statusSection
                if band.hasSavedBand { actionsSection }
                callsSection
                healthSection
                Section("帮助与调试") {
                    NavigationLink("使用说明") { HelpView() }
                    NavigationLink("协议调试日志") { LogView() }
                    NavigationLink("权限与版本信息") { SettingsInfoView() }
                }
            }
            .navigationTitle("Fit3BridgeFree")
            .sheet(isPresented: $showingScanner) { ScannerView() }
        }
    }

    private var statusSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "applewatch.side.right")
                    .font(.system(size: 36))
                    .foregroundStyle(band.isReady ? .green : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(band.bandName ?? "未连接手环").font(.headline)
                    Text(band.phase.rawValue).font(.subheadline).foregroundStyle(.secondary)
                    if let v = band.softwareVersion {
                        Text("固件 \(v)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let b = band.battery {
                    Label("\(b.percent)%", systemImage: b.charging ? "battery.100.bolt" : batteryIcon(b.percent))
                        .font(.subheadline.monospacedDigit())
                }
            }
            .padding(.vertical, 4)
            if let at = band.lastConnectedAt {
                Text("最近连接：\(at.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !band.lastResult.isEmpty {
                Text(band.lastResult).font(.footnote).foregroundStyle(.secondary)
            }
            Button(band.hasSavedBand ? "选择其他手环" : "查找我的 Galaxy Fit3") {
                showingScanner = true
            }
        }
    }

    private var actionsSection: some View {
        Section("手环") {
            Button("发送测试通知") { band.sendTestNotification() }
                .disabled(!band.isReady)
            Button("测试来电提醒（响铃 10 秒）") { band.sendTestCall() }
                .disabled(!band.isReady)
            NavigationLink("表盘") { WatchFacesView() }
                .disabled(!band.isReady)
            Button("同步时间") { band.syncTime() }
                .disabled(!band.isReady)
            Button("刷新电量") { band.requestBattery() }
                .disabled(!band.isReady)
            Button("手动重新连接") { band.reconnect() }
            Button("忘记手环", role: .destructive) { band.forgetBand() }
        }
    }

    private var callsSection: some View {
        Section {
            Toggle("来电震动提醒", isOn: $callsEnabled)
                .onChange(of: callsEnabled) { _, v in CallMonitor.shared.enabled = v }
            Toggle("未接来电提醒", isOn: $missedCalls)
                .onChange(of: missedCalls) { _, v in CallMonitor.shared.notifyMissed = v }
                .disabled(!callsEnabled)
            Toggle("保持后台运行", isOn: $keepAlive)
                .onChange(of: keepAlive) { _, v in KeepAlive.shared.enabled = v }
        } header: {
            Text("来电")
        } footer: {
            Text("iOS 会在后台暂停应用，因此来电提醒需要开启\"保持后台运行\"才能可靠工作。"
                 + "该选项会播放一段无声音频，耗电略有增加。iOS 不允许第三方应用看到来电人姓名，手环只显示\"来电\"。")
        }
    }

    private var healthSection: some View {
        Section {
            Toggle("健康数据同步", isOn: $health.enabled)
                .onChange(of: health.enabled) { _, on in
                    if on { health.requestAuthorization() }
                }
            if health.enabled {
                if let steps = health.todaySteps {
                    HStack {
                        Label("今日步数", systemImage: "figure.walk")
                        Spacer()
                        Text("\(steps) 步").monospacedDigit()
                    }
                }
                if let hr = health.heartRate {
                    HStack {
                        Label("最近心率", systemImage: "heart.fill")
                            .foregroundStyle(.red)
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text("\(hr) bpm").monospacedDigit()
                            if let at = health.heartRateAt {
                                Text(at.formatted(date: .omitted, time: .shortened))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let sync = health.lastSync {
                    HStack {
                        Label("上次同步", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        Text(sync.formatted(date: .abbreviated, time: .shortened))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Text(health.lastStatus).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("健康")
        } footer: {
            Text("连接手环后自动同步步数与心率到 Apple Health（健康 App）。步数按分钟区间写入，重复数据自动去重。")
        }
    }

    private func batteryIcon(_ p: Int) -> String {
        switch p {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}

struct ScannerView: View {
    @EnvironmentObject var band: BandManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if band.discovered.isEmpty {
                        HStack {
                            ProgressView()
                            Text("正在搜索手环…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(band.discovered) { device in
                        Button {
                            band.choose(device)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.name)
                                    Text(device.alreadyConnected ? "已连接到 iPhone" : "信号 \(device.rssi) dBm")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                    }
                } footer: {
                    Text("连接前请先：在 iPhone 设置 → 蓝牙中，点击手环右侧的 ⓘ 并选择\"忽略此设备\"。"
                         + "然后重置手环（手环上：设置 → 通用 → 重置），使其显示配对界面。若 iOS 询问配对，请接受。")
                }
                Section {
                    Toggle("显示所有蓝牙设备", isOn: $band.showAllDevices)
                        .onChange(of: band.showAllDevices) { _, _ in band.startScan() }
                }
            }
            .navigationTitle("查找手环")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("重新扫描") { band.startScan() } }
            }
            .onAppear { band.startScan() }
            .onDisappear { band.stopScan() }
        }
    }
}

struct WatchFacesView: View {
    @EnvironmentObject var band: BandManager

    var body: some View {
        List {
            Section {
                if band.facesLoading && band.faces.isEmpty {
                    HStack { ProgressView(); Text("加载中…").foregroundStyle(.secondary) }
                }
                ForEach(band.faces) { face in
                    Button {
                        band.selectWatchFace(face)
                    } label: {
                        HStack {
                            Image(systemName: face.current ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(face.current ? .green : .secondary)
                            Text(face.label)
                            Spacer()
                            Text("样式 \(face.sampler)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!face.selectable)
                }
            } footer: {
                Text("只能切换手环上已有的表盘。安装新表盘需要 iOS 应用无法使用的蓝牙模式。")
            }
            if !band.lastResult.isEmpty {
                Text(band.lastResult).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("表盘")
        .refreshable { band.loadWatchFaces() }
        .onAppear { band.loadWatchFaces() }
    }
}

struct LogView: View {
    @EnvironmentObject var log: Logbook

    var body: some View {
        List(log.lines.reversed()) { line in
            VStack(alignment: .leading, spacing: 2) {
                Text(log.format(line)).font(.caption2).foregroundStyle(.secondary)
                Text(line.text).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .listStyle(.plain)
        .navigationTitle("协议调试日志")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ShareLink(item: log.fileURL) { Image(systemName: "square.and.arrow.up") }
                Button("清空") { log.clear() }
            }
        }
    }
}

struct HelpView: View {
    var body: some View {
        List {
            Section("连接手环") {
                Text("1. iPhone 设置 → 蓝牙 → 点击 Galaxy Fit3 旁的 ⓘ → 忽略此设备。\n"
                     + "2. 手环上：设置 → 通用 → 重置，让手环进入配对界面。\n"
                     + "3. 打开本应用 → 查找我的 Galaxy Fit3 → 点选手环，接受配对请求。\n"
                     + "4. 状态变为\"已连接\"后，可发送测试通知与测试来电提醒。")
                    .font(.callout)
            }
            Section("来电提醒测试") {
                Text("请用另一部手机拨打你的 iPhone：\n"
                     + "· 响铃时手环应持续震动；\n"
                     + "· 接听后手环停止震动；\n"
                     + "· 挂断/拒接后手环停止震动并显示未接来电；\n"
                     + "· 对方取消呼叫后手环停止震动。\n"
                     + "注意：来电提醒需要开启\"保持后台运行\"，App 被用户从后台划掉后 iOS 不会唤醒它。")
                    .font(.callout)
            }
            Section("健康数据") {
                Text("首次开启\"健康数据同步\"会请求 Apple Health 权限。连接手环后自动同步今日步数与心率。"
                     + "健康协议按 Samsung 官方插件逆向实现（来自 Fit3-App 开源项目），需真机验证。")
                    .font(.callout)
            }
        }
        .navigationTitle("使用说明")
    }
}

struct SettingsInfoView: View {
    var body: some View {
        List {
            Section("权限说明") {
                row("蓝牙", "连接 Galaxy Fit3 手环（始终需要）")
                row("通话监听 (CallKit)", "识别 iPhone 来电、接听与挂断，触发手环震动（来电提醒需要）")
                row("Apple Health", "写入步数与心率数据（健康同步需要）")
                row("后台音频", "播放无声音频以保持后台运行（\"保持后台运行\"开启时使用）")
            }
            Section("版本") {
                row("应用", "Fit3BridgeFree")
                row("版本", (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                    + " (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
            }
            Section("开源许可") {
                Text("本项目基于 GokulArumugam/Fit3Bridge 开发，蓝牙协议移植自 yuriyurin/Fit3-App。"
                     + "两者均以 GPL-3.0-only 许可证发布，本项目同样采用 GPL-3.0-only。"
                     + "完整的许可证文本见仓库中的 LICENSE 文件。本项目与 Samsung 无关。")
                    .font(.callout)
            }
        }
        .navigationTitle("权限与版本")
    }

    private func row(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.body)
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
