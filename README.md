# codex-remote

管理 ChatGPT Desktop 对 Codex managed app-server daemon 的复用。

该工具面向使用 `CODEX_APP_SERVER_USE_LOCAL_DAEMON=1` 的 macOS 环境。它不安装常驻
LaunchAgent。`start` 是完整的状态收敛入口，会按本工具固定的策略安装或恢复 ChatGPT
Desktop 和官方 standalone Codex，不把已知恢复步骤交给用户选择。

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
codex-remote status             # 只读显示事实和全部检测问题，不生成操作建议
codex-remote start              # 自动收敛全部已知问题、打开并验证 Desktop
codex-remote stop               # 完全关闭 Desktop、复用环境和 shared daemon
codex-remote restart            # 无论当前是否启动，确保停止后重新收敛到运行状态
codex-remote update check       # 只检查 standalone Codex 更新
codex-remote update latest      # 更新到最新版
codex-remote update 0.153.4     # 安装或回滚到指定版本
```

`status` 会区分 `managed`、`unmanaged`、版本错位和 stale socket，而不是只根据
`daemon version` 是否成功判断。它会同时列出所有检测到的问题，但不会输出恢复菜单或要求
用户组合命令。对于新版不再返回 `backend` 字段的 daemon，会结合
`managedCodexPath`、control socket、官方可执行文件和 `--remote-control` 进程参数确认
ownership，避免对正常复用产生假阳性。无参数运行不会修改系统状态。

交互式终端中的 `status` 会用红色突出异常、黄色标记停止或等待状态，并只对关键健康状态
使用绿色。通过管道、重定向或非 TTY SSH 执行时保持纯文本；设置 `NO_COLOR` 或使用
`TERM=dumb` 也会关闭颜色。远程查看颜色时可使用 `ssh -t HOST codex-remote status`。

reuse 环境变量始终读写登录用户的 `gui/<uid>` launchd bootstrap domain；从 SSH 执行时
会通过一次性 LaunchAgent 完成写入，随后立即卸载。因此本地终端、Desktop 和 SSH 的行为
一致，远程执行 `start` 后新启动的 ChatGPT 也能继承配置，且不需要 sudo。

`start` 是面向日常使用的幂等闭环入口。健康时不打断会话；否则会先确认 PID、UID、进程
启动时间、可执行文件和 control socket ownership，然后自动完成固定 ChatGPT Desktop 的
安装或恢复、standalone Codex 的安装和版本统一，并清理安全的 unmanaged app-server、stale
runtime、残留 updater 或 unready daemon。它会显式启用 Remote Control，启动 managed
daemon，打开 ChatGPT 并等待 Desktop 真正接入。首次接入失败时会自动执行一次有上限的
daemon/Desktop 重试，最终只返回成功或一个无法安全自动处理的 blocker。
运行中的 daemon 如果已经由 control socket、官方可执行文件和 `--remote-control` 参数
确认处于 managed 模式，`start` 会直接复用，不再要求生命周期命令重复 enable。

每次 `start` 都会在登录用户的 GUI launchd 环境中设置
`CODEX_SPARKLE_ENABLED=false`。这是固定版 Desktop 在创建 updater 前读取的启动门控；
相比会被应用运行期间重新写回的 `SUEnableAutomaticChecks` 和 `SUAutomaticallyUpdate`
首选项，它是自动更新是否真正被禁用的权威状态。工具仍会将这两个旧首选项写为 `false`
作为辅助防线。如果正在运行的 ChatGPT 尚未继承 updater 门控，`start` 会自动关闭并重新
打开一次；已经健康的 managed daemon 不会因此重启。随后工具会同时验证进程环境、
daemon ownership 和 Desktop attachment。`stop` 不会
清除 updater 门控，因此以后直接打开 ChatGPT 也会保持禁用自动更新。

ChatGPT 缺失或版本不是 `26.818.61809` 时，`start` 会通过
`omzcj/omzcj/chatgpt` 自动安装或恢复固定版本。standalone Codex 缺失，或者 PATH CLI 与
managed Codex 错位时，`start` 会通过官方安装器统一到当前 latest release。只有无法证明
身份的 socket/updater 进程、缺少 Homebrew、认证或网络失败等不能安全猜测的条件才会阻止
收敛；失败只报告具体 blocker，不输出多套下一步方案。

`stop` 会完全关闭 Desktop、GUI reuse 环境和 shared daemon。
`restart` 定义为 `ensure-stopped + start`。已经启动时会强制重建；完全停止时不会因
`not running` 失败，而是直接进入 `start`；部分启动时会清理后进入相同的闭环收敛。
`restart` 会先验证未知进程 ownership，避免在真正无法安全处理时先中断当前会话。
`start` 在自动清理运行状态后还会重新恢复固定 Desktop，因为 ChatGPT 可能在退出时应用
之前已经下载的更新，导致磁盘版本在同一次操作中发生变化。

`stop` 会中断连接 shared daemon 的 Desktop、CLI、SSH 或移动端任务，成功后保持 ChatGPT
关闭，避免它在后续 `start` 前抢占 control socket。
它只终止占用当前 `CODEX_HOME` control socket 的精确 app-server PID 和经过校验的 updater
PID，不会使用 `pkill codex`，也不会删除配置、认证、线程、日志或 standalone releases。
如果官方 `daemon stop` 拒绝一个已经由 socket、可执行文件、UID、启动时间和命令行
共同确认的 managed 进程，`stop` 会使用同一套身份校验安全终止该 PID，避免生命周期元数据
错位使闭环永久卡住；任何身份不明确的进程仍会原样保留并报告 blocker。

`update` 只更新 standalone Codex/app-server，不更新 ChatGPT.app。它会自动收敛可安全识别
的 managed 或 unmanaged runtime，更新后恢复之前处于活动状态的 daemon 和 Desktop；原本
完全停止时仍保持停止。工具不会启动自动 updater。

遇到 daemon 异常时，固定恢复流程为：

```sh
codex-remote start
```

## 为什么需要这些约束

从本地终端启动、从 SSH 启动和由 Finder 启动的进程不一定处在同一个 macOS launchd
bootstrap domain。SSH 中直接运行 `launchctl setenv` 可能只修改 Background domain，随后
由 GUI domain 启动的 ChatGPT 看不到该变量。因此本工具必须把 reuse 环境明确写入登录用户
的 `gui/<uid>` domain，而不能依赖调用它的 shell 环境。

另一个容易复现的问题是 stop/start 竞态：如果 stop 清理后立刻打开 ChatGPT，Desktop
可能在 managed daemon 启动前先创建普通 app-server 并抢占 control socket。因此 stop
完成后必须保持 ChatGPT 关闭；start 先建立并验证 managed daemon 和 GUI 环境，最后才打开
Desktop。这也是 start 只自动终止“身份与 ownership 都可证明”的进程、restart 必须先做
preflight 的原因。
