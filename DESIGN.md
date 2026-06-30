# RAMMap Memory Guard — 设计方案

## 1. 项目概述

RAMMap Memory Guard 是一个 Windows 后台内存监控与自动清理守护服务。利用 Sysinternals RAMMap（`RAMMap64.exe`）在物理内存使用率超过阈值时自动调用系统级内存清理命令，释放物理内存。

### 核心目标

- **持续监控**：以固定间隔检测系统物理内存使用率
- **阈值触发**：超过阈值时按序执行 RAMMap 清理策略（Ew / Es / Em，可配置子集）
- **冷却控制**：两次清理之间强制最小间隔，避免高频清理形成死循环
- **keep-alive**：通过 Windows Task Scheduler 实现进程级守护——进程崩溃后自动拉起
- **静默运行**：以 SYSTEM 账户在 Session 0 运行，完全无窗口、无弹窗
- **单一脚本**：所有功能（监控、安装、卸载、诊断）集成在一个 `.ps1` 文件中

### 文件

| 文件 | 角色 |
|------|------|
| `RAMMapMemoryGuard.ps1` | 唯一入口——守护循环 / 安装 / 卸载 / 诊断均在同一个脚本 |
| `RAMMap64.exe` | 微软 Sysinternals 工具（二进制），负责实际内存清理动作 |

---

## 2. 架构

### 2.1 模式调度

```
RAMMapMemoryGuard.ps1

    ├── -Install    → 以管理员身份注册 Task Scheduler 任务
    │
    ├── -Uninstall  → 以管理员身份删除 Task Scheduler 任务
    │
    └── 默认（Monitor 模式）
         │
         ├── RAMMap64.exe 存在性检查
         ├── Mutex 单实例守卫 (Global\ → Local\ fallback)
         ├── 管理员提权（WhatIf 模式下跳过；SYSTEM 账户自动跳过）
         └── 监控循环
              ├── Get-MemoryStatus (Get-CimInstance Win32_OperatingSystem)
              ├── 阈值判断 (默认 ≥ 80%)
              ├── 冷却检查 (默认 ≥ 5 分钟)
              ├── Invoke-RAMMapCleanup (Ew → Es → Em，每步 WaitForExit 15s 超时)
              ├── 清理效果评估 (前后对比采样)
              └── Sleep Interval (默认 30s) → 循环
```

### 2.2 keep-alive 机制

```
系统启动
   │
   ▼
Task Scheduler BOOT 触发器（启动时 + 每 5 分钟重复）
   │
   ▼ SYSTEM 账户 / Session 0（无交互桌面）
powershell.exe -WindowStyle Hidden -File RAMMapMemoryGuard.ps1
   │
   ├── 创建 Global\RAMMapMemoryGuard Mutex 成功 → 启动监控循环
   └── 创建 Mutex 失败（已有实例持有）→ 静默退出（exit 0）
```

进程崩溃后 Mutex 被 OS 自动释放，下一个 5 分钟触发周期新进程可成功获取 Mutex，恢复守护。

**为什么用 BOOT 触发器 + SYSTEM 账户？**

- 电脑启动后立即开始监控，无需用户登录
- SYSTEM 账户运行在 Session 0，没有交互桌面，**任何窗口都不会弹出**
- 使用 `TASK_LOGON_SERVICE_ACCOUNT` 登录类型，无需存储密码
- 完全消除旧版 LOGON + InteractiveToken 方案可能出现的 PowerShell 窗口闪烁问题

---

## 3. 参数说明

### Monitor 模式（默认）

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `-Threshold` | `int` (1–99) | 80 | 内存使用率触发阈值（百分比） |
| `-Interval` | `int` (5–3600) | 30 | 内存采样间隔（秒） |
| `-CleanupCooldown` | `int` (1–1440) | 5 | 两次清理之间最小间隔（分钟） |
| `-Operations` | `string[]` (Ew,Es,Em) | 全部 | 要执行的 RAMMap 清理操作子集 |
| `-LogPath` | `string` | 自动生成 | 日志文件路径。默认按日期滚动：`memory_cleaner_YYYYMMDD.log` |
| `-WhatIf` | `switch` | False | 诊断模式：采样并报告，不执行清理，不创建日志文件，不要求管理员权限 |

### Install 模式

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `-Install` | `switch` | —— | 在 Task Scheduler 中注册 keep-alive 任务 |
| `-RunGuardInterval` | `int` (1–1440) | 5 | keep-alive 触发间隔（分钟） |
| `-Force` | `switch` | False | 若任务已存在则先删除再创建 |

### Uninstall 模式

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `-Uninstall` | `switch` | —— | 从 Task Scheduler 中删除 keep-alive 任务 |
| `-Force` | `switch` | False | 跳过确认提示 |

---

## 4. 核心模块

### 4.1 实例守卫（Mutex）

使用 Windows 命名 Mutex 保证全局单实例。优先在 `Global\` 命名空间创建（支持跨会话去重），失败时 fallback 到 `Local\`。

```
$mutex = New Mutex(true, "Global\RAMMapMemoryGuard")
  ↓ 失败（权限不足）
$mutex = New Mutex(true, "Local\RAMMapMemoryGuard")
  ↓ createdNew = false
静默退出（exit 0）
```

keep-alive 正是依赖此机制：Task Scheduler 定时拉起新进程 → 已有 Mutex 持有者 → 退出；无持有者 → 接管。

### 4.2 管理员提权

```powershell
Test-Administrator
  → 使用 [WindowsPrincipal]::IsInRole(Administrator)
  → WhatIf 模式：跳过后继续运行（仅采样不执行清理，无需管理员）
  → 正常模式：ProcessStartInfo.Verb = "runas" 重新启动自身，退出
  → SYSTEM 账户（Boot Trigger）：由 Test-SystemAccount 检测 SID S-1-5-18，
    自动跳过提权步骤——SYSTEM 已拥有全部权限
```

不使用 `net session`（Batch 旧做法），改用 .NET 标准 API。

### 4.3 内存采样

```powershell
Get-MemoryStatus
  → Get-CimInstance Win32_OperatingSystem
  → 提取 TotalVisibleMemorySize (KB) / FreePhysicalMemory (KB)
  → 计算 UsedKB、UsedPct (64-bit)
  → 返回 PSCustomObject
  → 失败时记录 ERROR 日志并返回 $null
```

原生 PowerShell CIM 调用，零子进程开销。返回 `$null` 时循环会跳过当前轮次而非崩溃。

### 4.4 RAMMap 清理执行

```powershell
Invoke-RAMMapCleanup -Ops @("Ew", "Es", "Em")

foreach op in Ops:
    Start-Process RAMMap64.exe -$op -WindowStyle Hidden -PassThru
    WaitForExit(15000)  # 最多等 15 秒
      超时 → Kill 进程 + WARNING 日志
      非零退出码 → WARNING 日志
    每步间隔 3 秒
    全部失败 → 返回 $false
```

| 参数 | 操作 | 说明 |
|------|------|------|
| `-Ew` | Empty Working Set | 清空所有用户进程的工作集 |
| `-Es` | Empty System Working Set | 清空系统缓存的工作集 |
| `-Em` | Empty Modified Page List | 将已修改页写入磁盘后回收 |

**窗口行为**：RAMMap64.exe 以 `-WindowStyle Hidden` 启动，完全不可见。旧版使用 `Minimized` 会导致最小化窗口在任务栏闪烁。

**WhatIf 模式行为**：打印 `[WHATIF] Would run: RAMMap64.exe -Ew ...` 但不启动进程。

### 4.5 清理效果评估

```
before: free_before (KB)
  ↓ 执行 Ew, Es, Em（均以 Hidden 方式运行）
after:  free_after (KB)

freed_mb = (free_after - free_before) / 1024

freed_mb > 0  → "freed ~X MB"
freed_mb = 0 且 cleanOk → "no significant memory freed"
cleanOk = false → "completed with errors"
重新采样失败 → "failed to re-sample memory"
```

### 4.6 日志系统

```powershell
Write-Log $Message
  → 时间戳格式: [yyyy/MM/dd HH:mm:ss]
  → 文件: Out-File -Append -Encoding utf8
  → 文件名: memory_cleaner_YYYYMMDD.log（每次日志写入时动态拼接日期）
  → WhatIf 模式: 仅输出到控制台，不写文件
  → 控制台: Write-Host（在 Session 0 中不可见，仅用于兼容性）
```

文件名按天滚动——跨午夜后新日志写入次日的文件，无额外逻辑。

### 4.7 Task Scheduler 注册

使用 COM API（`Schedule.Service`）而非 `schtasks.exe`，保证可靠性。

| 配置项 | 值 |
|--------|-----|
| 任务名称 | `RAMMapMemoryGuard` |
| 兼容性 | TASK_COMPATIBILITY_V2 |
| 触发器 | TASK_TRIGGER_BOOT（系统启动时）+ 每 N 分钟重复（默认 5），持续 365 天 |
| 操作 | `powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "<脚本路径>"` |
| 主体 | `SYSTEM` / SERVICE_ACCOUNT / Highest（Session 0 运行，无弹窗） |
| 电源 | 电池不阻止启动、不断电停止 |
| 超时 | 无限制（PT0S） |

**与旧版的区别：**

| 项目 | 旧版 | 新版 |
|------|------|------|
| 触发器 | `TASK_TRIGGER_LOGON`（用户登录） | `TASK_TRIGGER_BOOT`（系统启动） |
| 运行身份 | 当前用户（InteractiveToken） | `SYSTEM`（ServiceAccount） |
| 运行环境 | 用户会话（Session 1+） | 无交互桌面（Session 0） |
| 弹窗风险 | PowerShell 窗口可能闪现 | 完全无窗口 |

注册时自动删除同名的已有任务（CreateOrUpdate 语义）。

### 4.8 提权守卫（`Test-SystemAccount`）

当脚本以 SYSTEM 身份运行时（BOOT 触发器），不需要也不应该触发 UAC 提权。

```powershell
function Test-SystemAccount {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return $identity.User.Value -eq 'S-1-5-18'
}
```

在自动提权判定处：

```powershell
if (-not $WhatIf -and -not (Test-Administrator) -and -not (Test-SystemAccount)) {
    # 只有普通用户才需要提权，SYSTEM 直接跳过
    $mutex.Dispose()
    Request-Administrator
}
```

### 4.9 Task Scheduler 卸载

使用同一 COM API 删除 `RAMMapMemoryGuard` 任务。`-Force` 时跳过确认。

---

## 5. 监控循环主流程

```
while ($true):
    mem = Get-MemoryStatus
    if mem == null → sleep Interval, continue

    log "Memory: X% (X KB used / X KB total)"

    if mem.UsedPct >= Threshold:
        elapsed = Now - lastCleanupTime
        if elapsed >= CleanupCooldown:
            log "WARNING: Memory exceeds X% threshold! Cleaning..."
            beforeFree = mem.FreeKB
            Invoke-RAMMapCleanup(Operations)   # RAMMap64.exe 以 Hidden 运行
            等待 2s 后重新采样
            计算释放量 → log "CLEANUP: ... freed ~X MB"
            lastCleanupTime = Now
        else:
            log "SKIP: cooldown active (X min remaining)"

    else:
        log "OK: Memory below threshold."

    sleep Interval
```

---

## 6. 数据流

```
WMI (Get-CimInstance Win32_OperatingSystem)
   │
   ├── TotalVisibleMemorySize  →  total_kb (int64)
   └── FreePhysicalMemory      →  free_kb  (int64)
   │
   ▼
used_kb   = total_kb - free_kb
used_pct  = round(used_kb × 100 / total_kb, 1)
   │
   ├── used_pct < Threshold  → 日志 "OK" → sleep
   │
   └── used_pct >= Threshold
         │
         ├── 冷却未结束  → 日志 "SKIP" → sleep
         │
         └── 冷却已结束
               │
               ▼
         RAMMap64.exe -Ew  (Start-Process -WindowStyle Hidden + 15s WaitForExit)
          sleep 3
         RAMMap64.exe -Es
          sleep 3
         RAMMap64.exe -Em
          sleep 3
               │
               ▼
         Get-CimInstance → new_free_kb
         freed_mb = (new_free_kb - free_kb) / 1024
               │
               ▼
         日志 "CLEANUP: X% used (freed ~X MB)"
```

---

## 7. 运行依赖与约束

| 依赖 | 说明 |
|------|------|
| Windows 操作系统 | `Get-CimInstance`、Task Scheduler COM、Mutex 均为 Windows API |
| 管理员权限 | RAMMap 清理操作和 Task Scheduler 注册需要；WhatIf 诊断模式除外；SYSTEM 账户免提权 |
| `RAMMap64.exe` | 须放置于脚本同级目录（从 Microsoft Sysinternals 获取） |
| PowerShell 5.1+ | `Get-CimInstance`、`[PSCustomObject]`、类语法、COM 互操作 |

---

## 8. 部署流程

```
① 将 RAMMap64.exe 放入脚本所在目录
② 以普通用户身份执行安装（会触发 UAC 提权）：
      powershell -File RAMMapMemoryGuard.ps1 -Install
   → 在 Task Scheduler 中注册 "RAMMapMemoryGuard" 任务
   → 任务使用 BOOT 触发器 + SYSTEM 账户，下次系统启动时自动生效
③ 如需立即启动（不重启）：
      schtasks /run /tn "RAMMapMemoryGuard"
④ 卸载：
      powershell -File RAMMapMemoryGuard.ps1 -Uninstall
```

---

## 9. 错误处理约定

| 场景 | 行为 |
|------|------|
| RAMMap64.exe 不存在（非 WhatIf） | 立即退出，exit code 4 |
| Mutex 创建失败 | 立即退出，exit code 5（Global 失败时自动 fallback 到 Local） |
| WMI 采样失败 | `Get-MemoryStatus` 返回 `$null`，循环跳过本轮 |
| RAMMap 执行超时（15s） | Kill 子进程，记录 WARNING，继续执行下一个操作 |
| RAMMap 退出码非零 | 记录 WARNING，继续 |
| 循环内异常 | `catch` 记录 "ERROR in monitoring loop: $_"，`sleep Interval` 后继续 |
| Task Scheduler 注册失败 | 立即退出，exit code 3 |
| Mutex 已存在 | 静默退出，exit code 0（keep-alive 的正常路径） |

---

## 10. 与原版对比

| 项目 | 原版（已删除） | 当前版本 |
|------|---------------|---------|
| 文件数 | 4（bat ×2, vbs ×1, ps1 ×1） | 1（ps1 ×1） |
| 语言 | Batch + VBScript + PowerShell | 纯 PowerShell |
| WMI 查询 | 每轮启动 2 个 `powershell.exe` 子进程 | 原生 `Get-CimInstance` |
| 实例守卫 | 窗口标题文本匹配 | 命名 Mutex（Global + Local 双命名空间） |
| 数值精度 | `set /a` 32 位（> 2GB 溢出风险） | `[int64]` 64 位 |
| 清理时序 | `start /min` + 固定 `sleep 3` + `taskkill /f` | `Start-Process -PassThru` + `WaitForExit(15000)` 超时 |
| 清理窗口 | `start /min`（最小化窗口，会闪现） | `-WindowStyle Hidden`（完全隐藏） |
| 日志 | `>` 覆盖写 | `Out-File -Append` 追加 + 按日期滚动 |
| 路径 | 硬编码 `C:\rammap\` | `$MyInvocation.MyCommand.Path` 动态检测 |
| 错误处理 | 无 | 全域 `try/catch` |
| 清理冷却 | 无 | `-CleanupCooldown` 可配 |
| 操作子集 | 无，永远三连 | `-Operations` 可配 |
| 诊断模式 | 无 | `-WhatIf` |
| 自安装/卸载 | 单独脚本 | `-Install` / `-Uninstall` |
| 任务触发器 | LOGON（用户登录） | BOOT（系统启动） |
| 任务身份 | 当前用户（InteractiveToken） | SYSTEM（ServiceAccount） |
| 自动提权 | 无条件触发 UAC | SYSTEM 账户自动跳过 |
| 运行窗口 | 可能闪现 PowerShell 窗口 | Session 0 无窗口、无弹窗 |

---

## 11. 修改记录

| 日期 | 修改内容 |
|------|---------|
| 2026-06-30 | 初始重构，整合 4 个文件为单一 ps1 |
| 2026-06-30 | 修复：RAMMap64.exe `-WindowStyle Minimized` → `Hidden`，消除清理窗口闪现 |
| 2026-06-30 | 修复：`TASK_TRIGGER_LOGON` → `TASK_TRIGGER_BOOT`，`InteractiveToken` → `SERVICE_ACCOUNT`，运行身份改为 `SYSTEM`，实现系统启动时无窗口自启 |
| 2026-06-30 | 修复：新增 `Test-SystemAccount` 函数，SYSTEM 账户自动跳过 UAC 提权步骤 |
