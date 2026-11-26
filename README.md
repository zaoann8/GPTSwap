# gptswap

轻量的 macOS Codex 账号切换工具。在菜单栏查看额度、切换登录，继续使用原来的本地对话。

## 功能

- 管理多个账号，一键切换并重新打开 Codex。
- 保留原有本地工作区与对话记录。
- 查看 5 小时、7 天剩余额度，默认优先展示 5 小时。
- 菜单栏轮播剩余额度与重置倒计时，使用实际读数，后台自动刷新。
- 分开展示订阅有效期与重置卡到期时间。
- 支持 Dock 开关、登录启动、低额度提醒和多语言。
- 本地保存备用登录，不转发模型请求，不走反代。

## 使用

1. 安装并登录官方 Codex 桌面应用。
2. 打开 gptswap，在「管理账号」中添加账号。
3. 等待 Codex 当前任务结束，从菜单栏选择目标账号。
4. Codex 重新打开后，从「最近」继续原来的对话。

## 本地构建

需要 macOS 14+、Swift 6.2+ 和匹配的 Xcode 或 Command Line Tools。

```sh
git clone https://github.com/zaoann8/GPTSwap.git
cd GPTSwap
./scripts/package-local-app.sh
```

脚本在 `.build/` 下生成 `gptswap.app` 并输出路径。没有外部 Swift Package 依赖，工具链齐全后可离线构建。

当前打包版校验 `/Applications/ChatGPT.app` 及其内置 Codex 的官方签名；其他安装路径或应用布局暂不保证兼容。

```sh
./scripts/run-tests.sh
```

## 许可

[MIT License](LICENSE)。保留既有开源代码的版权声明。本项目不隶属于 OpenAI。
