# RAMMap 自动内存清理工具

[English](README.md) | [简体中文](README.zh-CN.md)

一个轻量级的 Windows 后台服务：当物理内存占用超过设定阈值时，自动调用微软
Sysinternals **RAMMap** 释放内存。

## 工作原理

批处理脚本按固定间隔轮询物理内存占用率；当占用率超过阈值时，调用
`RAMMap64.exe` 清空工作集、系统工作集和已修改页面列表，并记录释放了多少内存。

| 组件 | 作用 |
|------|------|
| `memory_cleaner.bat` | 核心循环：轮询内存，超阈值时运行 RAMMap，写日志 |
| `memory_cleaner.vbs` | 启动器，以隐藏窗口 + 管理员权限启动核心循环 |
| `schtasks_install.ps1` | 注册计划任务，实现登录自启与自动重启 |
| `schtasks_install.bat` | 便捷封装：自动提权并运行安装脚本 |

使用的 RAMMap 参数：

- `-Ew` —— 清空工作集（Empty Working Sets）
- `-Es` —— 清空系统工作集（Empty System Working Set）
- `-Em` —— 清空已修改页面列表（Empty Modified Page List）

## 环境要求

- Windows（在 Windows 10/11 上测试）
- 管理员权限（RAMMap 清空内存列表需要管理员权限）
- `RAMMap64.exe` —— **未随仓库分发**，请从官方渠道下载（见下文）

## 安装步骤

1. 从微软官网下载 RAMMap，把 `RAMMap64.exe` 放到与脚本**相同的目录**：
   <https://learn.microsoft.com/sysinternals/downloads/rammap>

2.（可选）修改 `memory_cleaner.bat` 顶部的配置：

   ```bat
   set THRESHOLD=80     :: 内存占用 >= 80% 时清理
   set INTERVAL=30      :: 每 30 秒检查一次
   ```

3. 运行 `schtasks_install.bat`（会请求管理员权限）。它会注册一个名为
   `MemoryCleaner` 的计划任务：
   - 登录时启动清理服务；
   - 每 5 分钟重复一次，进程意外退出后可自动重启；
   - 以最高权限运行，避免每次触发都弹出 UAC。

4. 无需重新注销即可立即启动：

   ```bat
   schtasks /run /tn "MemoryCleaner"
   ```

## 卸载

```bat
schtasks /delete /tn "MemoryCleaner" /f
```

## ⚠️ 安全提示（请务必阅读）

这些脚本有意使用了**可能被杀毒软件误报**的技术：提权到管理员、隐藏启动窗口、
常驻计划任务。这与部分恶意软件的行为模式相同，因此可能出现误报。本项目所有
代码均为纯文本、可完整审计：

- **为什么需要管理员权限？** RAMMap 清空内存列表必须有管理员权限。
- **为什么用最高权限的计划任务？** 这样服务可在后台运行，而不必每隔几分钟弹
  一次 UAC 确认框。
- **为什么隐藏窗口？** 避免后台循环一直占着一个控制台窗口。把
  `memory_cleaner.vbs` 末尾的 `0` 改成 `1` 即可让窗口可见。

建议你在运行前通读每一行代码，并用自己的工具扫描（例如
<https://www.virustotal.com>）。**使用风险自负。**

### 杀毒扫描报告

最可能触发杀软启发式检测的两个脚本已上传 VirusTotal 扫描。每份报告的 SHA-256
与本仓库中的文件一致，你可以用 `Get-FileHash <文件> -Algorithm SHA256` 自行核对：

- `memory_cleaner.bat` ——
  <https://www.virustotal.com/gui/file/77cfe7f3bf0b310cacdd4450ea3cd65c8440cec1a92c967eb64e5eaf6257c4cf>
- `schtasks_install.ps1` ——
  <https://www.virustotal.com/gui/file/d8fb7f6c0dc854622df7907164aa8babab9cefb392eeaa362ec4716e84adba3e>

## 免责声明

本项目**与微软及 Sysinternals 无任何隶属关系**。RAMMap 是微软的工具，遵循其
自身的许可协议，请仅从上方官方链接下载，且不要再分发该二进制文件。这些脚本按
**“原样”提供，不附带任何形式的担保**。

## 贡献者
1. Deepseek v4 pro/flash
2. Claude Opus 4.8
