//
//  AppDelegate.swift
//  zenmux-monitor
//
//  macOS 菜单栏状态项管理器
//  使用原生 NSStatusItem + 自定义 NSView 绘制双进度条
//  替代 MenuBarExtra（其 label 宽度受系统硬限制）
//

import AppKit
import SwiftUI

// MARK: - 用量配色（下拉面板统一蓝→橙→红三档）

/// 下拉面板中所有按「占比」变色的控件统一使用此配色，
/// 避免色值在 QuotaRow 等多处重复定义、改一处忘一处。
enum UsagePalette {
    /// 低占比（< 50%）：蓝
    static let low    = Color(red: 0.18, green: 0.56, blue: 0.98)
    /// 中占比（50% ~ 80%）：橙
    static let mid    = Color(red: 0.98, green: 0.67, blue: 0.19)
    /// 高占比（> 80%）：红
    static let high   = Color(red: 0.90, green: 0.34, blue: 0.31)

    /// 按占比返回对应档位颜色。
    static func color(for fraction: Double) -> Color {
        if fraction > 0.8 { return high }
        if fraction > 0.5 { return mid }
        return low
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let menuContentWidth: CGFloat = 336
    /// 每个源独立的状态栏项（按 sourceID 索引），随设置开关动态创建/销毁
    private var statusItems: [String: NSStatusItem] = [:]
    /// 与 statusItems 一一对应的离屏渲染视图
    private var statusBarViews: [String: StatusItemRenderable] = [:]
    /// 下拉面板菜单（单实例，挂到第一个可见状态栏项上）
    private let dropdownMenu = NSMenu()
    private var settingsWindow: NSWindow?
    private var appearanceObservers: [NSObjectProtocol] = []
    private var localNotificationObservers: [NSObjectProtocol] = []
    private var isShuttingDown = false
    private let registry = SourceRegistry.shared
    private var sizeObservers: [MenuHostingSizeObserver] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItems()
        observeAPIService()
        observeAppearanceChanges()
        // 启动所有源：Zenmux 走 handleAppLaunch，DeepSeek/Kimi 的缓存恢复已在各自 init 中
        registry.sources.forEach { source in
            if let zenmux = source as? ZenmuxAPIService {
                zenmux.handleAppLaunch()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {

        let distributedCenter = DistributedNotificationCenter.default()
        appearanceObservers.forEach { distributedCenter.removeObserver($0) }
        appearanceObservers.removeAll()

        let localCenter = NotificationCenter.default
        localNotificationObservers.forEach { localCenter.removeObserver($0) }
        localNotificationObservers.removeAll()

        performShutdownCleanup()
    }

    // MARK: - 数据观察（任一源状态变化时同步状态栏）

    @MainActor
    private func observeAPIService() {
        registry.sources.forEach { source in
            source.onStateChange = { [weak self] in
                self?.syncStatusItems()
            }
        }
        syncStatusItems()
    }

    // MARK: - 状态栏项（每源一项，按设置开关动态管理）

    private func setupStatusItems() {
        dropdownMenu.delegate = self

        // 设置面板的状态栏开关变更时重建
        let settingsObserver = NotificationCenter.default.addObserver(
            forName: .statusBarSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncStatusItems()
            }
        }
        localNotificationObservers.append(settingsObserver)

        syncStatusItems()
    }

    private func observeAppearanceChanges() {
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateAllStatusItems()
            }
        }
        appearanceObservers = [observer]

        // 状态栏自身背景变深/变浅时也需重绘（与系统外观切换独立）
        let statusBarObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleStatusItemChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateAllStatusItems()
            }
        }
        appearanceObservers.append(statusBarObserver)
    }

    /// 按设置开关与数据可用性同步所有状态栏项：创建/移除/重绘，
    /// 并把下拉菜单挂到第一个可见项上
    @MainActor
    private func syncStatusItems() {
        guard !isShuttingDown else { return }
        let settings = SettingsManager.shared
        var visibleIDs: [String] = []

        for source in registry.sources {
            let id = source.sourceID
            if settings.statusBarEnabled(for: id), statusContentAvailable(for: source) {
                visibleIDs.append(id)
                if statusItems[id] == nil {
                    createStatusItem(for: source)
                }
                // 防御性重绑：每次同步都确保视图绑定到本 ID 对应的源，
                // 杜绝弱引用失效/绑定错误导致的跨源内容串扰
                rebindStatusBarView(statusBarViews[id], to: source)
                if let view = statusBarViews[id], let item = statusItems[id], let button = item.button {
                    renderStatusBarView(view, into: item, button: button)
                }
            } else {
                removeStatusItem(id: id)
            }
        }

        // 下拉菜单挂到所有可见项：点击任一源的状态栏图标都能弹出面板；
        // NSMenu 单实例共享，menuWillOpen 时统一重建内容
        for (id, item) in statusItems {
            item.menu = visibleIDs.contains(id) ? dropdownMenu : nil
        }

        // 兜底：所有源开关全部关闭时，保留一个仅显示 App Logo 的状态栏项，
        // 确保用户始终能点击打开下拉面板进入设置重新开启显示；
        // 任一源可见时移除兜底项，避免重复占位
        if visibleIDs.isEmpty {
            showFallbackLogoItem()
        } else {
            removeStatusItem(id: Self.fallbackSourceID)
        }
    }

    /// 兜底 Logo 状态栏项的保留 ID（不属于任何监控源）
    private static let fallbackSourceID = "__fallback_logo__"

    /// 创建（或刷新）兜底 Logo 状态栏项并挂载下拉菜单
    @MainActor
    private func showFallbackLogoItem() {
        if statusItems[Self.fallbackSourceID] == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                button.title = ""
                button.imagePosition = .imageOnly
                button.imageScaling = .scaleNone
            }
            let view = StatusBarView(frame: NSRect(x: 0, y: 0, width: 49, height: 22))
            view.registry = registry
            view.forceLogo = true
            statusBarViews[Self.fallbackSourceID] = view
            statusItems[Self.fallbackSourceID] = item
        }
        if let view = statusBarViews[Self.fallbackSourceID],
           let item = statusItems[Self.fallbackSourceID],
           let button = item.button {
            renderStatusBarView(view, into: item, button: button)
            item.menu = dropdownMenu
        }
    }

    /// 仅重绘已存在的状态栏项（明暗外观变化时用，不增删项）
    @MainActor
    private func updateAllStatusItems() {
        guard !isShuttingDown else { return }
        for (id, item) in statusItems {
            guard let view = statusBarViews[id], let button = item.button else { continue }
            renderStatusBarView(view, into: item, button: button)
        }
    }

    /// 源是否有可展示的状态栏内容：Zenmux 无数据时有 Logo 回退，始终可见；
    /// 配额型需双窗口，余额型需有快照
    private func statusContentAvailable(for source: any MonitoredSource) -> Bool {
        if source.sourceID == "zenmux" { return true }
        guard let snapshot = source.snapshot else { return false }
        switch snapshot {
        case .quota(let quota): return quota.windows.count >= 2
        case .balance: return true
        }
    }

    private func createStatusItem(for source: any MonitoredSource) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = ""
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
        }
        statusBarViews[source.sourceID] = makeStatusBarView(for: source)
        statusItems[source.sourceID] = item
    }

    private func removeStatusItem(id: String) {
        guard let item = statusItems[id] else { return }
        item.menu = nil
        NSStatusBar.system.removeStatusItem(item)
        statusItems[id] = nil
        statusBarViews[id] = nil
    }

    /// 防御性重绑：把渲染视图重新绑定到当前源。
    /// StatusBarView.targetSource / DeepSeekBalanceStatusView.source 均为弱引用，
    /// 一旦失效会回退渲染其他源（primaryQuotaSource）的数据，
    /// 造成状态栏项内容串扰；因此每次同步都强制重写绑定
    private func rebindStatusBarView(_ view: StatusItemRenderable?, to source: any MonitoredSource) {
        if let sbv = view as? StatusBarView {
            sbv.registry = registry
            sbv.targetSource = source
        } else if let dsv = view as? DeepSeekBalanceStatusView {
            dsv.source = source as? DeepSeekAPIService
        }
    }

    /// 按源类型创建离屏渲染视图：配额型（Zenmux/Kimi）双进度条，余额型（DeepSeek）紧凑文本。
    /// 每个源（含 Zenmux）都创建独立视图实例：历史上的共享实例在
    /// 多源场景下存在状态残留/串扰风险，统一为每源一新实例
    private func makeStatusBarView(for source: any MonitoredSource) -> StatusItemRenderable {
        switch source.sourceID {
        case "deepseek":
            let view = DeepSeekBalanceStatusView(frame: NSRect(x: 0, y: 0, width: 60, height: 22))
            view.source = source as? DeepSeekAPIService
            return view
        default:
            // Zenmux / Kimi 及未来配额型源：双进度条视图；
            // 仅 Zenmux 无数据时回退 App Logo（主源始终可见的产品入口）；
            // Kimi 加源标识徽章，与 Zenmux 同款式进度条区分
            let view = StatusBarView(frame: NSRect(x: 0, y: 0, width: 49, height: 22))
            view.registry = registry
            view.targetSource = source
            view.showsLogoFallback = source.sourceID == "zenmux"
            view.showsSourceBadge = source.sourceID == "kimi"
            view.showsPercentText = source.sourceID != "kimi"
            return view
        }
    }

    /// 渲染视图位图并应用到状态栏按钮；宽度随内容自适应
    private func renderStatusBarView(_ view: StatusItemRenderable, into item: NSStatusItem, button: NSStatusBarButton) {
        view.appearance = button.effectiveAppearance
        let image = view.renderedImage()
        button.image = image
        item.length = image.size.width
        button.needsDisplay = true
    }

    // MARK: - 菜单构建（懒加载）

    private func buildMenuItems(into menu: NSMenu) {
        // 全局 Header：App 名 + 全局操作（暂停/刷新）
        let headerItem = NSMenuItem()
        let headerView = MenuGlobalHeaderView(registry: registry)
        let hosting = NSHostingView(rootView: headerView.frame(width: menuContentWidth))
        let headerSize = hosting.fittingSize
        hosting.frame = NSRect(x: 0, y: 0, width: menuContentWidth, height: headerSize.height)
        headerItem.view = hosting
        menu.addItem(headerItem)

        // 只显示有数据的源；没有任何源有数据时，才显示全部占位（引导用户配置）。
        // 顺序按用户自定义的区块排序（未设置时回退注册表顺序），
        // 菜单每次打开重建，排序变更无需重启即时生效
        let ordered = registry.orderedSources
        let withData = ordered.filter { $0.snapshot != nil }
        let displaySources = withData.isEmpty ? ordered : withData

        // 动态构建每个启用的源区块（源之间不加分隔线：
        // 各区块已有圆角卡片背景与描边，仅靠卡片自身分组，减少视觉噪音）
        for source in displaySources {
            let item = NSMenuItem()
            let view: AnyView

            if let snapshot = source.snapshot {
                switch snapshot {
                case .quota(let quotaSnapshot):
                    var section = SourceQuotaSection(source: source, snapshot: quotaSnapshot)
                    // 详情展开/收起改变 SwiftUI 高度后 KVO 未必触发，
                    // 用回调延时强制重测菜单项高度，确保展开内容完整可见
                    section.onToggleDetails = { [weak self] in
                        self?.scheduleMenuLayoutSync()
                    }
                    view = AnyView(section)
                case .balance(let balanceSnapshot):
                    view = AnyView(SourceBalanceSection(source: source, snapshot: balanceSnapshot))
                }
            } else {
                // 兜底：无数据时显示占位（仅当所有源都无数据时才会走到这里）
                view = AnyView(SourcePlaceholderSection(source: source))
            }

            let hosting = NSHostingView(rootView: view.frame(width: menuContentWidth))
            let size = hosting.fittingSize
            hosting.frame = NSRect(x: 0, y: 0, width: menuContentWidth, height: size.height)
            item.view = hosting
            menu.addItem(item)

            // KVO 监听内容尺寸变化：数据异步返回后 fittingSize 变化，
            // 需更新 frame 避免内容被裁剪（覆盖安装后首次无缓存时尤为明显）
            let observer = MenuHostingSizeObserver(
                hostingView: hosting, menu: menu, menuContentWidth: menuContentWidth
            )
            sizeObservers.append(observer)
            observer.start()
        }

        menu.addItem(.separator())

        // 底部操作行
        let actionItem = NSMenuItem()
        let actionView = MenuActionRow(
            onSettings: { [weak self] in self?.openSettings() },
            onRefresh: { [weak self] in self?.refreshData() },
            onQuit: { [weak self] in self?.quitApp() },
            isRefreshing: registry.isAnyRefreshing,
            hasAPIKey: true,  // 多源场景下，任一源有数据即可刷新；DeepSeek 未配置时静默跳过
            isShuttingDown: isShuttingDown
        )
        let actionHosting = NSHostingView(rootView: actionView.frame(width: menuContentWidth))
        let actionSize = actionHosting.fittingSize
        actionHosting.frame = NSRect(x: 0, y: 0, width: menuContentWidth, height: actionSize.height)
        actionItem.view = actionHosting
        menu.addItem(actionItem)
    }

    private func openSettings() {
        guard !isShuttingDown else { return }
        if settingsWindow == nil {
            let hosting = NSHostingView(rootView: SettingsView())
            settingsHostingView = hosting
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: Self.settingsWindowWidth, height: 360),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = "Zenmonitor 设置"
            win.contentView = hosting
            win.minSize = NSSize(width: 420, height: 300)
            win.isReleasedWhenClosed = false
            win.delegate = self
            settingsWindow = win
            fitSettingsWindowToContent()
            win.center()
        } else {
            // 内容可能随源数量/控件状态变化，每次打开重新适配高度
            fitSettingsWindowToContent()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 设置窗口固定宽度（高度随内容自适应）
    private static let settingsWindowWidth: CGFloat = 460

    /// 设置窗口宿主视图缓存：每次打开时按内容重算窗口高度
    private var settingsHostingView: NSHostingView<SettingsView>?

    /// 按内容理想高度自适应设置窗口：夹在 [320, min(760, 屏幕可用高度-60)] 区间，
    /// 内容多时不截断（超出上限由内部 ScrollView 承担滚动），内容少时无大片空白；
    /// 调整时保持窗口顶边不动，向下扩展
    private func fitSettingsWindowToContent() {
        guard let win = settingsWindow, let hosting = settingsHostingView else { return }
        // 先固定到目标宽度再测理想高度，保证 fittingSize 准确
        hosting.frame = NSRect(x: 0, y: 0, width: Self.settingsWindowWidth,
                               height: max(hosting.frame.height, 1))
        let screenLimit = (win.screen ?? NSScreen.main).map { $0.visibleFrame.height - 60 } ?? 760
        let target = min(max(hosting.fittingSize.height, 320), min(760, screenLimit))
        guard abs(win.frame.height - target) > 4 else { return }
        var frame = win.frame
        frame.origin.y -= target - frame.height
        frame.size.height = target
        win.setFrame(frame, display: true)
    }

    private func quitApp() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        NSApplication.shared.terminate(nil)
    }

    private func refreshData() {
        guard !isShuttingDown else { return }
        Task { [weak self] in
            guard let self, !self.isShuttingDown else { return }
            await self.registry.refreshAll()
            self.syncStatusItems()
        }
    }

    // MARK: - NSMenuDelegate（懒加载菜单）

    func menuWillOpen(_ menu: NSMenu) {
        guard !isShuttingDown else { return }
        if !menu.items.isEmpty { menu.removeAllItems() }
        buildMenuItems(into: menu)
        // 菜单打开时刷新所有源（DeepSeek 走「菜单打开时拉取」策略）
        Task { [weak self] in
            guard let self, !self.isShuttingDown else { return }
            await self.registry.refreshAll()
            self.syncStatusItems()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard !isShuttingDown else { return }
        sizeObservers.forEach { $0.stop() }
        sizeObservers.removeAll()
        menu.removeAllItems()
    }

    /// 详情展开/收起后强制同步菜单项高度：分两次延时重测，
    /// 覆盖 SwiftUI 布局提交的时序不确定性
    private func scheduleMenuLayoutSync() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            self?.syncMenuLayout()
            try? await Task.sleep(nanoseconds: 140_000_000)
            self?.syncMenuLayout()
        }
    }

    /// 重测所有菜单项宿主视图高度并刷新菜单排布
    @MainActor
    private func syncMenuLayout() {
        for observer in sizeObservers { observer.syncNow() }
    }

    func windowWillClose(_ notification: Notification) {
        guard !isShuttingDown else { return }
        if let win = notification.object as? NSWindow, win == settingsWindow {
            win.contentView = nil
            settingsWindow = nil
            settingsHostingView = nil
        }
    }

    private func performShutdownCleanup() {
        isShuttingDown = true
        // 清理每个源的回调
        registry.sources.forEach { source in
            source.onStateChange = nil
            if let zenmux = source as? ZenmuxAPIService {
                zenmux.cleanup()
            }
        }
        dropdownMenu.delegate = nil
        dropdownMenu.removeAllItems()
        // 移除全部状态栏项
        for (id, item) in statusItems {
            item.menu = nil
            NSStatusBar.system.removeStatusItem(item)
            statusItems[id] = nil
        }
        statusBarViews.removeAll()

        if let win = settingsWindow {
            win.orderOut(nil)
            win.contentView = nil
            win.delegate = nil
            settingsWindow = nil
            settingsHostingView = nil
        }
    }
}

// MARK: - 菜单区块高度自适应

/// KVO 监听 NSHostingView 的 intrinsicContentSize 变化，
/// 数据异步返回后重算 frame 高度，避免内容被固定高度裁剪。
/// 用于各源区块。
final class MenuHostingSizeObserver: NSObject {
    private weak var hostingView: NSView?
    private weak var menu: NSMenu?
    private let menuContentWidth: CGFloat
    private var observation: NSKeyValueObservation?

    init(hostingView: NSView, menu: NSMenu, menuContentWidth: CGFloat) {
        self.hostingView = hostingView
        self.menu = menu
        self.menuContentWidth = menuContentWidth
    }

    func start() {
        observation = hostingView?.observe(\.intrinsicContentSize, options: [.new]) { [weak self] _, _ in
            // KVO 可能在任意线程触发，统一回主线程处理
            DispatchQueue.main.async { self?.syncNow() }
        }
    }

    /// 重测宿主视图高度并刷新菜单：高度变化时更新 frame。
    /// SwiftUI @State 变更（详情展开/收起）引起的 intrinsicContentSize
    /// 变化不一定被 KVO 捕获，展开回调也会主动调用本方法兼容兼保险
    func syncNow() {
        guard let view = hostingView else { return }
        let newSize = view.fittingSize
        // 仅在高度发生明显变化时更新，避免无意义的重排
        guard abs(newSize.height - view.frame.height) > 1 else { return }
        view.frame = NSRect(x: 0, y: 0, width: menuContentWidth, height: newSize.height)
        // 延迟到下一 runloop 触发菜单重排，确保 frame 更先生效
        DispatchQueue.main.async { [weak self] in
            self?.menu?.update()
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
    }
}

// MARK: - 面板品牌 Logo（下拉面板与设置面板共用）

/// 面板侧品牌 Logo（彩色、透明底）：下拉面板区块头部与设置源卡片
/// 共用同一静态缓存，保证两处尺寸/背景效果一致
enum PanelLogo {
    /// Zenmux Logo：ZenmonitorLogo 源图去除烘焙的浅色圆角底板，保留原色
    static let zenmux: NSImage? = {
        if let icon = NSImage(named: "ZenmonitorLogo"),
           let stripped = stripLightBackgroundKeepColor(icon, lumGate: 0.72) {
            return stripped
        }
        return NSApp.applicationIconImage
    }()
}

/// 区域生长去底（保色版）：从四边透明边缘播种洪泛与外缘连通的浅色/半透明
/// 像素，并对亮度 0.88~0.97 的封闭底板区域（如触手缝隙）兜底清除；
/// 保留像素维持原色（与状态栏的单色版管线区分），最后裁剪到图案包围盒
func stripLightBackgroundKeepColor(_ image: NSImage, lumGate: CGFloat) -> NSImage? {
    // 降采样到 128px 再逐像素处理：面板显示 ≤32pt，避免启动时遍历 512² 卡顿
    let side = 128
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: side, height: side)
    NSGraphicsContext.saveGraphicsState()
    if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                   from: .zero, operation: .sourceOver, fraction: 1)
    }
    NSGraphicsContext.restoreGraphicsState()

    let w = rep.pixelsWide, h = rep.pixelsHigh
    guard w > 2, h > 2 else { return nil }

    var lum = [CGFloat](repeating: 0, count: w * h)
    var alpha = [CGFloat](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            lum[y * w + x] = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
            alpha[y * w + x] = c.alphaComponent
        }
    }

    // 种子：四边上 alpha≈0 的像素
    var isBG = [Bool](repeating: false, count: w * h)
    var queue: [Int] = []
    func seed(_ x: Int, _ y: Int) {
        let i = y * w + x
        if !isBG[i] && alpha[i] < 0.05 { isBG[i] = true; queue.append(i) }
    }
    for x in 0..<w { seed(x, 0); seed(x, 1); seed(x, h - 2); seed(x, h - 1) }
    for y in 0..<h { seed(0, y); seed(1, y); seed(w - 2, y); seed(w - 1, y) }

    // 生长：亮度高于门槛、或半透明（阴影/抗锯齿带）的相邻像素视为背景
    var head = 0
    while head < queue.count {
        let i = queue[head]; head += 1
        let x = i % w, y = i / w
        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
            let nx = x + dx, ny = y + dy
            guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
            let ni = ny * w + nx
            if !isBG[ni] && (lum[ni] > lumGate || alpha[ni] < 0.5) {
                isBG[ni] = true
                queue.append(ni)
            }
        }
    }

    // 清除：背景 + 封闭浅色底板置透明；其余保留原色
    var removed = isBG
    for i in 0..<(w * h) where !isBG[i] && lum[i] > 0.88 && lum[i] <= 0.97 {
        removed[i] = true
    }
    for y in 0..<h {
        for x in 0..<w where removed[y * w + x] {
            rep.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0), atX: x, y: y)
        }
    }

    // 裁剪到图案包围盒，去除图标设计的四周留白
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h {
        for x in 0..<w where !removed[y * w + x] && alpha[y * w + x] > 0.05 {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
    guard maxX >= minX, maxY >= minY, let cg = rep.cgImage else {
        let out = NSImage(size: NSSize(width: w, height: h))
        out.addRepresentation(rep)
        return out
    }
    let pad = 1
    let cropRect = CGRect(
        x: max(0, minX - pad), y: max(0, minY - pad),
        width: min(w, maxX + pad + 1) - max(0, minX - pad),
        height: min(h, maxY + pad + 1) - max(0, minY - pad)
    )
    guard let cropped = cg.cropping(to: cropRect) else {
        let out = NSImage(size: NSSize(width: w, height: h))
        out.addRepresentation(rep)
        return out
    }
    return NSImage(cgImage: cropped, size: NSSize(width: cropRect.width, height: cropRect.height))
}

// MARK: - 状态栏渲染视图协议

/// 可离屏渲染状态栏内容的视图（双进度条视图 / 余额文本视图）
@MainActor
protocol StatusItemRenderable: NSView {
    func renderedImage() -> NSImage
}

/// 共享的 2x 位图渲染：把视图 draw() 输出为状态栏用 NSImage。
/// isTemplate 固定 false：内容已按明暗外观直接绘制为目标颜色，
/// 交给系统 tinting 反会把透明区填实。
@MainActor
func renderStatusBarBitmap(of view: NSView, size: NSSize) -> NSImage {
    // 同步 frame：draw() 内部用 bounds 布局，frame 必须与位图尺寸一致，
    // 否则内容会画到位图之外（历史 Logo 细条 bug 的根因）
    view.frame = NSRect(origin: .zero, size: size)
    let bounds = NSRect(origin: .zero, size: size)

    // 手动创建 2x 像素位图（rep.size 以点为单位），绘制天然 2x 密度；
    // 不叠加 context 缩放，避免与位图自身倍率双重放大导致裁切错位
    let scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width * scale),
        pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return NSImage(size: size) }
    rep.size = size

    NSGraphicsContext.saveGraphicsState()
    if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
        NSGraphicsContext.current = ctx
        view.draw(bounds)
    }
    NSGraphicsContext.restoreGraphicsState()

    let image = NSImage(size: size)
    image.addRepresentation(rep)
    // 模板图（DEVELOPMENT.md §5.1 双屏自适应方案）：内容统一画纯黑+alpha，
    // 系统按「状态项所在菜单栏屏幕」的外观独立 tint（每屏各有渲染管线），
    // 浅色屏映射为黑色、深色屏自动白色，多显示器独立外观无需任何手动判定
    image.isTemplate = true
    return image
}

// MARK: - 菜单栏自定义绘制视图（配额型双进度条）

final class StatusBarView: NSView, StatusItemRenderable {
    weak var registry: SourceRegistry?
    /// 指定渲染的配额源；解析失败时不回退其他源（见 resolvedQuota 注释）
    weak var targetSource: (any MonitoredSource)?
    /// 无数据时是否回退绘制 App Logo（仅 Zenmux 项启用）
    var showsLogoFallback = false
    /// 强制只画 Logo（兜底状态栏项用：所有源开关关闭时
    /// 仍保留一个可点击入口，让用户能重新打开设置）
    var forceLogo = false
    /// 进度条左侧绘制源标识小 Logo（Kimi 项专用）：
    /// 两个配额源的双进度条样式完全相同，无标识时无法区分，
    /// 容易被误认为内容串扰/复制
    var showsSourceBadge = false
    /// 是否绘制百分比文字（Zenmux 保留；Kimi 关闭以缩减横向占用）
    var showsPercentText = true

    private static let percentFont = NSFont.monospacedDigitSystemFont(ofSize: 9.2, weight: .regular)
    private static let pausedFont = NSFont.systemFont(ofSize: 7)
    private static let normalLeadingInset: CGFloat = 1.2
    private static let normalTrailingInset: CGFloat = 0.2
    private static let barTextGap: CGFloat = 0.4
    /// 源标识徽章占位宽（Kimi Logo 高 8pt 按宽高比展开 + 边距）
    private static let badgeLeading: CGFloat = 12
    /// 徽章 Logo 绘制高度
    private static let badgeLogoHeight: CGFloat = 8

    private static let percentRightPadding: CGFloat = {
        "0".size(withAttributes: [.font: StatusBarView.percentFont]).width * 0.35
    }()

    private static let percentTextReserveWidth: CGFloat = {
        max(
            "99.9%".size(withAttributes: [.font: StatusBarView.percentFont]).width,
            "100%".size(withAttributes: [.font: StatusBarView.percentFont]).width
        ) + StatusBarView.percentRightPadding
    }()

    private struct Palette {
        let barBackground: NSColor
        let pausedBackground: NSColor
        let pausedFill: NSColor
        let lowUsage: NSColor
        let midUsage: NSColor
        let highUsage: NSColor
        let primaryText: NSColor
        let secondaryText: NSColor
    }

    override var intrinsicContentSize: NSSize {
        // 无配额数据时仅画 Logo：宽度按剪影宽高比自适应，高度占满菜单栏
        if showsLogo {
            let h: CGFloat = Self.logoDrawHeight
            let aspect = Self.appLogo.map { $0.size.width / max($0.size.height, 1) } ?? 1
            return NSSize(width: max(22, (h * aspect).rounded() + 2), height: 22)
        }
        // 不画百分比文字时（Kimi）：宽度 = 徽章占位 + 进度条，不再预留文字区，
        // 进度条区 28→24pt（缩短 ~15% 进一步减少空间占用）
        if !showsPercentText {
            return NSSize(width: Self.badgeLeading + 24, height: 22)
        }
        // 带源标识徽章时宽度相应加宽
        return NSSize(width: 49 + (showsSourceBadge ? Self.badgeLeading : 0), height: 22)
    }

    /// 当前解析出的配额快照：只读绑定的 targetSource。
    /// 不再回退 registry.primaryQuotaSource——隐式回退会让视图在
    /// 绑定失效时渲染其他源的数据（串扰唯一残留路径，已根除）；
    /// 兜底项（targetSource 为 nil）由 showsLogo 提前短路，不受影响
    private var resolvedQuota: (source: any MonitoredSource, snapshot: QuotaSnapshot)? {
        guard let source = targetSource,
              let snapshot = source.snapshot,
              case .quota(let quotaSnapshot) = snapshot,
              quotaSnapshot.windows.count >= 2 else {
            return nil
        }
        return (source, quotaSnapshot)
    }

    /// 是否处于「仅显示 Logo」状态：强制 Logo（兜底项），或
    /// 指定源无可用数据且允许回退时（未配置 Key / 尚未加载 / 请求失败）
    private var showsLogo: Bool {
        forceLogo || (showsLogoFallback && resolvedQuota == nil)
    }

    func renderedImage() -> NSImage {
        renderStatusBarBitmap(of: self, size: intrinsicContentSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // 仅 Logo 状态（兜底项 forceLogo / Zenmux 无数据回退）：
        // 必须先于 resolvedQuota 判定——否则 targetSource 为 nil 的兜底视图
        // 会回退到 primaryQuotaSource，把别的源的进度条画进 Logo 位图
        if showsLogo {
            drawLogo()
            return
        }

        // 读取配额快照；无可用数据时什么都不画
        guard let resolved = resolvedQuota else {
            return
        }
        let source = resolved.source
        let quotaSnapshot = resolved.snapshot

        // Zenmux 特有：检查暂停状态（通过协议扩展或类型判断）
        if let zenmux = source as? ZenmuxAPIService, zenmux.isPaused {
            drawPaused(quotaSnapshot)
            return
        }

        let palette = currentPalette
        let layout = normalLayoutMetrics

        // 源标识徽章（Kimi 项）：与 Zenmux 同款式双进度条的区分标记
        if showsSourceBadge {
            drawSourceBadge(palette: palette)
        }

        let barH: CGFloat = 4.5
        let spacing: CGFloat = 4
        let topY = bounds.height - barH - 5
        let bottomY = topY - barH - spacing
        let corner: CGFloat = 2.25

        // 前两个窗口：5h 在上，7d 在下（按 QuotaSnapshot.windows 顺序）
        let windows = quotaSnapshot.windows
        drawBar(x: layout.barX, y: topY, width: layout.barWidth, height: barH,
                pct: windows[0].pct, radius: corner, palette: palette)
        drawBar(x: layout.barX, y: bottomY, width: layout.barWidth, height: barH,
                pct: windows[1].pct, radius: corner, palette: palette)

        // Kimi 项不画百分比文字，仅保留双进度条以缩减横向占用
        guard showsPercentText else { return }

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: Self.percentFont,
            .foregroundColor: palette.primaryText
        ]
        drawPercent(text: percentStr(windows[0].pct),
                rightEdge: layout.textRightEdge, barRightEdge: layout.barRightEdge,
                barY: topY, barH: barH, attrs: textAttrs)
        drawPercent(text: percentStr(windows[1].pct),
                rightEdge: layout.textRightEdge, barRightEdge: layout.barRightEdge,
                barY: bottomY, barH: barH, attrs: textAttrs)
    }

    private func drawPaused(_ snapshot: QuotaSnapshot) {
        let palette = currentPalette
        let layout = pausedLayoutMetrics
        let barH: CGFloat = 4.5
        let topY = bounds.height - barH - 5
        let bottomY = topY - barH - 2

        let windows = snapshot.windows
        drawDimmedBar(x: layout.barX, y: topY, width: layout.barWidth, height: barH,
                      pct: windows[0].pct, palette: palette)
        drawDimmedBar(x: layout.barX, y: bottomY, width: layout.barWidth, height: barH,
                      pct: windows[1].pct, palette: palette)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.pausedFont,
            .foregroundColor: palette.secondaryText
        ]
        "⏸".draw(at: NSPoint(x: layout.textX, y: bottomY - 1), withAttributes: attrs)
    }

    private func drawDimmedBar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
                               pct: Double, palette: Palette) {
        let barRect = NSRect(x: x, y: y, width: width, height: height)
        let bgPath = NSBezierPath(roundedRect: barRect, xRadius: 2, yRadius: 2)
        palette.pausedBackground.setFill()
        bgPath.fill()

        let clamped = max(0, min(pct, 1))
        let fw = width * CGFloat(clamped)
        guard fw > 0.5 else { return }

        NSGraphicsContext.saveGraphicsState()
        bgPath.addClip()
        let fillRect = NSRect(x: x, y: y, width: fw, height: height)
        palette.pausedFill.setFill()
        NSBezierPath(rect: fillRect).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func percentStr(_ pct: Double) -> String {
        let percent = (max(0, min(pct, 1)) * 1000).rounded() / 10
        // 有消耗但不足 1% 时显示 <1%，避免取整为 0% 的误导
        if percent > 0 && percent < 1 { return "<1%" }
        if percent == 0 || percent == 100 {
            return String(format: "%.0f%%", percent)
        }
        return String(format: "%.1f%%", percent)
    }

    private func drawPercent(text: String, rightEdge: CGFloat, barRightEdge: CGFloat, barY: CGFloat, barH: CGFloat,
                             attrs: [NSAttributedString.Key: Any]) {
        let size = text.size(withAttributes: attrs)
        let y = barY + (barH - size.height) / 2
        let idealX = rightEdge - size.width
        let minX = barRightEdge + Self.barTextGap
        let drawX = max(minX, min(idealX, bounds.maxX - size.width))
        text.draw(at: NSPoint(x: drawX, y: y), withAttributes: attrs)
    }

    /// Logo 绘制高度：菜单栏约 24pt，19pt 接近上限且留有呼吸空间
    private static let logoDrawHeight: CGFloat = 19

    /// 无配额数据时的占位：居中绘制 App Logo（已抠去底板并裁剪到剪影包围盒）
    private func drawLogo() {
        // 黑色剪影 + 模板 tint：深/浅色菜单栏由系统自动映射，无需反色版
        guard let icon = Self.appLogo else { return }
        // 按宽高比适配，高度占满可用区域
        let h = Self.logoDrawHeight
        let w = h * icon.size.width / max(icon.size.height, 1)
        let rect = NSRect(
            x: (bounds.width - w) / 2,
            y: (bounds.height - h) / 2,
            width: w,
            height: h
        )
        NSGraphicsContext.saveGraphicsState()
        icon.draw(in: rect, from: NSRect(origin: .zero, size: icon.size),
                  operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// App Logo 缓存：优先用 Asset Catalog 中的 ZenmonitorLogo（源自 appicon-512.png），
    /// 加载后抠去图标自带的浅灰圆角底板，只留章鱼剪影；失败时逐级回退。
    /// 注意：不能直接用 AppIcon.icns —— 其内部位图为旧式 8-bit 遮罩格式，
    /// 转 RGBA 后全图不透明纯黑，无法逐像素处理。
    private static let appLogo: NSImage? = {
        if let icon = NSImage(named: "ZenmonitorLogo"),
           let stripped = floodStripBackground(icon, lumGate: 0.72) {
            return stripped
        }
        if let icon = NSApp.applicationIconImage {
            return icon
        }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }()

    /// 区域生长去背景：从图像四周透明边缘出发，洪泛所有与外缘连通的
    /// 浅色/半透明像素（图标底板、投影、抗锯齿带），仅保留不与外缘
    /// 连通的深色图案。比全局亮度阈值更稳：深色图案内部的亮色细节
    /// （如白色眼睛）因不与外缘连通而完整保留。
    private static func floodStripBackground(_ image: NSImage, lumGate: CGFloat) -> NSImage? {
        // 先降采样到 128px 再逐像素处理：菜单栏仅显示 16pt，
        // 避免启动时遍历 512² 像素产生可感知卡顿
        let side = 128
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                       from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()

        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 2, h > 2 else { return nil }

        var lum = [CGFloat](repeating: 0, count: w * h)
        var alpha = [CGFloat](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                lum[y * w + x] = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
                alpha[y * w + x] = c.alphaComponent
            }
        }

        // 种子：四边上 alpha≈0 的像素（圆角外的透明区）
        var isBG = [Bool](repeating: false, count: w * h)
        var queue: [Int] = []
        func seed(_ x: Int, _ y: Int) {
            let i = y * w + x
            if !isBG[i] && alpha[i] < 0.05 { isBG[i] = true; queue.append(i) }
        }
        for x in 0..<w { seed(x, 0); seed(x, 1); seed(x, h - 2); seed(x, h - 1) }
        for y in 0..<h { seed(0, y); seed(1, y); seed(w - 2, y); seed(w - 1, y) }

        // 生长：亮度高于门槛、或半透明（阴影/抗锯齿带）的相邻像素视为背景；
        // 图案为高 alpha 低亮度，不会被侵入
        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            let x = i % w, y = i / w
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                let ni = ny * w + nx
                if !isBG[ni] && (lum[ni] > lumGate || alpha[ni] < 0.5) {
                    isBG[ni] = true
                    queue.append(ni)
                }
            }
        }

        // 清除背景像素 + 图案重着色：
        // 1) 生长标记的背景置透明；
        // 2) 未被生长覆盖的残留浅色像素（触手围合的封闭底板区域，
        //    不与外缘连通，实测亮度 0.93~0.97）按亮度门槛补充清除，
        //    否则菜单栏里出现灰白块；门槛 0.97 同时保留白色眼睛
        //    等高亮细节（亮度≈1.0）；
        // 3) 保留像素置纯黑（菜单栏单色风格，深色模式经反色得纯白）
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let keepAlpha = isBG[i] ? 0 : (lum[i] > 0.97 ? alpha[i] : (lum[i] > 0.88 ? 0 : alpha[i]))
                rep.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: keepAlpha), atX: x, y: y)
            }
        }

        // 裁剪到图案包围盒：去掉图标设计的四周留白，
        // 让小尺寸绘制时剪影尽可能占满可用区域
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where !isBG[y * w + x] && alpha[y * w + x] > 0.05 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY, let cg = rep.cgImage else {
            let out = NSImage(size: NSSize(width: w, height: h))
            out.addRepresentation(rep)
            return out
        }
        let pad = 1
        let cropRect = CGRect(
            x: max(0, minX - pad), y: max(0, minY - pad),
            width: min(w, maxX + pad + 1) - max(0, minX - pad),
            height: min(h, maxY + pad + 1) - max(0, minY - pad)
        )
        guard let cropped = cg.cropping(to: cropRect) else {
            let out = NSImage(size: NSSize(width: w, height: h))
            out.addRepresentation(rep)
            return out
        }
        return NSImage(cgImage: cropped, size: NSSize(width: cropRect.width, height: cropRect.height))
    }

    /// Logo 白色版已废弃：模板 tint 方案下无需反色缓存（历史 CoreImage 反色实现已随方案回归移除）

    /// 源标识徽章：Kimi 品牌 Logo 单色剪影（呼应设置面板/下拉面板的品牌形象），
    /// 黑色剪影交给模板 tint，随所在屏幕菜单栏外观自动黑/白
    private func drawSourceBadge(palette: Palette) {
        // 黑色剪影 + 模板 tint，同 drawLogo
        guard let icon = Self.kimiBadgeLogo else { return }
        let h = Self.badgeLogoHeight
        let w = min(h * icon.size.width / max(icon.size.height, 1), Self.badgeLeading - 2)
        let rect = NSRect(
            x: (Self.badgeLeading - w) / 2,
            y: (bounds.height - h) / 2,
            width: w,
            height: h
        )
        NSGraphicsContext.saveGraphicsState()
        icon.draw(in: rect, from: NSRect(origin: .zero, size: icon.size),
                  operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Kimi 徽章 Logo 缓存：KimiLogo 资源经通用单色化管线处理（去底 + 置黑），
    /// 处理失败时回退到四角星形矢量绘制，保证标识始终存在
    private static let kimiBadgeLogo: NSImage? = {
        if let icon = NSImage(named: "KimiLogo"),
           let mono = makeMonochromeSilhouette(icon) {
            return mono
        }
        return sparkleFallbackImage
    }()

    /// Kimi 徽章白色版已废弃（模板 tint 方案，同 appLogoInverted）

    /// 通用单色化：降采样 → 区域生长去底 → 亮度兜底清残留 → 置纯黑 → 包围盒裁剪。
    /// 与 appLogo 同一套已验证的管线，抽为静态方法供两个 Logo 复用
    private static func makeMonochromeSilhouette(_ image: NSImage) -> NSImage? {
        floodStripBackground(image, lumGate: 0.72)
    }

    /// 四角星形回退图（KimiLogo 资源处理失败时启用）
    private static let sparkleFallbackImage: NSImage? = {
        let side: CGFloat = 16
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(side * 2), pixelsHigh: Int(side * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = NSSize(width: side, height: side)
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            let center = NSPoint(x: side / 2, y: side / 2)
            let radius: CGFloat = 7
            let inner = radius * 0.40
            let diag = inner * 0.707
            let outer: [NSPoint] = [
                NSPoint(x: center.x, y: center.y + radius),
                NSPoint(x: center.x + radius, y: center.y),
                NSPoint(x: center.x, y: center.y - radius),
                NSPoint(x: center.x - radius, y: center.y),
            ]
            let innerPts: [NSPoint] = [
                NSPoint(x: center.x + diag, y: center.y + diag),
                NSPoint(x: center.x + diag, y: center.y - diag),
                NSPoint(x: center.x - diag, y: center.y - diag),
                NSPoint(x: center.x - diag, y: center.y + diag),
            ]
            let path = NSBezierPath()
            path.move(to: outer[0])
            for i in 0..<4 {
                path.line(to: innerPts[i])
                path.line(to: outer[(i + 1) % 4])
            }
            path.close()
            NSColor.black.setFill()
            path.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: NSSize(width: side, height: side))
        out.addRepresentation(rep)
        return out
    }()

    private func drawBar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
                         pct: Double, radius: CGFloat, palette: Palette) {
        let barRect = NSRect(x: x, y: y, width: width, height: height)
        let bgPath = NSBezierPath(roundedRect: barRect, xRadius: radius, yRadius: radius)

        // 1. 背景层
        palette.barBackground.setFill()
        bgPath.fill()

        // 2. 填色层：用背景路径裁剪，填色自然继承左/右圆角
        let clamped = max(0, min(pct, 1))
        let fw = width * CGFloat(clamped)
        guard fw > 0.5 else { return }

        let color: NSColor
        if pct > 0.8 { color = palette.highUsage }
        else if pct > 0.5 { color = palette.midUsage }
        else { color = palette.lowUsage }

        NSGraphicsContext.saveGraphicsState()
        bgPath.addClip()
        let fillRect = NSRect(x: x, y: y, width: fw, height: height)
        color.setFill()
        NSBezierPath(rect: fillRect).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private var currentPalette: Palette {
        // 模板图方案：统一纯黑墨水+alpha 变体，最终 isTemplate=true
        // 由系统按所在屏幕菜单栏外观 tint（见 renderStatusBarBitmap 注释），
        // 不再手动区分明暗（手动方案在每屏独立外观下无法取到正确值）
        let ink = NSColor.black
        return Palette(
            barBackground: ink.withAlphaComponent(0.18),
            pausedBackground: ink.withAlphaComponent(0.12),
            pausedFill: ink.withAlphaComponent(0.28),
            lowUsage: ink.withAlphaComponent(0.58),
            midUsage: ink.withAlphaComponent(0.76),
            highUsage: ink.withAlphaComponent(0.94),
            primaryText: ink,
            secondaryText: ink.withAlphaComponent(0.55)
        )
    }

    private var normalLayoutMetrics: (barX: CGFloat, barWidth: CGFloat, barRightEdge: CGFloat, textRightEdge: CGFloat) {
        // 带源标识徽章时整体右移，给徽章让位
        let leadingInset = Self.normalLeadingInset + (showsSourceBadge ? Self.badgeLeading : 0)
        let trailingInset = Self.normalTrailingInset
        let gap = Self.barTextGap
        // 不画百分比文字时（Kimi）：不预留文字宽度，进度条拉到右缘，缩减横向占用
        let textWidth = showsPercentText ? Self.percentTextReserveWidth : 0
        let textRightEdge = bounds.width - trailingInset
        let textX = textRightEdge - textWidth
        let barWidth = max(13, textX - gap - leadingInset)
        let barRightEdge = leadingInset + barWidth
        return (leadingInset, barWidth, barRightEdge, textRightEdge)
    }

    private var pausedLayoutMetrics: (barX: CGFloat, barWidth: CGFloat, textX: CGFloat) {
        let leadingInset: CGFloat = 4
        let trailingInset: CGFloat = 4
        let gap: CGFloat = 5
        let textWidth: CGFloat = 7
        let textX = bounds.width - trailingInset - textWidth
        let barWidth = max(18, textX - gap - leadingInset)
        return (leadingInset, barWidth, textX)
    }
}

// MARK: - DeepSeek 状态栏文本视图（余额型）

/// DeepSeek 状态栏视图：紧凑余额文本（如 "¥123.45"），
/// monospacedDigit 字体，无进度条，宽度随数字自适应
final class DeepSeekBalanceStatusView: NSView, StatusItemRenderable {
    weak var source: DeepSeekAPIService?

    private static let balanceFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private static let horizontalInset: CGFloat = 2

    private var balanceText: String? {
        guard let info = source?.balanceData?.balance_infos.first else { return nil }
        return info.symbol + String(format: "%.2f", info.total)
    }

    override var intrinsicContentSize: NSSize {
        let width = (balanceText ?? "")
            .size(withAttributes: [.font: Self.balanceFont]).width
        return NSSize(width: ceil(width) + Self.horizontalInset * 2, height: 22)
    }

    func renderedImage() -> NSImage {
        renderStatusBarBitmap(of: self, size: intrinsicContentSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let text = balanceText else { return }
        // 模板图方案：统一纯黑绘制，系统按所在屏幕菜单栏外观 tint
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.balanceFont,
            .foregroundColor: NSColor.black
        ]
        let size = text.size(withAttributes: attrs)
        let y = (bounds.height - size.height) / 2
        text.draw(at: NSPoint(x: Self.horizontalInset, y: y), withAttributes: attrs)
    }
}

// MARK: - 菜单全局 Header 视图

/// 全局 Header：简化为一行，左侧 App 名，右侧操作按钮（暂停/刷新）
struct MenuGlobalHeaderView: View {
    let registry: SourceRegistry

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // 左侧：App 名 + 更新时间（合并为一行）
            HStack(spacing: 6) {
                Text("Zenmonitor")
                    .font(.subheadline.weight(.semibold))
                if let updated = registry.latestUpdateTime {
                    Text("· \(relativeTime(updated))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            // 右侧：操作按钮组
            HStack(spacing: 12) {
                // 主源（Zenmux）的暂停/继续按钮
                if let zenmux = registry.sources.first(where: { $0.sourceID == "zenmux" }) as? ZenmuxAPIService {
                    Button {
                        if zenmux.isPaused {
                            zenmux.resumeAutoRefresh()
                        } else {
                            zenmux.pauseAutoRefresh()
                        }
                    } label: {
                        Image(systemName: zenmux.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(zenmux.isPaused ? .green : .orange)
                    .accessibilityLabel(zenmux.isPaused ? "恢复自动刷新" : "暂停自动刷新")
                }

                // 刷新按钮
                Button {
                    Task {
                        await registry.refreshAll()
                    }
                } label: {
                    Image(systemName: registry.isAnyRefreshing ? "arrow.clockwise.circle.fill" : "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(registry.isAnyRefreshing)
                .accessibilityLabel("刷新所有源")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)秒前" }
        if seconds < 3600 { return "\(seconds / 60)分前" }
        return "\(seconds / 3600)时前"
    }
}

// MARK: - 源配额区块

/// 配额型源（Zenmux）的菜单区块：标题 + 状态 + 进度条列表 + 指标卡片
struct SourceQuotaSection: View {
    let source: any MonitoredSource
    let snapshot: QuotaSnapshot

    /// 次要详情展开状态：仅当前菜单会话有效，菜单每次打开重建时自动回到折叠
    @State private var expanded = false

    /// 展开/收起切换回调：AppDelegate 据此延时强制重测菜单项高度
    /// （SwiftUI 状态变更不一定触发宿主视图 KVO）
    var onToggleDetails: (() -> Void)?

    /// 仅 Zenmux 区块支持折叠次要信息（extraMetrics / flows / USD 明细）；
    /// Kimi 等其余配额源保持原有完整展示，不受影响
    private var isCollapsible: Bool { source.sourceID == "zenmux" }

    /// 次要详情是否可见（非折叠源恒为 true）
    private var showDetails: Bool { !isCollapsible || expanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 源头部：Logo + 名称 + 状态 + 展开/收起入口（统一为一行）
            HStack(spacing: 8) {
                // Logo：有品牌 Logo 的源 20pt（DeepSeek 24pt）；Zenmux 用透明底 App Logo 26pt，
                // 与设置面板共用 PanelLogo 缓存，两处效果一致
                if let logoName = source.logoImageName {
                    Image(logoName)
                        .resizable()
                        .frame(width: source.sourceID == "deepseek" ? 24 : 20,
                               height: source.sourceID == "deepseek" ? 24 : 20)
                } else if let logo = PanelLogo.zenmux {
                    Image(nsImage: logo)
                        .resizable()
                        .frame(width: 26, height: 26)
                }

                // 名称
                Text(snapshot.title)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                // 状态点 + 状态文字
                HStack(spacing: 5) {
                    Circle()
                        .fill(snapshot.status.color)
                        .frame(width: 6, height: 6)
                    Text(snapshot.status.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // 展开/收起入口（仅 Zenmux）：紧凑 chevron，替代原底部行按钮，
                // 省一整行垂直高度；折叠朝右、展开朝下，直觉一致
                if isCollapsible {
                    Button {
                        expanded.toggle()
                        onToggleDetails?()
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "收起详情" : "展开详情")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            // 配额窗口列表（5h / 7d / ...）；折叠时隐藏 flows/USD 文本，
            // 保留进度条/百分比/重置时间；本列表是收尾元素时（无指标卡或折叠态）
            // 保留底部间距，避免内层卡片与外框底边贴齐产生双层边框叠压
            VStack(spacing: 10) {
                ForEach(Array(snapshot.windows.enumerated()), id: \.offset) { _, window in
                    QuotaRow(
                        label: window.label,
                        icon: window.icon,
                        pct: window.pct,
                        usedText: window.usedText,
                        usedUSDText: window.usedUSDText,
                        resetsAt: window.resetsAt,
                        windowDuration: window.windowDuration,
                        projectedPct: window.projectedPct,
                        showDetails: showDetails
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, (snapshot.extraMetrics.isEmpty || !showDetails) ? 10 : 0)

            // 补充指标卡片（月度上限 / 汇率）；折叠时隐藏
            if !snapshot.extraMetrics.isEmpty && showDetails {
                HStack(spacing: 10) {
                    ForEach(Array(snapshot.extraMetrics.enumerated()), id: \.offset) { _, metric in
                        compactMetricCard(
                            title: metric.title,
                            value: metric.value,
                            detail: metric.detail,
                            icon: metric.icon,
                            tint: metric.tint
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.06))  // 主源用深色背景
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func compactMetricCard(title: String, value: String, detail: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(tint)
            Text(value)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

// MARK: - 配额行（纯渲染器）

struct QuotaRow: View {
    let label: String
    let icon: String
    let pct: Double
    let usedText: String
    let usedUSDText: String?
    let resetsAt: Date?
    let windowDuration: TimeInterval
    /// 预测占比：若上游窗口用满，本窗口将达到的占比 [0,1]。
    /// 仅 7d 行传入；nil 表示不渲染预测阴影。
    var projectedPct: Double? = nil
    /// 次要明细（flows / USD）是否可见；折叠时仅保留重置时间，行高不变
    var showDetails: Bool = true

    var body: some View {
        VStack(spacing: 6) {
            // 紧凑结构：标签 · 重置时间（左）| 百分比（右）
            HStack(spacing: 6) {
                HStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.subheadline.weight(.medium))
                    Text(label)
                        .font(.subheadline.weight(.medium))
                    // 重置时间：点分隔紧随标签，如 "Sun 08/17 03:00"
                    if let reset = resetsAt {
                        Text("· \(formatReset(reset))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.secondary)
                Spacer()
                // 有消耗但不足 1% 时显示 <1%，避免取整为 0% 的误导（Kimi 端点为 1% 粒度）
                Text(percentDisplay)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(progressColor)
            }

            // 进度条 + 时间三角形：三角形覆盖在进度条下方但不占空间，
            // 整体高度始终 8pt（与 5h 行一致），三角形用 offset 溢出到进度条外。
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // 底层：轨道
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.10))
                        .frame(height: 8)
                    // 预测阴影：上游窗口用满后本窗口将达到的位置（半透明，露出主条右侧部分）
                    // 颜色按预测值判档，提前预警（预测进入中/高档时阴影变橙/红）
                    if let proj = projectedPct {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(UsagePalette.color(for: proj).opacity(0.22))
                            .frame(width: max(0, geo.size.width * proj), height: 8)
                    }
                    // 主条：当前实际用量（盖在阴影上）
                    RoundedRectangle(cornerRadius: 2)
                        .fill(progressColor)
                        .frame(width: max(0, geo.size.width * pct), height: 8)
                }
            }
            .frame(height: 8)
            // 时间进度三角形：紧贴进度条底部溢出显示，不占据布局空间
            .overlay(alignment: .topLeading) {
                if let reset = resetsAt {
                    GeometryReader { geo in
                        TimeMarkerTriangle(resetsAt: reset, windowDuration: windowDuration, color: progressColor, trackWidth: geo.size.width)
                            .frame(height: 5)
                            .offset(y: 8)
                    }
                }
            }

            // 明细行（flows / USD）：仅展开且有 USD 明细时渲染（Zenmux 展开态）；
            // 折叠态与 Kimi（无 USD 明细且 usedText 是与右侧重复的百分比）
            // 都不渲染此行，高度自然压缩
            if showDetails, let usdText = usedUSDText {
                HStack {
                    Text(usedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(usdText)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        // 去掉独立描边、收缩内边距：区块卡片内的子行仅保留浅色底，
        // 降低嵌套层级的视觉重量
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    /// 重置时间格式：英文星期缩写 + 日期 + 时间（如 "Sun 08/17 03:00"），
    /// 固定 en_US_POSIX locale，避免系统中文区域输出「周日」
    private static let resetFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MM/dd HH:mm"
        return f
    }()

    private func formatReset(_ date: Date) -> String {
        Self.resetFmt.string(from: date)
    }

    private var progressColor: Color {
        UsagePalette.color(for: pct)
    }

    /// 百分比展示：0 < pct < 1 显示 "<1%"，其余保留两位小数
    private var percentDisplay: String {
        let percent = pct * 100
        if percent > 0 && percent < 1 { return "<1%" }
        return String(format: "%.2f%%", percent)
    }
}

// MARK: - 时间进度三角形（进度条下方指示标记）

/// 紧贴进度条下方的小三角形，水平位置 = 当前时间在滚动周期内的占比，
/// 颜色跟随进度条用量色。不占据布局空间（由 overlay + offset 实现）。
struct TimeMarkerTriangle: View {
    let resetsAt: Date
    let windowDuration: TimeInterval
    let color: Color
    let trackWidth: CGFloat

    private func fraction(at now: Date) -> Double {
        guard now < resetsAt else { return 1 }
        let start = resetsAt.addingTimeInterval(-windowDuration)
        let f = now.timeIntervalSince(start) / windowDuration
        return min(max(f, 0), 1)
    }

    var body: some View {
        // 每分钟推进一次
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let fraction = fraction(at: context.date)
            let x = trackWidth * fraction
            Path { p in
                // 向下的等腰小三角形，底边 6pt，高 5pt，尖端朝上贴进度条底部
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x - 3, y: 5))
                p.addLine(to: CGPoint(x: x + 3, y: 5))
                p.closeSubpath()
            }
            .fill(color)
        }
        .frame(height: 5)
    }
}

// MARK: - 源余额区块

/// 余额型源（DeepSeek）的菜单区块：标题 + 总余额 + 明细 + 今日用量（如有）
struct SourceBalanceSection: View {
    let source: any MonitoredSource
    let snapshot: BalanceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 源头部：Logo + 名称（与配额区块样式统一；尺寸与设置面板一致）
            HStack(spacing: 8) {
                // Logo
                if let logoName = source.logoImageName {
                    Image(logoName)
                        .resizable()
                        .frame(width: 24, height: 24)
                }

                // 名称
                Text(snapshot.title)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                // 状态（如有）
                if let status = snapshot.status {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(status.color)
                            .frame(width: 6, height: 6)
                        Text(status.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            // 余额内容：今日用量（左）+ 余额（右）同行；无今日用量时保持大数字布局
            VStack(alignment: .leading, spacing: 8) {
                if let usageText = snapshot.todayUsageText {
                    // 合并行：左今日用量（含弱化的起点说明），右余额
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text("今日用量")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                // 补充说明（自 HH:mm 起）：次要小字，不额外占行
                                if let detail = snapshot.todayUsageDetail {
                                    Text(detail)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            // 消耗以负数呈现，与「余额减少」直觉一致
                            Text("-\(usageText)")
                                .font(.subheadline.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 2) {
                            Text("余额")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(snapshot.currencySymbol)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Text(snapshot.total)
                                    .font(.title3.weight(.semibold))
                                    .monospacedDigit()
                            }
                        }
                    }
                } else {
                    // 无今日用量采样数据：保持原有大数字展示
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(snapshot.currencySymbol)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(snapshot.total)
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                    }
                }

                // 赠金/充值明细不再展示（实际意义不大）；breakdown 数据仍正常获取，
                // 仅移除渲染，不影响余额计算与今日用量统计
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.03))  // 次要源用浅色背景
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - 源占位区块

/// 源无数据时的占位展示（如 DeepSeek 未配置 Key）
struct SourcePlaceholderSection: View {
    let source: any MonitoredSource

    var body: some View {
        VStack(spacing: 10) {
            // 图标
            Image(systemName: source.logoImageName != nil ? "exclamationmark.circle" : "questionmark.circle")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)

            // 标题
            Text(source.displayName)
                .font(.subheadline.weight(.medium))

            // 状态/错误/引导
            if source.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else if let err = source.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(UsagePalette.high)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            } else {
                VStack(spacing: 4) {
                    Text("未配置 API Key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("前往设置添加")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - 菜单底部操作按钮行

struct MenuActionRow: View {
    let onSettings: () -> Void
    let onRefresh: () -> Void
    let onQuit: () -> Void
    let isRefreshing: Bool
    let hasAPIKey: Bool
    let isShuttingDown: Bool

    var body: some View {
        HStack(spacing: 0) {
            actionButton(
                icon: "gearshape.fill",
                label: "设置",
                action: onSettings,
                disabled: isShuttingDown
            )

            Divider()
                .frame(height: 16)

            actionButton(
                icon: "arrow.clockwise",
                label: isRefreshing ? "刷新中" : "刷新",
                action: onRefresh,
                disabled: isRefreshing || isShuttingDown
            )

            Divider()
                .frame(height: 16)

            actionButton(
                icon: "power",
                label: "退出",
                action: onQuit,
                disabled: false
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    private func actionButton(icon: String, label: String, action: @escaping () -> Void, disabled: Bool) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(height: 16)
                Text(label)
                    .font(.system(size: 9, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? .tertiary : .secondary)
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}
