# Changelog

All notable changes to TartR are documented here.

## 4.11.0 - 2026-07-20

### Added

- 正式发布构建支持手动检查更新和可关闭的每日自动检查，本地构建默认不联网
- GitHub Release 自动注入实际仓库的稳定 manifest 地址并发布 `TartR-update.json`
- 更新提示提供 DMG 下载、发布说明和完整 SHA-256，但不会自动下载、安装或执行代码
- Mac 从睡眠唤醒后立即恢复 Tart 状态同步，并在检查周期到期时查询更新

### Fixed

- 更新 manifest 严格限制为 1 MB、HTTPS、无内嵌凭据、合法版本、DMG 地址及 64 字符 SHA-256
- 版本比较统一处理 `v` 前缀、缺省尾部零和最多四段数字，拒绝预发布或畸形版本
- CI 和 Release 都生成并验证更新 manifest，DMG 校验和不匹配时不会发布

## 4.10.0 - 2026-07-20

### Added

- 状态摘要持续显示 Tart VM 所在宿主卷的可用磁盘空间，低于 15 GB 时以橙色提示
- 下载镜像、从 IPSW 创建 VM、创建 Linux VM、导入和导出归档前执行目标卷容量预检
- 容量估算额外保留 5 GB 安全空间，不足时可取消、明确覆盖或直接进入 Tart 缓存清理

### Fixed

- 导入归档按压缩文件两倍且至少 20 GB 估算，导出归档使用 Tart 报告的实际 VM 占用
- 容量查询不可用时保持兼容并允许继续，整数计算溢出时按空间不足安全处理

## 4.9.0 - 2026-07-20

### Added

- 可从缺失提示或 TartR 菜单选择任意可信位置的 Tart 可执行文件，并在本机记住路径
- 自定义路径优先于 `TART_EXECUTABLE`、Homebrew 和 `~/.local/bin`，可一键恢复自动检测
- 运行环境和隐私安全诊断报告会显示实际使用路径以及自定义路径回退状态

### Fixed

- 保存自定义路径前执行可取消的 `tart --version` 探测，并在 5 秒后强制回收无响应进程
- 拒绝无执行权限、版本输出无效或探测失败的文件，避免错误路径导致持续状态同步失败
- Tart 不可用时，任务结束不会错误地重新启用“更多操作”按钮
- App 签名和 ZIP 打包改在系统临时目录完成，避免 Documents 文件提供器写入 FinderInfo 导致构建偶发失败

## 4.8.0 - 2026-07-20

### Added

- 虚拟机列表支持 Shift/Command 多选，可批量启动和停止符合当前状态的 VM
- 可一次移除多条本地不存在的保存记录，并明确保证不会删除 VM 磁盘
- 批量按钮显示实际可操作数量，状态摘要显示当前选择数量
- 多选在状态刷新、排序和运行状态变化后仍能保持

### Fixed

- 多选时自动禁用日志、重命名、配置、归档和永久删除磁盘等单机操作，避免误操作第一条记录
- 批量启动会跳过未知、缺失或已运行条目，批量停止会跳过已停止或正在停止条目

## 4.7.0 - 2026-07-20

### Added

- 退出时可选择让 TartR 启动的 VM 继续在后台运行，重新打开 App 后会自动同步并继续管理
- 长任务尚未完成时提供明确的退出确认，避免意外取消克隆、导入或推送操作
- 记忆主窗口位置、大小和虚拟机表格列布局
- 为搜索、手动添加、虚拟机列表和自动启动复选框补充 VoiceOver 标签

### Fixed

- 退出期间不再由延迟的状态同步或任务回调重新启动 VM、弹出结果提示或创建新同步进程
- 分离后台 VM 时仅终止同步和修改任务，不会误杀选择保留的 `tart run` 进程

## 4.6.0 - 2026-07-20

### Added

- 生成带有 Applications 快捷方式的压缩只读 DMG，支持标准拖放安装
- DMG 具备独立代码签名、SHA-256、磁盘镜像完整性、双架构和内置 App 校验
- 可从 TartR 菜单启用或关闭 macOS 原生“登录时启动”，需要批准时直达系统设置
- CI 同时构建、验证并保留 ZIP 与 DMG，Release 同时发布两种安装介质

### Fixed

- DMG 和公证暂存目录移出 Documents/云盘范围，避免 FinderInfo 污染 App 签名
- 正式发布会分别公证并装订 App 与 DMG，且对外层 DMG 执行 Gatekeeper 评估

## 4.5.0 - 2026-07-20

### Added

- 将全部 VM 名称、自动启动和运行选项导出为版本化 JSON 设置文件，并支持安全导入
- 应用内显示 TartR、macOS、CPU 架构、Tart 版本、可执行文件路径和同步状态
- VM 配置详情改用可选择、可滚动、可一键复制的文本查看器
- 设置导入具备格式版本、重复 ID、重复名称、非法名称和 5 MB 大小限制校验

### Fixed

- 有 TartR 管理的 VM 或长任务运行时禁止替换设置，避免丢失进程控制关系
- 公证脚本在上传前强制检查 Developer ID Application、时间戳和 Hardened Runtime
- 公证完成后额外执行 Gatekeeper 评估，失败的包不会继续发布
- CI/Release 增加并发控制、执行超时、签名身份匹配及缺失凭据预检
- 公证在无扩展属性的隔离副本上进行，避免 Finder 或云盘元数据污染签名验证

## 4.4.0 - 2026-07-20

### Added

- 为每台 VM 保存独立的无图形、禁用音频、禁用剪贴板和可挂起启动选项
- 启动按钮、双击启动与自动启动统一使用每台 VM 保存的启动配置
- VM 配置数据保留最近一次有效备份，损坏时自动恢复并保留原始数据
- 自动清理超过 24 小时的 TartR 临时命令输出文件
- CPU、内存、显示分辨率和磁盘大小的本地输入校验
- CI 安装当前 Tart 版本并验证 TartR 使用的全部子命令和选项仍然兼容

### Fixed

- 旧版本 VM 配置缺少新字段时可以无损迁移，不会因解码失败丢失保存列表
- Intel Mac 不再提供 Tart 不支持的可挂起启动入口或参数

## 4.3.0 - 2026-07-20

### Added

- 使用 `.tvm` 归档离线导入和导出本地虚拟机
- 可从应用菜单导出隐私安全的运行环境诊断报告
- 支持 macOS 安全窗口状态恢复声明

### Fixed

- 为 `tart list` 状态同步增加 15 秒超时、优雅中断和强制回收，避免界面永久停留在同步中
- 退出应用时跟踪并回收正在运行的状态同步子进程
- 非用户发起的信号中断不再被静默忽略，而是显示明确的任务失败信息

## 4.2.0 - 2026-07-20

### Added

- 虚拟机名称搜索，以及名称、状态、磁盘、实际占用排序
- `tart get --format json` 详细配置查看
- OCI Registry 推送与明确的网络流量确认
- 仅针对可重新下载 OCI/IPSW 数据的缓存清理
- 下载、推送和创建任务的实时尾部进度显示
- VM 列表投影与排序单元测试

### Fixed

- 使用 SIGINT 等价模拟前台 Ctrl-C，确保 Tart 正常关闭 VM
- 状态同步失败时不再继续执行可能重复的 `tart run`
- 消除长任务启动前的重复提交竞态
- 取消长任务后不再误报操作成功或失败，并在必要时强制回收未响应进程
- 状态未变化时不再每五秒重建整个表格，减少闪烁并改善辅助功能稳定性

## 4.1.0 - 2026-07-20

### Added

- Ubuntu、Debian 和 Fedora 官方 Linux 镜像
- 可编辑的自定义 OCI 镜像地址与特定 tag 支持
- 使用临时钥匙串、Developer ID、Apple 公证和 GitHub Release 的标签发布流水线
- 自动派生版本号的二进制与源码归档脚本

### Fixed

- 避免将正常关闭、外部停止或挂起后的 `tart run` 退出误报为启动失败
- Intel 构建只展示兼容的 Linux 镜像
- 从旧 `local.caiyagang.*` bundle ID 自动迁移虚拟机与选择偏好

### Changed

- 生产 bundle ID 稳定为 `com.caiyagang.tartr`
- Release 版本提升至 4.1.0

## 4.0.0 - 2026-07-20

### Added

- Production Swift Package with a reusable `TartRCore` module
- Automatic Tart installation guidance and official quick-start link
- Built-in catalog of 15 official Cirrus Labs macOS images
- Clone, rename, delete, configure, IP, suspend, macOS create and Linux create actions
- VM disk capacity and allocated-size display
- Universal arm64/x86_64 release build
- Developer ID signing, notarization and checksum scripts
- Core unit tests and CI workflow

### Changed

- VM state is sourced from `tart list --source local --format json`
- Tart is invoked directly from known paths; login-shell resolution is fallback-only
- Polling interval is five seconds and refreshes immediately when the app becomes active
- Command output uses bounded temporary files to avoid pipe EOF and buffer deadlocks

### Security

- Destructive deletion now requires typing the exact VM name
- Tart arguments remain separated from shell interpretation
- Application and per-VM logs rotate automatically
