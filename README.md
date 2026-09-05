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
codex-remote enable             # 启动并验证 managed daemon，然后让 Desktop 复用
codex-remote reset              # 关闭复用并彻底清理 shared daemon 运行状态
codex-remote update check       # 只检查 standalone Codex 更新
codex-remote update latest      # 更新到最新版
codex-remote update 0.153.4     # 安装或回滚到指定版本
```

`status` 会区分 `managed`、`unmanaged`、版本错位和 stale socket，而不是只根据
`daemon version` 是否成功判断。无参数运行不会修改系统状态。

`enable` 只接受官方 standalone managed binary。发现 unmanaged app-server 或 stale
socket 时会拒绝继续，并要求先运行 `reset`。ChatGPT Desktop 版本不是已验证的
`26.818.61809` 时，默认拒绝启用；如需自行验证可使用 `enable --force`。

`reset` 是故障恢复命令，会中断连接 shared daemon 的 Desktop、CLI、SSH 或移动端任务。
它只终止占用当前 `CODEX_HOME` control socket 的精确 app-server PID 和经过校验的 updater
PID，不会使用 `pkill codex`，也不会删除配置、认证、线程、日志或 standalone releases。

`update` 只更新 standalone Codex/app-server，不更新 ChatGPT.app。运行中的 daemon 必须
处于 managed 状态；升级后工具会按需重启 daemon 和正在复用它的 Desktop。工具不会启动
自动 updater。

遇到 daemon 异常时，固定恢复流程为：

```sh
codex-remote reset
codex-remote enable
```
