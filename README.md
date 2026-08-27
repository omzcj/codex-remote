# codex-remote

手动让 ChatGPT Desktop 复用 Codex managed app-server daemon。

## 使用

```sh
brew install omzcj/omzcj/codex-remote

codex-remote          # 启用复用，等价于 start
codex-remote status   # 查看当前状态
codex-remote restart  # 重启 daemon 和 ChatGPT
codex-remote disable  # 取消 Desktop 复用
codex-remote --help
```

`start` 会在需要时启动 daemon，并重启正在运行的 ChatGPT。`disable` 会重启 ChatGPT，
但不会停止 daemon，以免中断其他远程连接。
