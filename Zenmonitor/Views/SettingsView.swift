//
//  SettingsView.swift
//  zenmux-monitor
//
//  设置面板视图
//  功能：配置各监控源、刷新间隔、通用设置
//

import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var refreshInterval: TimeInterval
    @State private var launchAtLogin: Bool
    /// 源卡片排列顺序（sourceID）：直接拖拽卡片调整，持久化到 menu_source_order
    @State private var orderedSourceIDs: [String]
    /// 当前正在被拖动的源 ID
    @State private var draggingSourceID: String?

    private let settings = SettingsManager.shared
    private let registry = SourceRegistry.shared

    init() {
        _refreshInterval = State(initialValue: SettingsManager.shared.refreshInterval)
        _launchAtLogin = State(initialValue: SettingsManager.shared.launchAtLogin)
        _orderedSourceIDs = State(initialValue: SettingsManager.shared.menuOrder(
            registrySources: SourceRegistry.shared.sources.map { $0.sourceID }))
    }

    var body: some View {
        ZStack {
            // 不透明窗口背景（替代全窗口磨砂）：Material 实时模糊在保存徽章出现/消失的
            // 动画期间会逐帧重算，是内存尖峰的主要来源（实测 93 万次瞬态分配）
            Rectangle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        // 源列表：按用户自定义顺序排列，直接拖拽卡片即可排序；
                        // 结果持久化到 menu_source_order，下拉面板下次打开即生效，
                        // 无需单独的排序模块
                        ForEach(orderedSourceIDs, id: \.self) { id in
                            if let source = registry.source(withID: id) {
                                sourceCard(for: source)
                                    .onDrag {
                                        draggingSourceID = id
                                        return NSItemProvider(object: id as NSString)
                                    }
                                    .onDrop(of: [.text], delegate: SourceCardDropDelegate(
                                        targetID: id,
                                        orderedIDs: $orderedSourceIDs,
                                        draggingID: $draggingSourceID,
                                        onReorder: { settings.setMenuOrder($0) }
                                    ))
                            }
                        }

                        // 通用设置（刷新间隔 + 开机启动，合并为一张卡片）
                        generalSection
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
                }

                Divider()

                bottomBar
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 420, minHeight: 280)
    }

    // MARK: - 源卡片（根据 sourceID 分发到专属配置视图）

    @ViewBuilder
    private func sourceCard(for source: any MonitoredSource) -> some View {
        switch source.sourceID {
        case "zenmux":
            ZenmuxSourceCard()
        case "deepseek":
            DeepSeekSourceCard()
        case "kimi":
            KimiSourceCard()
        case "zhipu":
            ZhipuSourceCard()
        case "ark":
            VolcanoArkSourceCard()
        case "tavily":
            TavilySourceCard()
        case "opencode":
            OpenCodeSourceCard()
        default:
            // 未来新源的通用卡片
            GenericSourceCard(source: source)
        }
    }

    // MARK: - 通用设置（刷新间隔 + 开机启动合并一张卡，Divider 分隔）

    private var generalSection: some View {
        VStack(spacing: 10) {
            HStack {
                Text("自动刷新间隔")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(SettingsPalette.primaryText)
                Spacer()
                Picker("", selection: $refreshInterval) {
                    Text("30s").tag(30.0)
                    Text("1m").tag(60.0)
                    Text("2m").tag(120.0)
                    Text("5m").tag(300.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .onChange(of: refreshInterval) { _, newValue in
                    settings.refreshInterval = newValue
                    // 重启全局自动刷新定时器，新间隔立即生效（四源统一跟随）
                    registry.startAutoRefresh()
                }
            }

            Divider()
                .opacity(0.5)

            HStack {
                Text("登录时自动启动")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(SettingsPalette.primaryText)
                Spacer()
                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: launchAtLogin) { _, newValue in
                        settings.launchAtLogin = newValue
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            // 注册/注销失败时开关状态会在下次打开设置时回读真实值，
                            // 不弹窗打扰；错误原因可在控制台日志查看
                        }
                    }
            }
        }
        .settingsCard()
    }

    // MARK: - 底部栏

    /// 检查更新进行中状态（防重复点击 + 按钮加载态）
    @State private var isCheckingUpdate = false

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Text("设置会自动保存，本窗口可随时关闭。")
                .font(.subheadline)
                .foregroundStyle(SettingsPalette.secondaryText)

            Spacer()

            Button {
                checkForUpdates()
            } label: {
                if isCheckingUpdate {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("检查更新", systemImage: "arrow.down.circle")
                }
            }
            .buttonStyle(SettingsProminentButtonStyle())
            .disabled(isCheckingUpdate)

            Button("完成") {
                NSApp.keyWindow?.close()
            }
            .buttonStyle(SettingsProminentButtonStyle())
        }
    }

    // MARK: - 检查更新（GitHub Releases 最新版本对比）

    /// 拉取 GitHub 最新 Release 与当前应用版本对比：
    /// 有新版本 → 弹窗提供「前往下载」；已最新 → 提示；网络异常 → 友好提示。
    private func checkForUpdates() {
        guard !isCheckingUpdate else { return }
        isCheckingUpdate = true
        Task {
            defer { isCheckingUpdate = false }
            do {
                let apiURL = URL(string: "https://api.github.com/repos/jianxing-chen/zenmonitor/releases/latest")!
                var request = URLRequest(url: apiURL)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 10
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    throw URLError(.cannotParseResponse)
                }
                let releaseURL = (json["html_url"] as? String)
                    ?? "https://github.com/jianxing-chen/zenmonitor/releases/latest"
                let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                if Self.isReleaseNewer(tag, than: current) {
                    showUpdateAvailableAlert(tag: tag, releaseURL: releaseURL)
                } else {
                    showInfoAlert(title: "当前已是最新版本",
                                  info: "Zenmonitor 已是最新版本（当前 \(current)）。")
                }
            } catch {
                showInfoAlert(title: "网络异常", info: "检查更新失败，请稍后重试。")
            }
        }
    }

    /// 版本比较：去除 v 前缀后逐段数字对比（如 v2.8 > 2.0）
    private static func isReleaseNewer(_ tag: String, than current: String) -> Bool {
        func parse(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(separator: ".")
                .compactMap { Int($0) }
        }
        let a = parse(tag), b = parse(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// 新版本可用弹窗：提供「前往下载」跳转 Release 页
    private func showUpdateAvailableAlert(tag: String, releaseURL: String) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(tag)"
        alert.informativeText = "有新的版本可用，建议前往 GitHub Releases 下载。"
        alert.addButton(withTitle: "前往下载")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: releaseURL) {
            NSWorkspace.shared.open(url)
        }
    }

    /// 普通信息弹窗（已是最新 / 网络异常）
    private func showInfoAlert(title: String, info: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

// MARK: - Zenmux 源配置卡片

struct ZenmuxSourceCard: View {
    @State private var apiKeyInput: String
    @State private var apiDomain: ZenmuxAPIDomain
    @State private var showKeySaved = false

    private let settings = SettingsManager.shared
    private let apiService = ZenmuxAPIService.shared

    init() {
        _apiKeyInput = State(initialValue: SettingsManager.shared.apiKey ?? "")
        _apiDomain = State(initialValue: SettingsManager.shared.apiDomain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 头部：Logo + 标题 + 域名选择（透明底 Logo，与下拉面板共用 PanelLogo）
            HStack(spacing: 10) {
                if let logo = PanelLogo.zenmux {
                    Image(nsImage: logo)
                        .resizable()
                        .frame(width: 26, height: 26)
                }
                Text("Zenmux")
                    .font(.headline)
                    .foregroundStyle(SettingsPalette.primaryText)

                Spacer(minLength: 8)

                Picker("", selection: $apiDomain) {
                    Text("zenmux.ai").tag(ZenmuxAPIDomain.zenmuxAI)
                    Text("zenmux.dev").tag(ZenmuxAPIDomain.zenmuxDEV)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .onChange(of: apiDomain) { _, newValue in
                    settings.apiDomain = newValue
                    apiService.settingsDidChange(forceFetch: true)
                }

                RefreshMultiplierPicker(sourceID: "zenmux")
            }

            // API Key 输入
            HStack(spacing: 10) {
                SecureField("请输入 Zenmux Management API Key", text: $apiKeyInput)
                    .keyFieldStyle()

                Button {
                    persistAPIKey(forceFetch: true)
                    flashSavedBadge()
                } label: {
                    // 输入框为空时按钮变为「删除」，允许清除已保存的 Key
                    if keyInputIsEmpty {
                        Label("删除", systemImage: "trash")
                    } else {
                        Label("保存", systemImage: "arrow.down.circle.fill")
                    }
                }
                .buttonStyle(SettingsProminentButtonStyle())
            }

            // 底部：菜单栏开关 + 控制台链接 + 状态徽章（含保存瞬时反馈）
            SourceCardFooter(
                sourceID: "zenmux",
                consoleURL: apiDomain.consoleURL,
                consoleHint: "前往 Zenmux 控制台创建 Key",
                badge: feedbackOrStatusBadge
            )
        }
        .settingsCard()
        // 保存反馈直切无动画：徽章过渡动画会触发整卡逐帧重算（内存尖峰来源之一）
    }

    /// 输入框去空白后是否为空（空 = 删除 Key 操作）
    private var keyInputIsEmpty: Bool {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func persistAPIKey(forceFetch: Bool) {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue = trimmed.isEmpty ? nil : trimmed
        let currentValue = settings.apiKey
        guard currentValue != newValue else { return }
        settings.apiKey = newValue
        apiService.settingsDidChange(forceFetch: forceFetch)
    }

    /// 保存/删除后短暂闪烁徽章反馈，随后恢复连接状态显示
    private func flashSavedBadge() {
        showKeySaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showKeySaved = false
        }
    }

    /// 状态徽章：保存瞬间显示「已保存/已删除」，1.5 秒后恢复连接状态，
    /// 反馈落在底部常驻徽章上，不再挤占输入框行宽度
    private var feedbackOrStatusBadge: StatusBadge {
        if showKeySaved {
            return StatusBadge(title: keyInputIsEmpty ? "已删除" : "已保存",
                               icon: "checkmark.circle.fill", tint: .green)
        }
        let configured = settings.apiKey?.isEmpty == false
        return StatusBadge(title: configured ? "已连接" : "未配置",
                           icon: "bolt.fill", tint: configured ? .green : .secondary)
    }
}

// MARK: - DeepSeek 源配置卡片

struct DeepSeekSourceCard: View {
    @State private var apiKeyInput: String
    @State private var showKeySaved = false

    private let settings = SettingsManager.shared

    init() {
        _apiKeyInput = State(initialValue: SettingsManager.shared.deepseekAPIKey ?? "")
    }

    /// 输入框去空白后是否为空（空 = 删除 Key 操作）
    private var keyInputIsEmpty: Bool {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 头部：Logo + 标题
            HStack(spacing: 10) {
                Image("DeepSeekLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                Text("DeepSeek")
                    .font(.headline)
                    .foregroundStyle(SettingsPalette.primaryText)

                Spacer(minLength: 8)

                RefreshMultiplierPicker(sourceID: "deepseek")
            }

            // API Key 输入
            HStack(spacing: 10) {
                SecureField("请输入 DeepSeek API Key（sk-...）", text: $apiKeyInput)
                    .keyFieldStyle()

                Button {
                    let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        // 删除 Key：置空配置并立即清空余额数据、缓存与用量采样历史
                        settings.deepseekAPIKey = nil
                        DeepSeekAPIService.shared.invalidateForMissingKey()
                    } else {
                        settings.deepseekAPIKey = trimmed
                        UserDefaults.standard.removeObject(forKey: "deepseek_cached_balance")
                        UserDefaults.standard.removeObject(forKey: "deepseek_cached_updated")
                    }
                    flashSavedBadge()
                } label: {
                    // 输入框为空时按钮变为「删除」，允许清除已保存的 Key
                    if keyInputIsEmpty {
                        Label("删除", systemImage: "trash")
                    } else {
                        Label("保存", systemImage: "arrow.down.circle.fill")
                    }
                }
                .buttonStyle(SettingsProminentButtonStyle())
            }

            // 底部：菜单栏开关 + 控制台链接 + 状态徽章（含保存瞬时反馈）
            SourceCardFooter(
                sourceID: "deepseek",
                consoleURL: URL(string: "https://platform.deepseek.com/api_keys")!,
                consoleHint: "前往 DeepSeek 控制台创建 Key",
                badge: feedbackOrStatusBadge
            )
        }
        .settingsCard()
        // 保存反馈直切无动画：徽章过渡动画会触发整卡逐帧重算（内存尖峰来源之一）
    }

    /// 保存/删除后短暂闪烁徽章反馈，随后恢复配置状态显示
    private func flashSavedBadge() {
        showKeySaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showKeySaved = false
        }
    }

    private var feedbackOrStatusBadge: StatusBadge {
        if showKeySaved {
            return StatusBadge(title: keyInputIsEmpty ? "已删除" : "已保存",
                               icon: "checkmark.circle.fill", tint: .green)
        }
        let configured = settings.deepseekAPIKey?.isEmpty == false
        return StatusBadge(title: configured ? "已配置" : "未配置",
                           icon: "bolt.fill", tint: configured ? .green : .secondary)
    }
}

// MARK: - Kimi 源配置卡片

struct KimiSourceCard: View {
    @State private var apiKeyInput: String
    @State private var showKeySaved = false

    private let settings = SettingsManager.shared

    init() {
        _apiKeyInput = State(initialValue: SettingsManager.shared.kimiAPIKey ?? "")
    }

    /// 输入框去空白后是否为空（空 = 删除 Key 操作）
    private var keyInputIsEmpty: Bool {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 头部：Logo + 标题
            HStack(spacing: 10) {
                Image("KimiLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                Text("Kimi Code")
                    .font(.headline)
                    .foregroundStyle(SettingsPalette.primaryText)

                Spacer(minLength: 8)

                RefreshMultiplierPicker(sourceID: "kimi")
            }

            // API Key 输入
            HStack(spacing: 10) {
                SecureField("请输入 Kimi Code API Key（sk-kimi-...）", text: $apiKeyInput)
                    .keyFieldStyle()

                Button {
                    let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        // 删除 Key：置空配置并立即清空配额数据与缓存
                        settings.kimiAPIKey = nil
                        KimiCodeAPIService.shared.invalidateForMissingKey()
                    } else {
                        settings.kimiAPIKey = trimmed
                        UserDefaults.standard.removeObject(forKey: "kimi_cached_usages")
                        UserDefaults.standard.removeObject(forKey: "kimi_cached_updated")
                        // 保存后立即拉取一次，便于下次打开菜单即有数据
                        Task { await KimiCodeAPIService.shared.refresh() }
                    }
                    flashSavedBadge()
                } label: {
                    // 输入框为空时按钮变为「删除」，允许清除已保存的 Key
                    if keyInputIsEmpty {
                        Label("删除", systemImage: "trash")
                    } else {
                        Label("保存", systemImage: "arrow.down.circle.fill")
                    }
                }
                .buttonStyle(SettingsProminentButtonStyle())
            }

            // 底部：菜单栏开关 + 控制台链接 + 状态徽章（含保存瞬时反馈）
            SourceCardFooter(
                sourceID: "kimi",
                consoleURL: URL(string: "https://www.kimi.com/code/console")!,
                consoleHint: "前往 Kimi Code 控制台创建 Key",
                badge: feedbackOrStatusBadge
            )
        }
        .settingsCard()
        // 保存反馈直切无动画：徽章过渡动画会触发整卡逐帧重算（内存尖峰来源之一）
    }

    /// 保存/删除后短暂闪烁徽章反馈，随后恢复配置状态显示
    private func flashSavedBadge() {
        showKeySaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showKeySaved = false
        }
    }

    private var feedbackOrStatusBadge: StatusBadge {
        if showKeySaved {
            return StatusBadge(title: keyInputIsEmpty ? "已删除" : "已保存",
                               icon: "checkmark.circle.fill", tint: .green)
        }
        let configured = settings.kimiAPIKey?.isEmpty == false
        return StatusBadge(title: configured ? "已配置" : "未配置",
                           icon: "bolt.fill", tint: configured ? .green : .secondary)
    }
}

// MARK: - 智谱 GLM 源配置卡片

struct ZhipuSourceCard: View {
    @State private var apiKeyInput: String
    @State private var showKeySaved = false
    /// 平台选择（国内版/国际版）：两平台账号独立、Key 不通用，
    /// 切换后需换用对应平台的 Key
    @State private var region: ZhipuRegion

    private let settings = SettingsManager.shared

    init() {
        _apiKeyInput = State(initialValue: SettingsManager.shared.zhipuAPIKey ?? "")
        _region = State(initialValue: SettingsManager.shared.zhipuRegion)
    }

    /// 输入框去空白后是否为空（空 = 删除 Key 操作）
    private var keyInputIsEmpty: Bool {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 头部：Logo + 标题 + 平台选择（与 Zenmux 域名选择器同布局）
            HStack(spacing: 10) {
                Image("ZhipuLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                Text("智谱 GLM")
                    .font(.headline)
                    .foregroundStyle(SettingsPalette.primaryText)

                Spacer(minLength: 8)

                // 平台切换（与 Zenmux 域名切换同模式）：端点路径两平台一致，
                // 仅 host 不同；切换后旧平台缓存失效，已配 Key 时立即重新拉取
                Picker("", selection: $region) {
                    Text("国内版").tag(ZhipuRegion.domestic)
                    Text("国际版 (z.ai)").tag(ZhipuRegion.international)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .onChange(of: region) { _, newValue in
                    settings.zhipuRegion = newValue
                    // 旧平台的缓存语义不同，立即清除避免启动时短暂显示错误数据
                    UserDefaults.standard.removeObject(forKey: "zhipu_cached_usages")
                    UserDefaults.standard.removeObject(forKey: "zhipu_cached_updated")
                    if settings.zhipuAPIKey?.isEmpty == false {
                        Task { await ZhipuAPIService.shared.refresh() }
                    } else {
                        ZhipuAPIService.shared.invalidateForMissingKey()
                    }
                }

                RefreshMultiplierPicker(sourceID: "zhipu")
            }

            // API Key 输入
            HStack(spacing: 10) {
                SecureField("请输入智谱 Coding Plan API Key", text: $apiKeyInput)
                    .keyFieldStyle()

                Button {
                    let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        // 删除 Key：置空配置并立即清空配额数据与缓存
                        settings.zhipuAPIKey = nil
                        ZhipuAPIService.shared.invalidateForMissingKey()
                    } else {
                        settings.zhipuAPIKey = trimmed
                        UserDefaults.standard.removeObject(forKey: "zhipu_cached_usages")
                        UserDefaults.standard.removeObject(forKey: "zhipu_cached_updated")
                        // 首次配置 Key 时自动开启状态栏显示（与火山方舟一致：
                        // 配置即意味着期望看到监控项）
                        if !settings.statusBarEnabled(for: "zhipu") {
                            settings.setStatusBarEnabled(true, for: "zhipu")
                            NotificationCenter.default.post(name: .statusBarSettingsChanged, object: nil)
                        }
                        // 保存后立即拉取一次，便于下次打开菜单即有数据
                        Task { await ZhipuAPIService.shared.refresh() }
                    }
                    flashSavedBadge()
                } label: {
                    // 输入框为空时按钮变为「删除」，允许清除已保存的 Key
                    if keyInputIsEmpty {
                        Label("删除", systemImage: "trash")
                    } else {
                        Label("保存", systemImage: "arrow.down.circle.fill")
                    }
                }
                .buttonStyle(SettingsProminentButtonStyle())
            }

            // 底部：菜单栏开关 + 控制台链接 + 状态徽章（含保存瞬时反馈）
            SourceCardFooter(
                sourceID: "zhipu",
                consoleURL: region.consoleURL,
                consoleHint: region == .domestic
                    ? "前往智谱开放平台创建 Key"
                    : "前往 Z.ai 控制台创建 Key",
                badge: feedbackOrStatusBadge
            )
        }
        .settingsCard()
        // 保存反馈直切无动画：徽章过渡动画会触发整卡逐帧重算（内存尖峰来源之一）
    }

    /// 保存/删除后短暂闪烁徽章反馈，随后恢复配置状态显示
    private func flashSavedBadge() {
        showKeySaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showKeySaved = false
        }
    }

    private var feedbackOrStatusBadge: StatusBadge {
        if showKeySaved {
            return StatusBadge(title: keyInputIsEmpty ? "已删除" : "已保存",
                               icon: "checkmark.circle.fill", tint: .green)
        }
        let configured = settings.zhipuAPIKey?.isEmpty == false
        return StatusBadge(title: configured ? "已配置" : "未配置",
                           icon: "bolt.fill", tint: configured ? .green : .secondary)
    }
}

// MARK: - 火山方舟源配置卡片

struct VolcanoArkSourceCard: View {
    @State private var accessKeyInput: String
    @State private var secretKeyInput: String
    @State private var showKeySaved = false

    private let settings = SettingsManager.shared

    init() {
        _accessKeyInput = State(initialValue: SettingsManager.shared.arkAccessKey ?? "")
        _secretKeyInput = State(initialValue: SettingsManager.shared.arkSecretKey ?? "")
    }

    /// 两个输入框去空白后是否均为空（空 = 删除凭据操作）
    private var keyInputIsEmpty: Bool {
        accessKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && secretKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 保存条件：两个输入框均非空
    private var canSave: Bool {
        !accessKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 凭据是否已配置（任一缺失即未配置）
    private var isConfigured: Bool {
        settings.arkAccessKey?.isEmpty == false && settings.arkSecretKey?.isEmpty == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 头部：Logo + 标题
            HStack(spacing: 10) {
                Image("VolcanoArkLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                Text("火山方舟")
                    .font(.headline)
                    .foregroundStyle(SettingsPalette.primaryText)

                Spacer(minLength: 8)

                RefreshMultiplierPicker(sourceID: "ark")
            }

            // AccessKey 输入
            SecureField("请输入 AccessKey（AK）", text: $accessKeyInput)
                .keyFieldStyle()

            // SecretKey 输入 + 保存/删除按钮
            HStack(spacing: 10) {
                SecureField("请输入 SecretKey（SK）", text: $secretKeyInput)
                    .keyFieldStyle()

                Button {
                    if keyInputIsEmpty {
                        // 删除凭据：置空配置并立即清空配额数据与缓存
                        settings.arkAccessKey = nil
                        settings.arkSecretKey = nil
                        ArkAPIService.shared.invalidateForMissingCredentials()
                        flashSavedBadge()
                    } else if canSave {
                        settings.arkAccessKey = accessKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        settings.arkSecretKey = secretKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        UserDefaults.standard.removeObject(forKey: "ark_cached_usages")
                        UserDefaults.standard.removeObject(forKey: "ark_cached_updated")
                        // 首次配置凭据时自动开启状态栏显示（与其他源需手动开启的预期不同，
                        // AK/SK 配置门槛更高，配置即意味着期望看到监控项）
                        if !settings.statusBarEnabled(for: "ark") {
                            settings.setStatusBarEnabled(true, for: "ark")
                            NotificationCenter.default.post(name: .statusBarSettingsChanged, object: nil)
                        }
                        // 保存后立即拉取一次，便于下次打开菜单即有数据
                        Task { await ArkAPIService.shared.refresh() }
                        flashSavedBadge()
                    }
                    // 只填了一个输入框时不保存（按钮处于禁用态）
                } label: {
                    // 输入框均为空时按钮变为「删除」，允许清除已保存的凭据
                    if keyInputIsEmpty {
                        Label("删除", systemImage: "trash")
                    } else {
                        Label("保存", systemImage: "arrow.down.circle.fill")
                    }
                }
                .buttonStyle(SettingsProminentButtonStyle())
                .disabled(!keyInputIsEmpty && !canSave)
            }

            // 底部：菜单栏开关 + 密钥管理链接 + 状态徽章
            SourceCardFooter(
                sourceID: "ark",
                consoleURL: URL(string: "https://console.volcengine.com/iam/keymanage")!,
                consoleHint: "前往火山引擎 IAM 创建 AccessKey",
                badge: feedbackOrStatusBadge
            )
        }
        .settingsCard()
        // 保存反馈直切无动画：徽章过渡动画会触发整卡逐帧重算（内存尖峰来源之一）
    }

    /// 保存/删除后短暂闪烁徽章反馈，随后恢复配置状态显示
    private func flashSavedBadge() {
        showKeySaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showKeySaved = false
        }
    }

    private var feedbackOrStatusBadge: StatusBadge {
        if showKeySaved {
            return StatusBadge(title: keyInputIsEmpty ? "已删除" : "已保存",
                               icon: "checkmark.circle.fill", tint: .green)
        }
        return StatusBadge(title: isConfigured ? "已配置" : "未配置",
                           icon: "bolt.fill", tint: isConfigured ? .green : .secondary)
    }
}

// MARK: - 通用源配置卡片（未来新源）

struct GenericSourceCard: View {
    let source: any MonitoredSource

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let logoName = source.logoImageName {
                    Image(logoName)
                        .resizable()
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "app.fill")
                        .resizable()
                        .frame(width: 28, height: 28)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.displayName)
                        .font(.headline)
                        .foregroundStyle(SettingsPalette.primaryText)
                    Text("该源暂无专属配置界面")
                        .font(.subheadline)
                        .foregroundStyle(SettingsPalette.secondaryText)
                }
            }
        }
        .settingsCard()
    }
}

// MARK: - 源卡片拖拽排序

/// 源卡片拖拽排序代理：拖动卡片悬停到目标位置时即换位（无需等松手），
/// 每次换位都持久化到 menu_source_order，下拉面板下次打开即按新顺序渲染
private struct SourceCardDropDelegate: DropDelegate {
    let targetID: String
    @Binding var orderedIDs: [String]
    @Binding var draggingID: String?
    let onReorder: ([String]) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingID, dragging != targetID,
              let from = orderedIDs.firstIndex(of: dragging),
              let to = orderedIDs.firstIndex(of: targetID) else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            orderedIDs.move(fromOffsets: IndexSet(integer: from),
                            toOffset: to > from ? to + 1 : to)
        }
        onReorder(orderedIDs)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}

// MARK: - 共享组件

/// 源卡片底部行：菜单栏显示开关（左）+ 控制台图标链接 + 状态徽章（右）。
/// 把原先「Toggle 独占一行 + 链接/徽章一行」的两行结构压缩为一行。
private struct SourceCardFooter: View {
    let sourceID: String
    let consoleURL: URL
    let consoleHint: String
    let badge: StatusBadge

    var body: some View {
        HStack(spacing: 8) {
            StatusBarToggle(sourceID: sourceID)

            Spacer()

            // 控制台链接收窄为图标，完整文案移入悬浮提示
            Link(destination: consoleURL) {
                Image(systemName: "safari")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SettingsPalette.secondaryText)
            }
            .help(consoleHint)

            badge
        }
    }
}

/// 状态徽章（胶囊）：源连接状态与保存瞬时反馈共用
private struct StatusBadge: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(SettingsPalette.fill)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(SettingsPalette.border, lineWidth: 1)
        )
    }
}

/// 状态栏显示开关：持久化到 UserDefaults，变更后通知 AppDelegate 重建菜单栏项
private struct StatusBarToggle: View {
    let sourceID: String
    @State private var isOn: Bool

    private let settings = SettingsManager.shared

    init(sourceID: String) {
        self.sourceID = sourceID
        _isOn = State(initialValue: SettingsManager.shared.statusBarEnabled(for: sourceID))
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Text("在菜单栏显示")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(SettingsPalette.primaryText)
        }
        .toggleStyle(.switch)
        .onChange(of: isOn) { _, newValue in
            settings.setStatusBarEnabled(newValue, for: sourceID)
            NotificationCenter.default.post(name: .statusBarSettingsChanged, object: nil)
        }
    }
}

// MARK: - Tavily 源配置卡片

struct TavilySourceCard: View {
    @State private var apiKeyInput: String
    @State private var showKeySaved = false

    private let settings = SettingsManager.shared

    init() {
        _apiKeyInput = State(initialValue: SettingsManager.shared.tavilyAPIKey ?? "")
    }

    /// 输入框去空白后是否为空（空 = 删除 Key 操作）
    private var keyInputIsEmpty: Bool {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 头部：Logo + 标题 + 刷新倍率选择器
            HStack(spacing: 10) {
                Image("TavilyLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                Text("Tavily")
                    .font(.headline)
                    .foregroundStyle(SettingsPalette.primaryText)

                Spacer(minLength: 8)

                RefreshMultiplierPicker(sourceID: "tavily")
            }

            // API Key 输入
            HStack(spacing: 10) {
                SecureField("请输入 Tavily API Key（tvly-...）", text: $apiKeyInput)
                    .keyFieldStyle()

                Button {
                    let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        // 删除 Key：置空配置并立即清空用量数据与缓存（同时重置节流）
                        settings.tavilyAPIKey = nil
                        TavilyAPIService.shared.invalidateForMissingKey()
                    } else {
                        settings.tavilyAPIKey = trimmed
                        // 更换 Key 后旧数据/节流状态不再适用，先清空再立即拉取新数据
                        TavilyAPIService.shared.invalidateForMissingKey()
                        Task { await TavilyAPIService.shared.refresh(force: true) }
                    }
                    flashSavedBadge()
                } label: {
                    // 输入框为空时按钮变为「删除」，允许清除已保存的 Key
                    if keyInputIsEmpty {
                        Label("删除", systemImage: "trash")
                    } else {
                        Label("保存", systemImage: "arrow.down.circle.fill")
                    }
                }
                .buttonStyle(SettingsProminentButtonStyle())
            }

            // 底部：菜单栏开关 + 控制台链接 + 状态徽章（含保存瞬时反馈）
            SourceCardFooter(
                sourceID: "tavily",
                consoleURL: URL(string: "https://app.tavily.com/home")!,
                consoleHint: "前往 Tavily 控制台创建 Key",
                badge: feedbackOrStatusBadge
            )
        }
        .settingsCard()
        // 保存反馈直切无动画：徽章过渡动画会触发整卡逐帧重算（内存尖峰来源之一）
    }

    /// 保存/删除后短暂闪烁徽章反馈，随后恢复配置状态显示
    private func flashSavedBadge() {
        showKeySaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showKeySaved = false
        }
    }

    private var feedbackOrStatusBadge: StatusBadge {
        if showKeySaved {
            return StatusBadge(title: keyInputIsEmpty ? "已删除" : "已保存",
                               icon: "checkmark.circle.fill", tint: .green)
        }
        let configured = settings.tavilyAPIKey?.isEmpty == false
        return StatusBadge(title: configured ? "已配置" : "未配置",
                           icon: "bolt.fill", tint: configured ? .green : .secondary)
    }
}

// MARK: - OpenCode 源配置卡片

struct OpenCodeSourceCard: View {
    @State private var apiKeyInput: String
    @State private var showKeySaved = false

    private let settings = SettingsManager.shared

    init() {
        _apiKeyInput = State(initialValue: SettingsManager.shared.opencodeAPIKey ?? "")
    }

    /// 输入框去空白后是否为空（空 = 删除 Key 操作）
    private var keyInputIsEmpty: Bool {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 头部：Logo + 标题 + 刷新倍率选择器（纵向构图，尺寸与 Zenmux 一致）
            HStack(spacing: 10) {
                Image("OpenCodeLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                Text("OpenCode Go")
                    .font(.headline)
                    .foregroundStyle(SettingsPalette.primaryText)

                Spacer(minLength: 8)

                RefreshMultiplierPicker(sourceID: "opencode")
            }

            // API Key 输入
            HStack(spacing: 10) {
                SecureField("请输入 OpenCode Go API Key", text: $apiKeyInput)
                    .keyFieldStyle()

                Button {
                    let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        // 删除 Key：置空配置并立即清空用量数据与缓存（同时重置节流）
                        settings.opencodeAPIKey = nil
                        OpenCodeAPIService.shared.invalidateForMissingKey()
                    } else {
                        settings.opencodeAPIKey = trimmed
                        // 更换 Key 后旧数据不再适用，先清空再立即拉取新数据；
                        // 首次配置自动开启状态栏显示（与其他源一致）
                        OpenCodeAPIService.shared.invalidateForMissingKey()
                        if !settings.statusBarEnabled(for: "opencode") {
                            settings.setStatusBarEnabled(true, for: "opencode")
                            NotificationCenter.default.post(name: .statusBarSettingsChanged, object: nil)
                        }
                        Task { await OpenCodeAPIService.shared.refresh(force: true) }
                    }
                    flashSavedBadge()
                } label: {
                    // 输入框为空时按钮变为「删除」，允许清除已保存的 Key
                    if keyInputIsEmpty {
                        Label("删除", systemImage: "trash")
                    } else {
                        Label("保存", systemImage: "arrow.down.circle.fill")
                    }
                }
                .buttonStyle(SettingsProminentButtonStyle())
            }

            // 底部：菜单栏开关 + 控制台链接 + 状态徽章（含保存瞬时反馈）
            SourceCardFooter(
                sourceID: "opencode",
                consoleURL: URL(string: "https://opencode.ai/auth")!,
                consoleHint: "前往 OpenCode Zen 控制台获取 Key",
                badge: feedbackOrStatusBadge
            )
        }
        .settingsCard()
        // 保存反馈直切无动画：徽章过渡动画会触发整卡逐帧重算（内存尖峰来源之一）
    }

    /// 保存/删除后短暂闪烁徽章反馈，随后恢复配置状态显示
    private func flashSavedBadge() {
        showKeySaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showKeySaved = false
        }
    }

    private var feedbackOrStatusBadge: StatusBadge {
        if showKeySaved {
            return StatusBadge(title: keyInputIsEmpty ? "已删除" : "已保存",
                               icon: "checkmark.circle.fill", tint: .green)
        }
        let configured = settings.opencodeAPIKey?.isEmpty == false
        return StatusBadge(title: configured ? "已配置" : "未配置",
                           icon: "bolt.fill", tint: configured ? .green : .secondary)
    }
}

// MARK: - 每源刷新倍率选择器（全部源卡片头部行共用）

/// 每源自动刷新倍率：实际周期 = 全局间隔 × 倍率（如全局 60s + ×4 = 240s）。
/// 倍率变更下一轮定时器即生效，无需重启。
private struct RefreshMultiplierPicker: View {
    let sourceID: String
    @State private var multiplier: Int

    private let settings = SettingsManager.shared

    init(sourceID: String) {
        self.sourceID = sourceID
        _multiplier = State(initialValue: SettingsManager.shared.refreshMultiplier(for: sourceID))
    }

    var body: some View {
        Picker("", selection: $multiplier) {
            ForEach(SettingsManager.allowedRefreshMultipliers, id: \.self) { value in
                Text("间隔 ×\(value)").tag(value)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 76)
        .onChange(of: multiplier) { _, newValue in
            settings.setRefreshMultiplier(newValue, for: sourceID)
        }
    }
}

// MARK: - 样式

private enum SettingsPalette {
    static let primaryText = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    /// 与下拉面板统一：primary 透明度随明暗模式自适应
    /// （原白色透明度写法在浅色模式下几乎不可见）
    static let fill = Color.primary.opacity(0.06)
    static let fieldFill = Color.primary.opacity(0.05)
    static let border = Color.primary.opacity(0.12)
}

/// 卡片容器：统一所有设置卡片的内边距、磨砂背景与描边
private struct SettingsCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(SettingsPalette.border, lineWidth: 1)
            )
    }
}

/// API Key 输入框统一样式
private struct KeyFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(SettingsPalette.fieldFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(SettingsPalette.border, lineWidth: 1)
            )
            .font(.callout)
    }
}

private extension View {
    func settingsCard() -> some View { modifier(SettingsCardModifier()) }
    func keyFieldStyle() -> some View { modifier(KeyFieldModifier()) }
}

private struct SettingsProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(isEnabled ? .white : .secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isEnabled
                        ? (configuration.isPressed ? Color.primary.opacity(0.65) : Color.primary.opacity(0.78))
                        : Color.primary.opacity(0.12))
            )
            .opacity(isEnabled ? 1 : 0.5)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview {
    SettingsView()
}
