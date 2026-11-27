# 手工验收：一窗一灯

> 关联：issue #11（T08）· 规格 `docs/specs/per-window-lamp.md`（§ Testing Decisions 3、User Story 27）
> 适用：Windows 10/11；Windows Terminal（ConPTY）与经典控制台（conhost）各跑一遍。
> 目的：把机器相关的两条底线（两终端各自只有自己的灯 / 强杀一个不影响另一个）和 `/clear` 行为固化成别人照着就能执行的步骤。

本清单只做**观测**。除验收 B 明确要求强杀一个进程外，不结束进程、不卸载计划任务、不手改状态文件。

## 0. 前置

1. 打开**两个真实终端**，分别启动一个 CodeBuddy 会话（在两个终端里各自进入同一个项目即可）。
   - 不要用同一窗口的两个标签页做 A/B：它们共享 hwnd，按设计会聚合成一盏灯（角标 `·2`），那是正确行为，不是 A/B 的验收对象。
2. 在**每个**终端里执行一次探针，把输出贴进记录表：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\probe.ps1 -Verdict
   ```

   预期（每个终端一行，除这一行外没有别的输出）：

   ```text
   hwnd=44434952 class=CASCADIA_HOSTING_WINDOW_CLASS size=1199x616 verdict=go
   ```

   - `hwnd` 是**十进制**；最小化的终端用还原矩形量尺寸，仍然能给 `verdict=go`。
   - 两次记录的 `hwnd` **必须不同**。相同说明两个会话落在同一个窗口（同窗聚合），换两个独立窗口重来。
   - `verdict=no-go` 时先修终端/解析（见 §5），不要继续 A/B。

3. 两个会话各提交一次任意提示，让灯被拉起（首次 SessionStart 已触发；保险起见再发一条）。
4. 终端里都先 `cd` 到仓库根，后续命令都在仓库根执行。

### 记录表

| 项 | 终端 1 | 终端 2 |
| --- | --- | --- |
| `probe -Verdict` 整行 | | |
| hwnd（十进制） | | |
| 灯的计划任务名 | | |
| 锚文件 | `w<hwnd>.win` | `w<hwnd>.win` |

## 1. 只读盘点脚本

`tests/manual/acceptance.ps1` 是 A/B/D 共用的观测工具。它只读计划任务、锚（`w<hwnd>.win`）、绑定（`<session_id>.bind`）、状态（`<pid>.state`），**不杀进程、不写文件、不注册/删除任务**，退出码恒为 0。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\manual\acceptance.ps1
```

输出是一个四列表：

```text
KIND   NAME                                         STATUS DETAIL
state dir: D:\workspace\traffic-light\.traffic-light-states
task   traffic-light-w44434952                      PASS   anchor fresh age=512ms
anchor w44434952.win                                PASS   hwnd=44434952 age=512ms drawer=22588 nonce=9f3c1a02
bind   3f0a....bind                                 PASS   pid=17324 hwnd=44434952 project=traffic-light degraded=0
state  17324.state                                   PASS   state=idle age=2s
summary task=1 anchor=1 bind=1 state=1 pass=4 fail=0
```

- `KIND`：`task` / `anchor` / `bind` / `state`。
- `STATUS`：
  - `PASS`：对象存在且自洽（任务有新鲜锚、锚在 3s 内刷新、绑定 pid 存活且创建时间匹配、状态 pid 存活）。
  - `FAIL`：对象存在但已不一致（孤儿任务、过期锚、死绑定、孤儿状态、PID 被复用、旧格式任务）。
  - `EMPTY`：这一类什么都没有（干净机器、或灯已全部退出）。
- 判定口径：锚即心跳，drawer 每 1s 刷新一次；3s 内刷新过视为活着。锚超过 10s 未刷新才会被 GC 删除。

**没有灯时脚本也必须正常跑完**：在无灯机器上四类各一行 `EMPTY`，退出码 0。

## 2. 验收 A：两个终端各自只有自己的灯

**目的**：两个会话互不覆盖，各自贴在自己的窗口上（User Story 3、4）。

### 命令

```powershell
# 1) 计划任务：应恰好有两个 traffic-light-w<数字>，数字等于两个 probe hwnd
Get-ScheduledTask -TaskName 'traffic-light-*' |
    Select-Object TaskName, State

# 2) 状态目录清单：两个锚、两个绑定、两个状态
Get-ChildItem .\.traffic-light-states |
    Select-Object Name, Length, LastWriteTime

# 3) 一键盘点（四类各两行 PASS）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\manual\acceptance.ps1
```

### 预期

- 计划任务集合 = `traffic-light-w<hwnd1>`、`traffic-light-w<hwnd2>`，没有第三个任务，也没有不带 `w<数字>` 的旧格式任务。
- 锚文件正好 `w<hwnd1>.win`、`w<hwnd2>.win`；两个文件的内容里 `hwnd=` 分别等于文件名里的数字。
- 绑定文件按 `session_id` 各一个；两个绑定的 `pid` 不同、`hwnd` 不同、`degraded=0`。
- 每个终端上方只有一盏灯，位置贴在各自窗口下方；两盏灯不重叠。

### 通过判定

- 上面三条命令的输出与预期一致，且 `acceptance.ps1` 的 `summary` 中 `fail=0`、两类灯各有 `PASS`。
- 两个 `hwnd` 不同（记录表已证明）。

### 失败排查

- 只剩一个任务 / 一个锚：两个终端可能共享 hwnd（同窗聚合）。回到 §0 用两个独立窗口；若 `probe -Verdict` 两次 hwnd 相同，确认是不是同一窗口的标签页。
- 出现 `traffic-light-w0`，或某个绑定 `degraded=1`：该会话没解析到窗口，落到了降级灯。看探针完整输出（不加 `-Verdict`）与 §5。
- 出现两个任务指向同一个 hwnd：两个 drawer 抢同一个锚的异常，检查锚 nonce 与 `daemon.log`（§5）。
- `FAIL anchor ... heartbeat stopped`：drawer 已死，见 §5 的 `daemon.log`。

## 3. 验收 B：强杀一个终端，另一盏无恙

**目的**：关掉一个终端不影响另一个；死灯自灭、任务不残留（User Story 4、5、18）。

### 先记录现场

```powershell
# 用验收 A 里终端 1 的 hwnd
$hwnd = <hwnd1>
Get-Content .\.traffic-light-states\w$hwnd.win
Get-ScheduledTask -TaskName "traffic-light-w$hwnd" | Get-ScheduledTaskInfo
```

记下锚里的 `owner_pid`、`drawer_pid`，以及任务信息。

### 命令（二选一或都做）

**B1 强杀该会话的 CodeBuddy 进程**（最精确，不影响同进程的其他窗口）：

```powershell
# 从 terminal 1 的绑定文件取 pid（acceptance.ps1 的 bind 行也有）
$bind = Get-ChildItem .\.traffic-light-states\*.bind |
    Where-Object { (Get-Content $_ | Select-String '^hwnd=<hwnd1>$') }
$cbPid = (Get-Content $bind | Select-String '^pid=').Line -replace '^pid=', ''
taskkill /F /PID $cbPid
```

**B2 强杀终端窗口宿主**（更贴近"直接关窗口"）：

```powershell
# owner_pid 是承载该窗口的终端宿进程（WT 为 WindowsTerminal.exe）
taskkill /F /PID <owner_pid>
```

> 注意：一个 WindowsTerminal.exe 进程可能承载多个窗口。若两个终端在同一个 WT 进程里，B2 会一起杀掉，不能用来验证"另一盏无恙"。这种情况用 B1，或直接点该窗口的 X 关闭。

### 观测（每 0.5s 一次，只看不碰）

```powershell
1..12 | ForEach-Object {
    $names = @(Get-ScheduledTask -TaskName 'traffic-light-*' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.TaskName })
    '{0:HH:mm:ss.fff} tasks={1}' -f (Get-Date), ($names -join ',')
    Start-Sleep -Milliseconds 500
}
```

### 预期

- 终端 2 的灯**全程不动**：任务 `traffic-light-w<hwnd2>` 一直在，锚 `w<hwnd2>.win` 的 mtime 持续刷新，`acceptance.ps1` 里它的 `PASS` 不掉。
- 终端 1 的灯在**约 3s（一个宽限期）内**消失：`traffic-light-w<hwnd1>` 从任务列表消失，锚 `w<hwnd1>.win` 被删除；`acceptance.ps1` 不再列出它（或下一次 GC 后不再列出）。
- 期间不应出现 `traffic-light-w0`（另一盏没有失败，不该有降级灯）。

### 通过判定

- 3s 后任务列表只剩 `traffic-light-w<hwnd2>`，终端 2 的 `acceptance.ps1` 行仍为 `PASS`。
- `Get-ChildItem .\.traffic-light-states` 里 `w<hwnd1>.win` 已不存在。
- 终端 2 的灯没有闪烁/换位（目测 + 锚 nonce 未变）。

### 失败排查

- 死灯超过 3s 还在：看 `daemon.log` 最后 40 行（§5）；确认 drawer 进程 `drawer_pid` 是否还活着。若锚 mtime 仍在刷新，说明 drawer 没判定死（窗口句柄仍有效、或还有活绑定）——检查该 hwnd 是否还有别的会话绑定。
- 另一盏也灭了：两个终端共享 hwnd 或共享终端宿主进程；回到 §0 的独立窗口要求。
- 任务消失但锚还在：等一次 GC（下一条提示或 `resolve.ps1 -GcOnly`），仍未清则是 GC 判定阈值问题，记录 `stat` 的 mtime 与当前时间。

## 4. 验收 C：`/clear` 不闪、不重建、不换位

**目的**：`/clear` 只回到 IDLE，不换灯（User Story 7）。

### 先记录现场（终端 2，避开刚做 B 的终端）

```powershell
$hwnd = <hwnd2>
Get-Content .\.traffic-light-states\w$hwnd.win
(Get-ScheduledTask -TaskName "traffic-light-w$hwnd" | Get-ScheduledTaskInfo).LastRunTime
Get-ChildItem .\.traffic-light-states\*.bind | Select-Object Name, LastWriteTime
```

记下锚的 `nonce`、`drawer_pid`，任务的 `LastRunTime`，以及绑定的 `session_id` 文件名。

### 命令

在终端 2 的 CodeBuddy 会话里输入：

```text
/clear
```

然后立刻回到 PowerShell：

```powershell
1..10 | ForEach-Object {
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\manual\acceptance.ps1 |
        Select-String 'anchor|bind|state'
    Start-Sleep -Milliseconds 500
}
```

### 预期

- 灯**不闪、不消失、不重建、不换位**；锚文件名不变、`nonce` 不变、`drawer_pid` 不变。
- 任务 `traffic-light-w<hwnd2>` 不变；`LastRunTime` **不变**（没有重新拉起 drawer）。
- 绑定换成新的 `session_id.bind`：旧 `session_id.bind` 被删除，同 pid 最终只剩一条绑定。
- 状态回到 `idle`（`acceptance.ps1` 的 state 行 `state=idle`）；颜色没有闪成 `ended`/失败。

### 通过判定

- `nonce` 与 `drawer_pid` 前后一致；任务 `LastRunTime` 前后一致。
- 绑定文件数没有增加（同 pid 的旧绑定被清掉）。
- 灯在 `/clear` 前后位置不变（目测），状态列为 `idle`。

### 失败排查

- `nonce` 变了或 `LastRunTime` 变了：drawer 被重建了。看 `daemon.log` 是否有新的 `drawer hwnd=... pid=...` 启动行，以及锚是否在 `/clear` 前已过期（超过 3s 没刷新）。
- 灯灭了：SessionEnd 只应把状态置 `ended`，drawer 在 `ended` 且 pid 仍活时按 idle 渲染，且零活 pid 要连续 3 次心跳才自灭；若瞬间消失，检查是否误杀了进程。
- 两条绑定同 pid：`/clear` 的旧绑定清理没生效，检查 `resolve.ps1` 的 SessionStart 路径与状态目录写权限。

## 5. 验收 D：强杀后计划任务不残留

**目的**：强杀终端后计划任务不变成孤儿（User Story 18）。

### 命令

在验收 B 结束、死灯已自灭后执行：

```powershell
# drawer 自检应已自行注销；GC 再兜底一次（只读/幂等）
powershell -NoProfile -ExecutionPolicy Bypass -File .\resolve.ps1 -GcOnly

Get-ScheduledTask -TaskName 'traffic-light-*' |
    Select-Object TaskName, State
Get-ChildItem .\.traffic-light-states |
    Select-Object Name, LastWriteTime
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\manual\acceptance.ps1
```

### 预期

- `-GcOnly` 没有输出（没有要清理的对象），或只输出与死灯无关的旧格式清理行。
- 计划任务列表只剩存活终端（终端 2）的 `traffic-light-w<hwnd2>`；没有 `traffic-light-w<hwnd1>`。
- 状态目录里没有 `w<hwnd1>.win`；死会话的 `.state`/`.bind` 若还在，`acceptance.ps1` 会以 `FAIL ... gone` 标出，并在下一次 SessionStart 的 GC 清掉。
- `acceptance.ps1` 里终端 2 仍为 `PASS`，整体 `fail` 不应包含终端 1 的任务或锚。

### 通过判定

- 死 hwnd 对应的任务与锚**都不存在**。
- 重复执行 `-GcOnly` 与 `acceptance.ps1` 结果稳定（幂等），不会越跑越多。

### 失败排查

- 任务还在、锚已删：锚是任务存活的唯一依据，`resolve.ps1 -GcOnly` 应删除它；若删不掉，检查是否有管理员权限保护、任务是否被其他安装副本重建。
- 锚还在、任务没了：锚超过 10s 会被 GC；等到下一次 SessionStart 或 `-GcOnly`。若一直存在，用 `Get-Item` 看 mtime 是否被外部刷新。
- 旧格式任务（不带 `w<数字>`）反复出现：安装脚本的 GC 没跑或另一个版本仍在写，检查 `install.bat` / 钩子里的 `resolve.ps1 -GcOnly`。

## 6. 失败时的排查路径

统一从这里开始，按顺序看：

1. **drawer 日志** `.traffic-light-states\daemon.log`

   ```powershell
   Get-Content .\.traffic-light-states\daemon.log -Tail 40
   ```

   关注：`[SignalLight] drawer hwnd=... pid=... degraded=...` 启动行、Python Traceback、`window_gone` / `owner_mismatch` / `no_live_sessions` / `nonce_superseded` 等自灭原因。

2. **锚的 mtime**（心跳）

   ```powershell
   Get-Item .\.traffic-light-states\w<hwnd>.win |
       Select-Object Name, LastWriteTime
   ```

   正常情况下每次查看都应比上一次新（约 1s 一次）。连续 3s 不动 = drawer 死了或卡住。

3. **绑定字段**

   ```powershell
   Get-Content .\.traffic-light-states\<session_id>.bind
   ```

   必看：`pid`（CodeBuddy 进程）、`creation_ft`（防 PID 转世）、`hwnd`（0 = 降级）、`hwnd_owner_pid`（窗口宿主）、`degraded`（1 = 降级灯）、`updated`（超过 60s 表示绑定 TTL 过期，下一条提示会重解析）。身份字段写入后不应变化，只有 `hwnd` 可刷新。

4. **计划任务详情**

   ```powershell
   Get-ScheduledTask -TaskName 'traffic-light-*' | Get-ScheduledTaskInfo
   ```

   看 `LastRunTime`（有没有被重建）与 `LastTaskResult`（启动失败码）。

5. **降级灯**

   出现 `traffic-light-w0` 或绑定 `degraded=1`：该会话解析不到窗口。跑一次不带 `-Verdict` 的 `probe.ps1` 看 attach/GW_OWNER 段；恢复归窗后下一次 UserPromptSubmit 会自动重解析，降级灯自灭。

## 7. 记录模板

| 检查 | 命令/观测 | 预期 | 实际 | 判定 |
| --- | --- | --- | --- | --- |
| 前置 | 两终端 `probe -Verdict` | 两行 `verdict=go`，hwnd 不同 | | |
| A | `Get-ScheduledTask` + 锚清单 | 两个 `traffic-light-w<数字>`，锚/绑定各两份 | | |
| B | `taskkill /F` 一个终端，观察 3s | 另一盏不动；死灯 3s 内消失、任务消失 | | |
| C | `/clear` | nonce/drawer_pid/LastRunTime 不变，绑定换新，状态 idle | | |
| D | `resolve.ps1 -GcOnly` + 盘点 | 死 hwnd 的任务与锚都不存在 | | |

判定一栏只写 `通过` / `不通过`；不通过时把 §6 里对应的日志/字段原文贴进"实际"。
