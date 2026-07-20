# TartR

TartR 是一个原生 macOS Tart 虚拟机管理器。它提供实时状态同步、官方镜像下载和常见虚拟机操作，同时保留 Tart CLI 的可预测行为。

## 功能

- 自动发现本地 Tart VM，并同步运行、停止和挂起状态
- 防止对已运行 VM 重复执行 `tart run`
- 管理由 TartR 或外部终端启动的 VM
- 内置 15 个 Cirrus Labs macOS 镜像（Tahoe 至 Monterey）和 3 个 Linux 镜像
- 支持编辑 OCI 地址，可下载官方目录之外的 Tart 镜像和特定 tag
- 下载远程镜像、复制本地 VM、重命名和永久删除
- 调整 CPU、内存、显示分辨率和磁盘大小
- 获取 IP、普通启动、可挂起模式启动、停止和挂起
- 从最新 IPSW 创建 macOS VM，或创建空白 Linux VM
- 每台 VM 可配置打开 TartR 时自动启动
- Tart 缺失时显示 Homebrew 安装引导

## 系统要求

- macOS 13 Ventura 或更高版本
- macOS VM 需要 Apple Silicon；Intel Mac 只能管理 Tart 支持的 Linux VM
- [Homebrew](https://brew.sh/)（推荐用于安装 Tart）

安装 Tart：

```bash
brew install cirruslabs/cli/tart
```

## 安装 TartR

从 Releases 下载 `TartR-<版本>-macos.zip`，解压后将 `TartR.app` 拖入 `/Applications`。

本地开发构建使用 ad-hoc 签名。面向其他用户分发时，请使用 Developer ID 签名并完成 Apple 公证，参见下方“发布”章节。

## 使用

启动 TartR 后，本地 VM 会自动出现在列表中。点击“下载官方镜像”可以完成等价于以下命令的操作：

```bash
tart clone ghcr.io/cirruslabs/macos-tahoe-base:latest tahoe-base
```

状态每 5 秒以及窗口重新激活时刷新。退出 TartR 只会停止由 TartR 自己启动的前台 `tart run` 进程，不会擅自停止从外部终端启动的 VM。

## 开发

```bash
make test
make build
make verify
```

工程使用 Swift Package Manager：

- `TartRCore`：Tart 数据模型、命令构造、状态解析、镜像目录和路径定位
- `TartR`：AppKit 应用、进程生命周期、状态轮询和 UI
- `TartRCoreTests`：无需真实 VM 的核心单元测试

`make build` 会生成：

- `outputs/TartR.app`
- `outputs/TartR-<版本>-macos.zip`
- `outputs/TartR-<版本>-macos.zip.sha256`

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
- 只在找不到标准 Tart 安装路径时使用登录 shell 兼容层
- 删除 VM 前必须输入完整 VM 名称二次确认
- 长任务可取消，输出写入受控临时文件，避免管道阻塞和内存无限增长
- 日志自动轮转；TartR 不保存 registry 密码或 SSH 密码

## 许可证

[MIT](LICENSE)
