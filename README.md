# gptswap

A lightweight macOS account switcher for Codex. Check remaining quota, switch accounts from the menu bar, and keep using your existing local chats.

## Features

- Manage multiple accounts with one-click switching and automatic Codex restart.
- Keep your existing local workspaces and chat history.
- View remaining quota for the 5-hour and 7-day windows, with the 5-hour window shown by default.
- Rotate between remaining quota and the reported reset time in the menu bar: `22:09` today, or `11/28 22:09` on another day, in your local time zone. Readings refresh automatically in the background.
- Show subscription expiration and reset credit expiration separately.
- Configure Dock visibility, launch at login, low-quota notifications, and display language.
- Store saved logins locally without forwarding model requests or using a reverse proxy.

## Usage

1. Install the official Codex desktop app and sign in.
2. Open gptswap and add accounts under **Manage Accounts**.
3. Wait for any running Codex tasks to finish, then select an account from the menu bar.
4. Once Codex reopens, continue an existing chat from your recent chats.

## Build Locally

Requires macOS 14+, Swift 6.2+, and a compatible Xcode or Command Line Tools installation.

```sh
git clone https://github.com/zaoann8/GPTSwap.git
cd GPTSwap
./scripts/package-local-app.sh
```

The script creates `gptswap.app` under `.build/` and prints its path. There are no external Swift Package dependencies, so builds can run offline once the toolchain is installed.

The current packaged app verifies the official signatures of `/Applications/ChatGPT.app` and its bundled Codex executable. Other installation paths or app layouts are not guaranteed to work.

```sh
./scripts/run-tests.sh
```

## License

[MIT License](LICENSE)
