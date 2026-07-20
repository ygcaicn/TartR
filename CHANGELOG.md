# Changelog

All notable changes to TartR are documented here.

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
