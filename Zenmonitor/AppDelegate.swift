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
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var appearanceObservers: [NSObjectProtocol] = []
    private var isShuttingDown = false
    private let registry = SourceRegistry.shared
    private var sizeObservers: [MenuHostingSizeObserver] = []
    private let statusView = StatusBarView(frame: NSRect(x: 0, y: 0, width: 49, height: 22))

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        observeAPIService()
        observeAppearanceChanges()
        // 启动所有源：Zenmux 走 handleAppLaunch，DeepSeek 走 restoreCachedBalance（已在 init 中）
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

        performShutdownCleanup()
    }

    // MARK: - 数据观察（状态变化时刷新进度条）

    @MainActor
    private func observeAPIService() {
        // 监听每个源的变化，任一源更新都刷新状态栏
        registry.sources.forEach { source in
            if let zenmux = source as? ZenmuxAPIService {
                zenmux.onStateChange = { [weak self] in
                    self?.updateStatusItemImage()
                }
            }
        }
        updateStatusItemImage()
    }

    // MARK: - 状态栏项

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.length = statusView.intrinsicContentSize.width

        statusView.registry = registry

        if let button = item.button {
            button.title = ""
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
        }
        statusItem = item
        updateStatusItemImage()

        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
    }

    private func observeAppearanceChanges() {
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateStatusItemImage()
            }
        }
        appearanceObservers = [observer]
    }

    @MainActor
    private func updateStatusItemImage() {
        guard !isShuttingDown, let button = statusItem?.button else { return }
        statusView.appearance = button.effectiveAppearance
        button.image = statusView.renderedImage()
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

        // 只显示有数据的源；没有任何源有数据时，才显示全部占位（引导用户配置）
        let displaySources = registry.dataSources.isEmpty ? registry.sources : registry.dataSources

        // 动态构建每个启用的源区块
        for (index, source) in displaySources.enumerated() {
            // 源之间有分隔线（第一个源前不加）
            if index > 0 {
                menu.addItem(.separator())
            }

            let item = NSMenuItem()
            let view: AnyView

            if let snapshot = source.snapshot {
                switch snapshot {
                case .quota(let quotaSnapshot):
                    view = AnyView(SourceQuotaSection(source: source, snapshot: quotaSnapshot))
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
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = "Zenmonitor 设置"
            win.contentView = NSHostingView(rootView: SettingsView())
            win.minSize = NSSize(width: 420, height: 300)
            win.center()
            win.isReleasedWhenClosed = false
            win.delegate = self
            settingsWindow = win
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard !isShuttingDown else { return }
        sizeObservers.forEach { $0.stop() }
        sizeObservers.removeAll()
        menu.removeAllItems()
    }

    func windowWillClose(_ notification: Notification) {
        guard !isShuttingDown else { return }
        if let win = notification.object as? NSWindow, win == settingsWindow {
            win.contentView = nil
            settingsWindow = nil
        }
    }

    private func performShutdownCleanup() {
        isShuttingDown = true
        // 清理每个源的回调
        registry.sources.forEach { source in
            if let zenmux = source as? ZenmuxAPIService {
                zenmux.onStateChange = nil
                zenmux.cleanup()
            }
        }
        statusItem?.menu?.delegate = nil
        statusItem?.menu?.removeAllItems()

        if let win = settingsWindow {
            win.orderOut(nil)
            win.contentView = nil
            win.delegate = nil
            settingsWindow = nil
        }

        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
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
        observation = hostingView?.observe(\.intrinsicContentSize, options: [.new]) { [weak self] view, _ in
            guard let self else { return }
            let newSize = view.fittingSize
            // 仅在高度发生明显变化时更新，避免无意义的重排
            guard abs(newSize.height - view.frame.height) > 1 else { return }
            view.frame = NSRect(x: 0, y: 0, width: self.menuContentWidth, height: newSize.height)
            // 延迟到下一 runloop 触发菜单重排，确保 frame 更先生效
            DispatchQueue.main.async { [weak self] in
                self?.menu?.update()
            }
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
    }
}

// MARK: - 菜单栏自定义绘制视图

final class StatusBarView: NSView {
    weak var registry: SourceRegistry?

    private static let percentFont = NSFont.monospacedDigitSystemFont(ofSize: 9.2, weight: .regular)
    private static let pausedFont = NSFont.systemFont(ofSize: 7)
    private static let normalLeadingInset: CGFloat = 1.2
    private static let normalTrailingInset: CGFloat = 0.2
    private static let barTextGap: CGFloat = 0.4

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
        NSSize(width: 49, height: 22)
    }

    func renderedImage() -> NSImage {
        let bounds = NSRect(origin: .zero, size: intrinsicContentSize)
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else {
            return NSImage(size: intrinsicContentSize)
        }

        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: intrinsicContentSize)
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // 从主配额源读取快照
        guard let source = registry?.primaryQuotaSource,
              let snapshot = source.snapshot,
              case .quota(let quotaSnapshot) = snapshot,
              quotaSnapshot.windows.count >= 2 else {
            drawPlaceholder()
            return
        }

        // Zenmux 特有：检查暂停状态（通过协议扩展或类型判断）
        if let zenmux = source as? ZenmuxAPIService, zenmux.isPaused {
            drawPaused(quotaSnapshot)
            return
        }

        let palette = currentPalette
        let layout = normalLayoutMetrics

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

    private func drawPlaceholder() {
        let palette = currentPalette
        let barH: CGFloat = 4.5
        let topY = bounds.height - barH - 5
        let bottomY = topY - barH - 4
        drawDimmedBar(x: 4, y: topY, width: 24, height: barH, pct: 0.45, palette: palette)
        drawDimmedBar(x: 4, y: bottomY, width: 24, height: barH, pct: 0.7, palette: palette)

        // 任一源有错误时显示 "!"
        if registry?.sources.contains(where: { $0.lastError != nil }) == true {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 9),
                .foregroundColor: NSColor.black
            ]
            "!".draw(at: NSPoint(x: bounds.width - 10, y: 2), withAttributes: attrs)
        }
    }

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
        Palette(
            barBackground: NSColor.black.withAlphaComponent(0.18),
            pausedBackground: NSColor.black.withAlphaComponent(0.12),
            pausedFill: NSColor.black.withAlphaComponent(0.28),
            lowUsage: NSColor.black.withAlphaComponent(0.58),
            midUsage: NSColor.black.withAlphaComponent(0.76),
            highUsage: NSColor.black.withAlphaComponent(0.94),
            primaryText: NSColor.black,
            secondaryText: NSColor.black.withAlphaComponent(0.55)
        )
    }

    private var normalLayoutMetrics: (barX: CGFloat, barWidth: CGFloat, barRightEdge: CGFloat, textRightEdge: CGFloat) {
        let leadingInset = Self.normalLeadingInset
        let trailingInset = Self.normalTrailingInset
        let gap = Self.barTextGap
        let textWidth = Self.percentTextReserveWidth
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 源头部：Logo + 名称 + 状态点 + 状态文字（统一为一行）
            HStack(spacing: 8) {
                // Logo
                if let logoName = source.logoImageName {
                    Image(logoName)
                        .resizable()
                        .frame(width: 20, height: 20)
                } else if let appIcon = NSApp.applicationIconImage {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 20, height: 20)
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
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            // 配额窗口列表（5h / 7d / ...）
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
                        projectedPct: window.projectedPct
                    )
                }
            }
            .padding(.horizontal, 12)

            // 补充指标卡片（月度上限 / 汇率）
            if !snapshot.extraMetrics.isEmpty {
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
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.06))  // 主源用深色背景
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
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
            RoundedRectangle(cornerRadius: 12, style: .continuous)
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

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                HStack(spacing: 2) {
                    Image(systemName: icon)
                        .font(.subheadline.weight(.medium))
                    Text(label)
                        .font(.subheadline.weight(.medium))
                    // 时间进度百分比：紧随标签，色与标签一致
                    if resetsAt != nil {
                        Text("\(timePercentStr)")
                            .font(.subheadline.weight(.regular))
                    }
                }
                .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f%%", pct * 100))
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

            HStack {
                Text(usedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // 合并 USD 和重置时间为一行，减少视觉跳跃
                HStack(spacing: 6) {
                    if let usdText = usedUSDText {
                        Text(usdText)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if let reset = resetsAt {
                        Text("· \(formatReset(reset))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }

    private static let resetFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE MM/dd HH:mm"; return f
    }()

    private func formatReset(_ date: Date) -> String {
        Self.resetFmt.string(from: date)
    }

    /// 时间占比百分比字符串，如 " · 45%"
    private var timePercentStr: String {
        guard let end = resetsAt else { return "" }
        let now = Date()
        guard now < end else { return " · 100%" }
        let start = end.addingTimeInterval(-windowDuration)
        let f = now.timeIntervalSince(start) / windowDuration
        let p = Int(min(max(f, 0), 1) * 100)
        return " · \(p)%"
    }

    private var progressColor: Color {
        UsagePalette.color(for: pct)
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

/// 余额型源（DeepSeek）的菜单区块：标题 + 总余额 + 明细
struct SourceBalanceSection: View {
    let source: any MonitoredSource
    let snapshot: BalanceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 源头部：Logo + 名称（与配额区块样式统一）
            HStack(spacing: 8) {
                // Logo
                if let logoName = source.logoImageName {
                    Image(logoName)
                        .resizable()
                        .frame(width: 20, height: 20)
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

            // 余额内容：大数字 + 明细
            VStack(alignment: .leading, spacing: 8) {
                // 总余额（大数字）
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(snapshot.currencySymbol)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(snapshot.total)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                }

                // 明细（赠金/充值）
                HStack(spacing: 12) {
                    ForEach(Array(snapshot.breakdown.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 4) {
                            Text(item.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(snapshot.currencySymbol)\(item.value)")
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.03))  // 次要源用浅色背景
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
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
                    .foregroundStyle(Color(red: 0.90, green: 0.34, blue: 0.31))
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
        .padding(.vertical, 20)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
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
