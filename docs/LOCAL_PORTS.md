# 本地功能移植：BoDian / RightSight

本地来源：`/Users/song/AIProject/BoDian`、`/Users/song/AIProject/RightSight`。原项目未修改。本文的“已有”由仓库源码与调用入口核对得出，不代表所有硬件/系统上的运行行为已经验证。

## 功能对照与实现归属

| 来源功能 | Vorssaint 原有能力 | 本次处理 |
| --- | --- | --- |
| 电池电量、充放电状态、实时功率 | PowerSampler / 系统监视器 | 保留，不新增第二套系统监视器 |
| 充电上限、暂停/恢复、本次充满、接线使用电池、自动结束阈值 | 无充电策略写入模块 | 移入 BoDian 的纯策略、原生后台与签名校验客户端 |
| 分钟 Wh、覆盖率、7 天历史、三个时间范围、CSV | 原有实时图表不提供该持久统计 | 移入能量积分、SQLite 与历史窗口；保留原采样时效及睡眠断段规则 |
| Finder 剪切粘贴 | FinderCutPaste | 菜单调用同一剪切状态、剪贴板和移动引擎 |
| 复制到指定目录且重名编号 | 无相同复制入口 | 从 RightSight 移入复制算法；不复制它的移动引擎 |
| JPG/PNG 批量转换 | MediaService | 复用；菜单原图保留，使用不覆盖输出的服务实例 |
| WebP 输出 | 无，原有支持 JPEG/PNG/HEIC/PDF | 在 MediaService 增加 Google libwebp 编码；输出保留透明度，重新编码时不保留 EXIF/XMP |
| Finder 右键菜单、应用参数/环境变量、模板、常用目录 | 无 FinderSync 扩展 | 新增薄扩展，主程序执行操作；移入原项目文件操作行为 |
| 设置导入/导出/恢复 | 全应用已有备份 | 菜单配置纳入原备份；另提供菜单设置单独导入/导出与恢复 |
| Office/PDF 预置模板 | 原有仅内置 txt/md | 预置符合规范的 Word (.docx)、Excel (.xlsx)、PowerPoint (.pptx)、PDF (.pdf) 等 6 种模板，支持一键恢复默认 |
| Dock 悬停预览与多标签页 | 原有单窗口且大灰边 | 重构为 Windows 11 / DockDoor 紧凑卡片（去灰边、去遮挡大徽标、顶部红底叉关闭）；支持 Chrome/Safari 等浏览器多标签页独立枚举与切换 |
| Dock 图标点击控制 | dockClick 原生能力 | 点击前台 App 的 Dock 图标最小化/还原窗口，支持全桌面跨 Space 预览 |

## 使用入口

设置 → 功能中按需安装“充电控制”“电池能量历史”“Finder 右键菜单”。三者默认关闭。

“充电控制”“电池能量历史”位于能耗分类；“Finder 右键菜单”位于文件分类。菜单中的剪切/粘贴/移动依赖已安装的原有“剪切和粘贴”功能，图片转换依赖已安装的“媒体”功能。关闭依赖后菜单隐藏相应项目，主程序也拒绝过时的请求。

模板导入后保存内容副本（每个最多 10 MB），重命名后提交或离开页面保存。已有文件不会被模板覆盖。系统目录与用户根目录等沿用 RightSight 的保护范围。直接删除会永久移除所选项目，需在应用确认框确认。

## 系统与后台边界

- 主程序仍以 **macOS 14 / Apple Silicon** 为最低目标；充电控制的 UI、命令入口和原生 helper 均限制在 macOS 27+，还需内置电池。
- 充电后台仅从 `/Applications/Vorssaint.app` 授权；使用独立 `com.vorssaint.utils.charge` 服务、`/Library/Application Support/Vorssaint/Charging` 数据与本构建代码哈希。开发变体不能借用正式构建的授权。
- 启用前检查 `com.bodian.charge`；运行时必须先在泊电中恢复系统管理并停用后台。不要同时启用其他充电控制器。
- 退出 GUI 保留充电后台；卸载充电功能先恢复系统管理并注销后台，失败时恢复功能入口，避免隐藏仍在控制的后台。
- 重新构建/更新前应先恢复系统管理并停用后台，更新后重新授权；不导入泊电的旧授权或历史数据库。临时签名不保证整机重启后的后台批准状态。私有充电机制的固件边界继承 BoDian，不能以编译通过推断硬件支持。
- 历史记录位于当前用户 `~/Library/Application Support/Vorssaint/energy.sqlite`，默认保留 7 天。卸载历史功能停止采集并保留数据；退出 GUI 停止采集。CSV 是电池端估算 Wh，不能当作整机耗电。
- Finder 扩展需在系统设置中允许。iCloud 等 File Provider 路径不保证提供 FinderSync 菜单。权限仅在使用相关功能时由系统询问。
- 扩展与主程序通过普通偏好域（`com.vorssaint.utils`）中的随机密钥认证请求，沙盒扩展通过只读共享偏好临时例外（`com.apple.security.temporary-exception.shared-preference.read-only`）读取；扩展把 HMAC 签名的请求经自定义 URL scheme 交给主程序（沙盒禁止扩展发送带 userInfo 的分布式通知，已实测）；密钥、后台授权和能量数据不进入设置备份。开发变体使用独立偏好域与 URL scheme。

## 构建与验证

```sh
git submodule update --init Dependencies/libwebp
./build.sh
./build/Vorssaint --selftest
zsh Tools/test-ports.sh
./build.sh --test-suite=features
./build.sh --test-suite=settings
./build.sh --test-suite=media
./build.sh --test-suite=storage
./build.sh --test-suite=preferences
```

libwebp 固定至官方 v1.6.0，通过上游 makefile.unix 按 macOS 14 目标静态构建，无需用户电脑安装 Homebrew 或外部编码程序。许可证随应用打包。`Package.swift` 只服务于索引，实际扩展、helper、静态库与签名由 build.sh 组装。

验证记录另见本次交付说明。真实充电切换、后台批准/重启以及 Finder 实际右键调用必须单独记录；自检、纯策略测试和注册成功均不能替代这些运行时验证。

## 许可

RightSight 源自 GPL-3.0 RClick，相关声明见 RIGHTSIGHT_NOTICE.md。BoDian 原生策略使用的第三方 MIT 声明见 BODIAN_NOTICES.md 和 Resources/Licenses/BoDian。Google libwebp 的 BSD 许可见 Resources/Licenses/libwebp.txt。

## 签名诊断

安装包中的同一主程序可使用 `--local-port-status` 检查支持范围、功能开关与偏好配置就绪状态；`--battery-energy-report` 汇总实际历史记录。`--charge-command status|pause|resume|limit N|topup|restore|battery|floor N` 使用与界面相同的签名 XPC，不另建权限通道。更新前可通过旧版已授权程序执行 `--charge-command restore`，再在界面停用后台。

Finder 菜单配置与随机认证密钥通过 CFPreferences 存储在应用偏好域中，扩展利用精确只读偏好例外读取，不依赖受限的 App Group 容器。Finder 会在自身进程重建扩展菜单项，回调时只保留 `tag`，`representedObject` 丢失；因此扩展按 tag 保存每个菜单项的动作与路径快照。所有本地签名路径均包含声明的 entitlements。
