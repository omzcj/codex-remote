# codex-remote

管理 ChatGPT Desktop 对 Codex managed app-server daemon 的复用。

该工具面向已经安装官方 standalone Codex、并明确使用
`CODEX_APP_SERVER_USE_LOCAL_DAEMON=1` 的 macOS 环境。它不安装 LaunchAgent，不会在
`enable` 中隐式安装、bootstrap 或升级 Codex。

## 安装

```sh
brew install omzcj/omzcj/codex-remote
```

如未安装 standalone Codex，先执行官方安装脚本：

```sh
curl -fsSL https://chatgpt.com/codex/install.sh | sh
```

## 命令

```sh
codex-remote                    # 等价于 status，只读
codex-remote status             # 查看版本、进程、socket、ownership 和 Desktop 后端
codex-remote start              # 检查、修复安全的运行时问题、打开并验证 Desktop
codex-remote stop               # 完全关闭 Desktop、复用环境和 shared daemon
codex-remote restart            # 强制 stop 后重新 start
codex-remote enable             # 启动并验证 managed daemon，然后让 Desktop 复用
codex-remote reset              # 关闭复用并彻底清理 shared daemon 运行状态
codex-remote update check       # 只检查 standalone Codex 更新
codex-remote update latest      # 更新到最新版
codex-remote update 0.153.4     # 安装或回滚到指定版本
```

`status` 会区分 `managed`、`unmanaged`、版本错位和 stale socket，而不是只根据
`daemon version` 是否成功判断。它会同时列出所有检测到的问题，并将 Desktop
安装/版本、runtime 清理、Codex 更新、智能启动和最终复查合并为一组
去重且有顺序的恢复步骤。对于新版不再返回 `backend` 字段的 daemon，会结合
`managedCodexPath`、control socket、官方可执行文件和 `--remote-control` 进程参数确认
ownership，避免对正常复用产生假阳性。无参数运行不会修改系统状态。

reuse 环境变量始终读写登录用户的 `gui/<uid>` launchd bootstrap domain；从 SSH 执行时
会通过一次性 LaunchAgent 完成写入，随后立即卸载。因此本地终端、Desktop 和 SSH 的行为
一致，远程执行 `enable` 后新启动的 ChatGPT 也能继承配置，且不需要 sudo。

`start` 是面向日常使用的幂等入口。健康时不打断会话；否则会在确认 PID、UID、进程
启动时间、可执行文件和 control socket ownership 后，自动清理安全的 unmanaged
app-server、stale runtime、残留 updater 或 unready daemon，再执行 `enable`，打开
ChatGPT 并等待它真正接入 managed daemon。可自动处理的动作会逐项记录。

安装缺失、Desktop 版本不兼容、Codex CLI 与 managed Codex 版本错位，以及无法证明身份的
socket/updater 进程不会被静默修改。`start` 会汇总所有 blocker，显示 PID、可执行文件和
命令行等已知证据，并给出按依赖排序、可复制的安装、检查、更新和重试命令。Desktop
版本不是已验证的 `26.818.61809` 时，可用 `start --force` 临时自行验证。

`stop` 是 `reset` 的日常名称，会完全关闭 Desktop、GUI reuse 环境和 shared daemon。
`restart` 总是执行完整的 stop/start，但会先运行 start preflight；如果恢复所需的安装或
进程身份存在 blocker，它不会先中断当前会话。`restart --force` 与 `start --force` 使用
相同的 Desktop 版本例外。

`enable` 和 `reset` 保留为底层生命周期/故障排查命令。`enable` 只接受官方 standalone
managed binary；发现 unmanaged app-server 时会要求先 `reset`。

`reset` 是故障恢复命令，会中断连接 shared daemon 的 Desktop、CLI、SSH 或移动端任务，
成功后保持 ChatGPT 关闭，避免它在后续 `enable` 前抢占 control socket。
它只终止占用当前 `CODEX_HOME` control socket 的精确 app-server PID 和经过校验的 updater
PID，不会使用 `pkill codex`，也不会删除配置、认证、线程、日志或 standalone releases。

`enable` 会启动 managed daemon、设置 GUI reuse 环境、打开或重启 ChatGPT，并等待 Desktop
真正连接后才返回成功。

`update` 只更新 standalone Codex/app-server，不更新 ChatGPT.app。运行中的 daemon 必须
处于 managed 状态；升级后工具会按需重启 daemon 和正在复用它的 Desktop。工具不会启动
自动 updater。

遇到 daemon 异常时，固定恢复流程为：

```sh
codex-remote start
```

## 为什么需要这些约束

从本地终端启动、从 SSH 启动和由 Finder 启动的进程不一定处在同一个 macOS launchd
bootstrap domain。SSH 中直接运行 `launchctl setenv` 可能只修改 Background domain，随后
由 GUI domain 启动的 ChatGPT 看不到该变量。因此本工具必须把 reuse 环境明确写入登录用户
的 `gui/<uid>` domain，而不能依赖调用它的 shell 环境。

另一个容易复现的问题是 reset/start 竞态：如果 reset 清理后立刻打开 ChatGPT，Desktop
可能在 managed daemon 启动前先创建普通 app-server 并抢占 control socket。因此 reset/stop
完成后必须保持 ChatGPT 关闭；start 先建立并验证 managed daemon 和 GUI 环境，最后才打开
Desktop。这也是 start 只自动终止“身份与 ownership 都可证明”的进程、restart 必须先做
preflight 的原因。
