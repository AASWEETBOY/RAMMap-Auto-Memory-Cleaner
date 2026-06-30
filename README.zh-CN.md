# RAMMap 内存守护服务

[English](README.md) | [简体中文](README.zh-CN.md)

一个轻量级的 Windows 后台服务：当物理内存占用超过设定阈值时，自动调用微软
Sysinternals **RAMMap** 释放内存。

所有功能都集成在**单个 PowerShell 脚本**
[`RAMMapMemoryGuard.ps1`](RAMMapMemoryGuard.ps1) 中——监控、安装、卸载、诊断
（空跑）模式一应俱全。完整设计见 [DESIGN.md](DESIGN.md)。

## 工作原理

原生 PowerShell 循环按固定间隔轮询物理内存占用率（通过
`Get-CimInstance Win32_OperatingSystem`，零子进程开销）。当占用率超过阈值、
且冷却时间已过时，调用 `RAMMap64.exe` 清空工作集、系统工作集和已修改页面列表，
随后重新采样并记录释放了多少内存。

| 组件 | 作用 |
|------|------|
| `RAMMapMemoryGuard.ps1` | 唯一入口：监控循环 / 安装 / 卸载 / 诊断 |
| `RAMMap64.exe` | 微软 Sysinternals 二进制工具，负责实际的内存清理（未随仓库分发） |

使用的 RAMMap 操作（可通过 `-Operations` 配置子集）：

- `-Ew` —— 清空工作集（Empty Working Sets）
- `-Es` —— 清空系统工作集（Empty System Working Set）
- `-Em` —— 清空已修改页面列表（Empty Modified Page List）

### keep-alive 保活机制

安装时会注册一个计划任务，以 **SYSTEM** 账户、**系统启动（BOOT）** 触发器运行，
并每隔几分钟重复一次。命名 Mutex（`Global\RAMMapMemoryGuard`，失败时回退到
`Local\`）保证全局单实例：每次定时拉起的进程要么获取 Mutex 接管运行，要么因已有
实例持有而静默退出。守护进程崩溃后操作系统会自动释放 Mutex，下一个重复周期即可
重新拉起。以 SYSTEM 身份运行在 Session 0，意味着**永远不会弹出控制台窗口，也不会
弹出 UAC 确认框**。

## 环境要求

- Windows 10/11
- PowerShell 5.1+
- 管理员权限（RAMMap 清空内存列表需要管理员权限；`-WhatIf` 诊断模式除外）
- `RAMMap64.exe` —— **未随仓库分发**，请从官方渠道下载（见下文）

## 安装步骤

1. 从微软官网下载 RAMMap，把 `RAMMap64.exe` 放到与脚本**相同的目录**：
   <https://learn.microsoft.com/sysinternals/downloads/rammap>

2. 安装保活任务（会触发一次 UAC 提权确认）：

   ```powershell
   powershell -ExecutionPolicy Bypass -File RAMMapMemoryGuard.ps1 -Install
   ```

   它会注册一个名为 `RAMMapMemoryGuard` 的计划任务：
   - 系统启动时运行，每 5 分钟重复一次（崩溃后自动重启）；
   - 以 **SYSTEM** 账户在 Session 0 运行，无窗口、无 UAC 弹窗。

3. 无需重启即可立即启动：

   ```powershell
   schtasks /run /tn "RAMMapMemoryGuard"
   ```

## 配置参数

在命令行传入参数（下表为默认值）：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-Threshold` | `80` | 触发清理的内存占用率百分比（1–99） |
| `-Interval` | `30` | 采样间隔（秒，5–3600） |
| `-CleanupCooldown` | `5` | 两次清理之间的最小间隔（分钟，1–1440） |
| `-Operations` | `Ew Es Em` | 要执行的 RAMMap 操作子集 |
| `-LogPath` | 自动 | 日志文件路径；默认按天滚动 `memory_cleaner_YYYYMMDD.log` |
| `-WhatIf` | 关闭 | 诊断模式：仅采样并报告，不清理、不写日志、无需管理员 |
| `-RunGuardInterval` | `5` | 保活触发间隔（分钟，与 `-Install` 配合） |

示例：

```powershell
# 直接运行监控，使用 90% 阈值、60 秒间隔
powershell -File RAMMapMemoryGuard.ps1 -Threshold 90 -Interval 60

# 诊断空跑——查看它会做什么，无需管理员权限
powershell -File RAMMapMemoryGuard.ps1 -WhatIf
```

## 卸载

```powershell
powershell -File RAMMapMemoryGuard.ps1 -Uninstall
```

如果守护进程仍在运行，请一并停止：

```powershell
Stop-Process -Name RAMMap64 -Force
```

## ⚠️ 安全提示（请务必阅读）

本脚本有意使用了**可能被杀毒软件误报**的技术：提权到管理员、隐藏窗口、以 SYSTEM
身份运行、常驻计划任务。这与部分恶意软件的行为模式相同，因此可能出现误报。本项目
所有代码均为纯文本、可完整审计：

- **为什么需要管理员 / SYSTEM 权限？** RAMMap 清空内存列表必须有管理员权限；保活
  任务以 SYSTEM 运行可避免每次触发都弹出 UAC 确认框。
- **为什么用计划任务？** 这样服务能在后台运行，并在崩溃后自动重启。
- **为什么隐藏窗口？** 避免后台循环一直占着一个控制台窗口。以 SYSTEM 运行在
  Session 0 时根本没有交互桌面。

建议你在运行前通读每一行代码，并用自己的工具扫描（例如
<https://www.virustotal.com>）。你也可以用 `Get-FileHash <文件> -Algorithm SHA256`
核对任意文件与你本地副本是否一致。**使用风险自负。**

## 免责声明

本项目**与微软及 Sysinternals 无任何隶属关系**。RAMMap 是微软的工具，遵循其
自身的许可协议，请仅从上方官方链接下载，且不要再分发该二进制文件。本脚本按
**“原样”提供，不附带任何形式的担保**。

## 贡献者
1. Deepseek v4 pro/flash
2. Claude Opus 4.8
