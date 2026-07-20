# Changelog

All notable changes to TartR are documented here.

## 4.16.1 - 2026-07-20

### Fixed

- Homebrew 6 要求显式信任 Tart 的 `softnet` 依赖；安装引导现在只信任该具体官方 formula 后再安装 Tart
- CI 和 Release 共用版本化安装脚本，避免 Homebrew tap 信任策略变化导致单元测试通过后构建中断
- 不使用 `HOMEBREW_NO_REQUIRE_TAP_TRUST`，也不信任整个 Cirrus Labs tap，保持最小供应链授权范围

### Verified

- 从 Homebrew formula 固定 URL 下载 Tart 2.32.1 官方归档并通过发布 SHA-256 校验
- 使用真实 Tart 2.32.1 二进制完成全部 CLI 帮助兼容检查，包括 `tart exec`

## 4.16.0 - 2026-07-20

### Added

- 运行中的单台 VM 可通过 Tart Guest Agent 执行非交互式 Shell 命令，并在可复制文本窗口查看完整结果
- 命令使用 `tart exec <VM> /bin/zsh -lc <命令>` 的独立参数调用，仅在客体 VM 中执行，不经过宿主机 shell
- 命令输入限制为 4096 字节且拒绝空命令和空字符；输出继续使用 1 MB 有界采集
- CLI 兼容检查新增 `tart exec`，当前 Tart 不支持该命令时 Release 会停止

### Fixed

- 多选或 VM 未运行时禁用客体命令入口，macOS 13 上明确提示 `tart exec` 需要 macOS 14 或更高版本
- 命令失败不再只显示短错误提示，可查看和复制客体标准输出、标准错误及截断标记
- 客体命令文本和输出不会写入 TartR 应用日志，避免意外持久化令牌或其他敏感结果

## 4.15.0 - 2026-07-20

### Added

- 正式发布构建支持在 App 内选择保存位置、下载并验证更新 DMG，下载进度可见且可取消
- 更新 manifest 在保持 schema 1 向后兼容的同时新增 `fileSize`，旧版可忽略、新版用于精确限制下载大小
- 下载完成后流式计算 SHA-256，并在系统临时文件和最终同卷暂存文件上进行两次大小与校验和验证
- 验证成功后可选择打开 DMG 或在 Finder 显示，TartR 仍不会自动安装或执行更新

### Fixed

- Manifest 和 DMG 下载只允许 HTTPS 且无内嵌凭据的初始地址、重定向地址和最终响应地址
- 更新包严格限制为 manifest 声明大小且不超过 512 MB；大小、哈希或响应不符时不保存目标 DMG
- 更新下载期间禁用冲突的 Tart 操作、设置导入和可执行文件切换，退出或用户取消时安全终止下载

## 4.14.0 - 2026-07-20

### Added

- 新增打包 App 自动化冒烟测试，从发布 ZIP 解包并验证签名后真实启动 AppKit 应用
- 冒烟测试同时覆盖外部已运行和已停止的自动启动 VM，确认只启动后者且两台 VM 都不会重复执行 `tart run`
- 再次打开相同 App 时验证进程 PID 不变且立即再次同步状态，覆盖单实例重开路径
- CI 和 Release 在构建后、公证前自动运行 `make smoke`，打包层或 App 启动回归会阻止发布

### Fixed

- 冒烟测试使用独立 HOME、CFPreferences、假 Tart 状态和日志目录，不读取或修改用户真实配置
- 假 Tart fixture 不再共享固定 `/tmp` 状态，连续或并行测试之间不会互相污染
- ZIP 发布校验迁移到系统临时目录并主动清除扩展属性，避免文件提供器写入 FinderInfo 导致签名验证竞态

## 4.13.0 - 2026-07-20

### Added

- 新增可复用的有界进程输出采集器，持续排空 Tart 标准输出和错误输出并保留最近 1 MB
- 长时间克隆、推送、创建和导入任务继续实时显示最新进度，不再依赖持续增长的临时输出文件
- 为小输出完整保留及 2 MB 连续输出截断、无死锁排空增加自动化回归测试

### Fixed

- 状态同步、停止、版本验证和通用 Tart 操作不再在结束时把完整临时文件一次性读入内存
- `tart list` 输出超过安全上限时明确拒绝本次同步，避免用不完整 JSON 覆盖正确 VM 状态
- 被截断的诊断输出带有明确省略标记，错误提示和应用日志仍保留最新上下文

## 4.12.1 - 2026-07-20

### Fixed

- 本地与 CI 构建只把 ZIP、DMG 和源码包作为发布工件，避免文件提供器向裸 `.app` 写入 FinderInfo 后破坏严格签名校验
- DMG 和公证流程统一从已校验的 ZIP 解包到系统临时目录，并在使用前清除扩展属性、重新验证 App 签名
- 不再让公证或 DMG 打包依赖工作区中的裸 App，云盘同步不会污染正式归档
- 源码包版本改为从指定 Git ref 内的 plist 派生，避免未提交版本号造成文件名与归档内容不一致

## 4.12.0 - 2026-07-20

### Added

- 运行中的单台 VM 可一键获取地址、复制 SSH 命令并打开 Terminal，命令仍由用户确认后手动执行
- 每台 VM 独立记忆 SSH 用户名；旧配置无损迁移并默认使用 `admin`
- SSH 命令支持严格校验的 IPv4、IPv6 和 DNS 主机名，IPv6 使用 OpenSSH 原生的 `-l` 用户参数形式

### Fixed

- SSH 用户名、Tart 返回地址及导入设置均拒绝空白、选项、命令替换、分号和其他注入字符
- 多选 VM 时禁用 SSH 单机操作，避免在选择不明确时生成错误连接命令
- TartR 只向剪贴板写入验证后的 SSH 命令并打开 Terminal，不通过 shell 或 AppleScript 自动执行

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
