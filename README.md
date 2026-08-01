# Zenmonitor

macOS 菜单栏多源监控工具，实时显示各类 API 服务的用量配额与余额。

## 功能

- **多源监控**：支持 Zenmux（配额型）、DeepSeek（余额型）等多个 API 服务，可随时扩展新源
- **双进度条**：菜单栏直接显示主源 5 小时 / 7 天滚动窗口用量，菜单栏深浅随用量变化，下拉面板颜色随用量变化（蓝→橙→红），带精确百分比
- **重置时间百分比**：标签后紧跟当前时间在滚动周期内的占比（如「5 小时用量 · 45%」），纯时间标度与用量进度相互独立
- **7 天用量预测阴影**：7 天进度条上叠加半透明阴影，表示「若 5 小时用量被用满，7 天用量将达到的位置」——当前 7d 用量 + 5h 剩余可用量，露出主条右侧部分即预测增量；阴影颜色按预测值判档，提前预警（预测进入中/高档时阴影提前变橙/红）；5h 用满时预测=实际，阴影与主条重合不可见
- **DeepSeek 余额**：下拉面板独立区块显示 DeepSeek 账户余额（总余额、赠金、充值明细，支持 CNY/USD 多币种）；菜单打开时拉取，仅在设置中配置 DeepSeek API Key 后显示
- **下拉详情**：点击菜单栏图标展开完整用量面板（flows、USD、汇率、月度上限、到期时间）
- **暂停/继续**：菜单内一键暂停或恢复自动刷新
- **本地设置保存**：API Key 与所有配置持久化在应用本地
- **纯菜单栏运行**：无 Dock 图标，无窗口，极低资源占用

## 截图

<img src="screenshot.png" width="320" alt="Zenmonitor 截图" />

> 截图仅为软件界面示意，图中数据均为虚例。

## 安装

1. 从 [Releases](../../releases) 下载 `Zenmonitor.zip`
2. 解压后拖 `Zenmonitor.app` 到 `/Applications`
3. 首次打开：**右键 App → 打开**（Ad Hoc 签名需绕过 Gatekeeper）
4. 之后可在系统设置 → 通用 → 登录项 中设为开机自启

## 配置

1. 点击菜单栏图标 → **设置**
2. 配置 Zenmux API Key：
   - 前往 [Zenmux 控制台](https://zenmux.ai/platform/management) 创建 **Management API Key**
   - 粘贴到设置窗口 → 保存
3. （可选）配置 DeepSeek API Key：
   - 前往 [DeepSeek 控制台](https://platform.deepseek.com/api_keys) 创建 API Key
   - 粘贴到设置窗口 → 保存

## 系统要求

- macOS 15.0+
- Apple Silicon / Intel（通用二进制）

## 资源占用

- 内存：空闲 ~20MB，菜单打开时 ~30MB
- CPU：空闲时 < 0.1%，无轮询时 ≈ 0%
- 网络：主源每 60s 一次小请求，DeepSeek 菜单打开时拉取

## 开发

```bash
git clone https://github.com/jianxing-chen/zenmonitor.git
cd zenmonitor
open Zenmonitor.xcodeproj
```

Cmd+R 运行，Cmd+B 编译。

## License

MIT
