# codex-remote

在 macOS 上手动启用 ChatGPT Desktop 对 Codex managed app-server daemon 的复用。
它不安装、不生成，也不依赖 LaunchAgent；需要时由用户主动运行命令。

> 这是对 ChatGPT Desktop 隐藏行为的个人工具，不是 OpenAI 官方支持的配置界面。
> 已验证 ChatGPT `26.818.61809` 可用；更高版本可能改变或移除该行为。

## 安装

源码仓库是私有仓库，安装前需要确保 GitHub SSH 可用：

```sh
ssh -T git@github.com
```

然后通过个人 Homebrew Tap 安装：

```sh
brew tap omzcj/omzcj
brew install codex-remote
```

## 使用

直接运行等价于 `start`：

```sh
codex-remote
```

它会依次：

1. 查找 `~/.local/bin/codex` 或 `PATH` 中的 Codex CLI；找不到时运行官方安装脚本。
2. 在当前 macOS GUI 登录会话中设置 `CODEX_APP_SERVER_USE_LOCAL_DAEMON=1`。
3. 按需执行 daemon bootstrap，并启动 managed app-server daemon。
4. 如果 ChatGPT 已打开，将其关闭并重新打开，让新进程继承环境变量。

其他命令：

```sh
codex-remote status   # 只读检查 daemon 与 Desktop 的实际连接
codex-remote restart  # 手动重启 daemon 和 ChatGPT
codex-remote disable  # 取消复用并重启 ChatGPT，但保留 daemon
codex-remote --help
```

`disable` 不停止 daemon，因为 iPhone 上的 ChatGPT Remote SSH 可能仍在使用它。

## 无后台服务

Homebrew Formula 只安装 `codex-remote` 可执行文件，不提供 `service` block，也不会创建
`~/Library/LaunchAgents`。重启或重新登录后，需要时再次手动运行：

```sh
codex-remote
```

## 本地开发

```sh
sh -n ./codex-remote
./codex-remote --version
./codex-remote --help
./codex-remote status
```

可用环境变量：

- `CODEX_REMOTE_CODEX_BIN`：覆盖 Codex CLI 路径。
- `CODEX_REMOTE_CHATGPT_APP`：覆盖 `ChatGPT.app` 路径。
- `CODEX_REMOTE_CHATGPT_BUNDLE_ID`：覆盖 ChatGPT bundle identifier。

## 发布

版本由 `VERSION` 与脚本中的 `PROGRAM_VERSION` 共同维护。发布新版本时创建相同版本的 Git tag：

```sh
git tag v0.1.0
git push origin main --tags
```

随后更新 `homebrew-omzcj/Formula/codex-remote.rb` 的 tag、revision 与 version。
