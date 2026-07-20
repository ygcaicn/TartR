# TartR

TartR 是一个原生 macOS Tart 虚拟机管理器。它提供实时状态同步、官方镜像下载和常见虚拟机操作，同时保留 Tart CLI 的可预测行为。

## 功能

- 自动发现本地 Tart VM，并同步运行、停止和挂起状态
- 支持 Shift/Command 多选并批量启动、停止或移除失效记录
- 防止对已运行 VM 重复执行 `tart run`
- 管理由 TartR 或外部终端启动的 VM
- 退出 TartR 时可选择停止托管 VM，或让它们继续在后台运行并在下次打开时重新接管
- 内置 15 个 Cirrus Labs macOS 镜像（Tahoe 至 Monterey）和 3 个 Linux 镜像
- 支持编辑 OCI 地址，可下载官方目录之外的 Tart 镜像和特定 tag
- 下载远程镜像、复制本地 VM、重命名和永久删除
- 显示宿主卷可用空间，并在下载、创建和归档操作前进行带安全余量的容量预检
- 使用 `.tvm` 文件离线备份和恢复本地 VM
- 调整 CPU、内存、显示分辨率和磁盘大小
- 获取 IP、普通启动、可挂起模式启动、停止和挂起
- 为运行中的 VM 复制安全的 SSH 命令并打开 Terminal，且分别记忆每台 VM 的 SSH 用户名
- 通过 Tart Guest Agent 在运行中的 VM 内执行非交互式 Shell 命令并查看、复制输出
- 为每台 VM 记忆无图形、音频、剪贴板和可挂起启动选项，自动启动沿用相同配置
- 查看完整 VM 配置，并按名称搜索或按状态、磁盘和占用排序
- 推送本地 VM 到 OCI Registry，安全清理可重新下载的 OCI/IPSW 缓存
- 从最新 IPSW 创建 macOS VM，或创建空白 Linux VM
- 每台 VM 可配置打开 TartR 时自动启动
- 可使用 macOS 原生登录项让 TartR 在用户登录时启动
- 正式发布构建支持手动或每日自动检查 HTTPS 更新，并在 App 内下载、校验 DMG
- Tart 缺失时显示 Homebrew 安装引导
- 支持选择并记住非标准位置的 Tart 可执行文件，保存前验证版本且可随时恢复自动检测
- 导出不包含 VM 名称、日志或凭据的诊断报告
- 导入、导出版本化 TartR 设置文件，并在应用内查看 Tart 与系统运行环境

## 系统要求

- macOS 13 Ventura 或更高版本
- macOS VM 需要 Apple Silicon；Intel Mac 只能管理 Tart 支持的 Linux VM
- [Homebrew](https://brew.sh/)（推荐用于安装 Tart）

安装 Tart：

```bash
brew trust --formula cirruslabs/cli/softnet
brew install cirruslabs/cli/tart
```

Homebrew 6 要求对第三方 tap 依赖显式授权。这里只信任 Tart 的具体官方 `softnet` formula，不会信任整个 tap；旧版 Homebrew 若不支持 `brew trust`，可直接执行第二行。

## 安装 TartR

从 Releases 下载 `TartR-<版本>-macos.dmg`，打开后将 `TartR.app` 拖到 `Applications`。也可以下载 ZIP 后手动解压安装。

本地开发构建使用 ad-hoc 签名。面向其他用户分发时，请使用 Developer ID 签名并完成 Apple 公证，参见下方“发布”章节。

## 使用

启动 TartR 后，本地 VM 会自动出现在列表中。点击“下载/克隆镜像”可以完成等价于以下命令的操作：

```bash
tart clone ghcr.io/cirruslabs/macos-tahoe-base:latest tahoe-base
```

状态每 5 秒以及窗口重新激活时刷新。退出 TartR 时，如果仍有由 TartR 启动的 VM，可以选择“保持 VM 运行并退出”或“停止 VM 并退出”；从外部终端启动的 VM 始终不会被擅自停止。正在进行的克隆、导入、推送等修改操作不会被静默遗留，退出前会明确提示并安全取消。

按住 Shift 或 Command 可在列表中选择多台 VM。批量启动和停止只处理当前状态允许操作的项目；日志、重命名、配置、归档和永久删除磁盘等操作仍要求只选择一台 VM。

选择一台运行中的 VM 后，可在“更多操作…”中选择“复制 SSH 命令并打开终端…”。TartR 默认使用 `admin`，并为每台 VM 记忆修改后的用户名；它会通过 `tart ip <名称> --wait 5` 获取地址，只复制经过严格校验的命令并打开 Terminal，不会自动执行。请在终端确认命令后按 ⌘V 粘贴并回车。

在 macOS 14 或更高版本上，还可以选择“在虚拟机内执行命令…”。该功能需要 VM 内运行 Tart Guest Agent；Cirrus Labs 的非 vanilla 镜像默认包含 Guest Agent。输入内容仅作为 `/bin/zsh -lc` 的单个参数传给 `tart exec`，因此不会在宿主机 shell 中执行，但会以 VM 内当前 Guest Agent 权限修改客体系统。

如果 Tart 未安装在 Homebrew 或 `~/.local/bin` 的标准位置，可点击缺失提示中的“选择已有 Tart…”，或使用 TartR 菜单的“选择 Tart 可执行文件…”。TartR 会先执行带超时的版本验证再保存本机路径；“恢复自动检测 Tart”可清除自定义路径。

TartR 会在状态摘要中显示宿主卷可用空间。下载镜像、从 IPSW 创建 VM、导入归档和导出归档前会预留额外 5 GB；空间不足时默认取消，也可以选择清理 Tart 缓存或在确认风险后继续。

正式 Release 构建可从 TartR 菜单手动检查更新，也可以关闭“自动检查更新”。自动检查最多每天一次，只获取不超过 1 MB 的 HTTPS JSON manifest，不会自动下载。用户确认后可在 App 内选择 DMG 保存位置；下载严格限制为 manifest 声明大小且不超过 512 MB，完成后两次验证文件大小和 SHA-256。TartR 不会自动安装或执行更新。电脑唤醒后会立即重新同步 VM 状态。

## 开发

```bash
make test
make compat # 需要已安装 Tart，用于验证当前 CLI 参数兼容性
make build
make smoke  # 启动打包 App，用隔离的假 Tart 验证状态同步和重复打开
make verify
```

工程使用 Swift Package Manager：

- `TartRCore`：Tart 数据模型、命令构造、状态解析、镜像目录和路径定位
- `TartR`：AppKit 应用、进程生命周期、状态轮询和 UI
- `TartRCoreTests`：无需真实 VM 的核心单元测试

`make smoke` 不接触真实 Tart VM 或用户偏好。它在临时 HOME 中启动打包后的 App，验证已停止的自动启动 VM 只启动一次、外部已运行 VM 不会被重复启动，并确认再次打开 App 只激活现有实例和重新同步状态。

`make build` 会生成以下可发布工件；App 始终封装在 ZIP 和 DMG 中，避免工作区文件提供器写入 FinderInfo 后影响代码签名：

- `outputs/TartR-<版本>-macos.zip`
- `outputs/TartR-<版本>-macos.zip.sha256`
- `outputs/TartR-<版本>-macos.dmg`
- `outputs/TartR-<版本>-macos.dmg.sha256`

Release 工作流还会生成稳定名称的 `outputs/TartR-update.json`，其中包含版本、最低 macOS、DMG 下载地址、文件大小和 SHA-256。本地开发构建默认不配置更新源，不会自动联网。

## 发布

Developer ID 构建：

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make build
```

先将公证凭据保存到钥匙串：

```bash
xcrun notarytool store-credentials TartR-notary \
  --apple-id you@example.com \
  --team-id TEAMID \
  --password APP_SPECIFIC_PASSWORD
```

然后提交公证：

```bash
NOTARY_PROFILE=TartR-notary make notarize
```

构建脚本会启用 Hardened Runtime、装订公证票据，并重新生成 SHA-256。

也可以配置仓库 Secrets 后推送与版本一致的标签，由 Release workflow 自动完成签名、公证和发布；详见 `docs/RELEASING.md`。

## 安全设计

- VM 名称和镜像地址作为独立 `Process.arguments` 传递，不拼接为 shell 命令
- SSH 用户名和 Tart 返回的主机地址必须通过白名单校验；生成的命令只复制到剪贴板，不会自动执行
- 客体 Shell 命令通过独立进程参数传给 `tart exec`，不会进入宿主机 shell；界面明确其在 VM 内具有实际执行效果
- 只在找不到标准 Tart 安装路径时使用登录 shell 兼容层
- 用户选择的 Tart 文件必须具有执行权限并通过受限时间的版本探测，失败路径不会持久化
- 大容量操作会检查实际目标卷容量，整数溢出或空间不足按安全失败处理，并保留用户明确覆盖的能力
- 更新 manifest 只接受无内嵌凭据的 HTTPS URL、合法版本、最低系统版本、DMG 地址、受限文件大小和 64 字符十六进制 SHA-256
- Manifest 与 DMG 的重定向和最终响应继续强制 HTTPS；未通过大小与 SHA-256 双重验证的下载不会保存
- 删除 VM 前必须输入完整 VM 名称二次确认
- 长任务可取消，输出由固定内存上限的管道持续排空，避免管道阻塞以及磁盘或内存无限增长
- 下载、推送和创建任务实时显示 Tart 最新进度输出
- Tart 子命令输出最多保留最近 1 MB，异常工具输出不会无限占用宿主机资源
- 状态同步具有超时和进程回收保护，异常 Tart 进程不会永久卡住管理界面
- 配置数据保留有效备份并支持损坏恢复；崩溃遗留的临时任务文件会自动清理
- 设置导入会验证格式、重复项和名称，运行中不会替换进程对应关系
- 日志自动轮转；TartR 不保存 registry 密码或 SSH 密码

## 许可证

[MIT](LICENSE)
