# Zenmonitor

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/platform-macOS%2015.0%2B-blue.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org/)
[![GitHub release](https://img.shields.io/github/v/release/jianxing-chen/zenmonitor)](https://github.com/jianxing-chen/zenmonitor/releases)

macOS 菜单栏多源监控工具，实时显示各类 API 服务的用量配额与余额。

## ✨ 功能特性

- **多源监控**：支持 Zenmux（配额型）、DeepSeek（余额型）、Kimi Code（配额型）三个 API 服务，架构可随时扩展新源
- **每源独立状态栏项**：各源可在设置中独立开关自己的菜单栏项——Zenmux 双进度条、DeepSeek 余额文本（¥xx.xx）、Kimi 进度条+品牌徽章；全部关闭时保留 App Logo 入口，永不失联
- **多显示器自适应**：状态栏图标采用系统模板着色，每块屏幕的菜单栏深/浅外观自动适配，无需手动切换
- **重置时间提示**：配额窗口行内显示重置时间（如「5H · Sun 08/17 03:00」），下拉面板颜色随用量变化（蓝→橙→红）
- **7 天用量预测阴影**：7 天进度条上叠加半透明阴影，表示「若 5 小时用量被用满，7 天用量将达到的位置」；阴影颜色按预测值判档，提前预警
- **DeepSeek 余额与今日用量**：下拉面板显示总余额与本地差值推算的今日用量（整点采样，充值自动重置基线）
- **Kimi Code 配额**：5 小时滚动频控 + 7 天周额度双窗口，品牌 Logo 标识
- **下拉详情可折叠**：Zenmux 区块默认只展示核心指标，一键展开 flows / USD / 月度上限 / 汇率完整信息
- **区块排序**：在设置面板直接拖动源卡片，即可调整下拉面板各区块顺序，即时生效
- **暂停/继续**：菜单内一键暂停或恢复自动刷新
- **本地设置保存**：API Key 与所有配置持久化在应用本地
- **纯菜单栏运行**：无 Dock 图标，无窗口，极低资源占用

## 📸 截图

<img src="screenshot.png" width="320" alt="Zenmonitor 截图" />

> 截图仅为软件界面示意，图中数据均为虚例。

## 🚀 安装

### 方式一：下载预编译版本（推荐）

1. 从 [Releases](../../releases) 下载最新版 `Zenmonitor-vX.X.zip`
2. 解压后拖 `Zenmonitor.app` 到 `/Applications`
3. 首次打开：**右键 App → 打开**（Ad Hoc 签名需绕过 Gatekeeper）
4. 之后可在系统设置 → 通用 → 登录项 中设为开机自启

### 方式二：自行编译

```bash
git clone https://github.com/jianxing-chen/zenmonitor.git
cd zenmonitor
open Zenmonitor.xcodeproj
```

Cmd+R 运行，Cmd+B 编译。

## ⚙️ 配置

1. 点击菜单栏图标 → **设置**
2. 配置各源 API Key（每张源卡片还可开关「在菜单栏显示」并拖动排序）：
   - **Zenmux**：[控制台](https://zenmux.ai/platform/management) 创建 Management API Key
   - **DeepSeek**：[控制台](https://platform.deepseek.com/api_keys) 创建 API Key（用于余额查询与今日用量统计）
   - **Kimi Code**：[控制台](https://www.kimi.com/code/console) 创建 API Key（sk-kimi- 开头）
3. 所有 Key 仅保存在本机（UserDefaults 明文，详见 DEVELOPMENT 权衡说明），不上传任何服务器

## 🏗️ 架构

```
MonitoredSource 协议（sourceID/displayName/snapshot/refresh/onStateChange）
        ↓
SourceSnapshot 统一快照（.quota / .balance）
        ↓
SourceRegistry 注册中心（sources/orderedSources/refreshAll）
        ↓
状态栏：每源独立 NSStatusItem + 模板图自绘位图
下拉面板：SourceQuotaSection / SourceBalanceSection 按用户排序渲染
```

**添加新源**：
1. 新建 `Services/YourAPIService.swift`，实现 `MonitoredSource` 协议
2. 在 `SourceRegistry.init()` 中注册：`sources.append(YourAPIService.shared)`
3. 新建 `Views/YourSourceCard.swift`（设置界面配置卡片）
4. 在 `SettingsView.sourceCard(for:)` 中加 case `"your-source"`

无需改动 `AppDelegate` / `StatusBarView` / 菜单构建逻辑，全部自动适配。

## 📋 系统要求

- macOS 15.0+
- Apple Silicon / Intel（通用二进制）

## 📊 资源占用

- 内存：空闲 ~20MB，菜单打开时 ~30MB
- CPU：空闲时 < 0.1%，无轮询时 ≈ 0%
- 网络：Zenmux 按设置间隔自动刷新；DeepSeek/Kimi 菜单打开时拉取，另有 DeepSeek 整点余额采样

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 License

[MIT](LICENSE) © jianxing-chen
