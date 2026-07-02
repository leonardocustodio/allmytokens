# AllMyTokens

A macOS menu-bar app that shows your Claude and Codex subscription usage — the 5-hour session window, the weekly window, and per-model limits, each with its reset time.

It reads the same subscription rate-limit data the official CLIs use, so there's no API key and no API billing: you sign in with your existing Claude (Pro/Max) or ChatGPT (Codex) subscription.

## Features

- **Menu-bar item** with a live usage summary for every connected account.
- **Widgets** (small, medium, large) for Notification Center, with Dark and Light themes and a per-widget account/metric picker.
- **Multiple accounts** across providers — connect several Claude and Codex logins side by side.
- **Reset notifications**, toggled per account (also from the widget's bell).
- **Runs as a background agent** — no Dock icon, just the menu bar.

## How it works

Sign-in uses OAuth (the same public clients as Claude Code and the Codex CLI). Tokens are stored in the macOS Keychain; the only network traffic is the OAuth exchange and the usage fetch to Anthropic/OpenAI. The app and its widget share data through an App Group.

Adding a provider means implementing `UsageProvider` (`AllMyTokens/Providers.swift`) and listing it in the registry — connection and usage-querying are behind that one interface.

## Requirements

- macOS 26 or later
- Xcode 26 or later

## Build & run

Open `AllMyTokens.xcodeproj` in Xcode, select the **AllMyTokens** scheme, and run. The widget extension builds and installs with the app.

The app and widget share the `group.me.custodio.AllMyTokens` App Group; if you fork this under your own team, update the group identifier and bundle IDs to match your signing.

## Project layout

- `AllMyTokens/` — the menu-bar app: auth (`AnthropicAuth`, `OpenAIAuth`), usage clients (`UsageEngine`, `CodexUsageClient`), the `UsageProvider` abstraction, the `UsageStore` coordinator, and the SwiftUI dashboard (`ContentView`).
- `Widget/` — the WidgetKit extension.
- `AllMyTokens/Shared/UsageSnapshot.swift` — the data contract shared between the two targets (duplicated in `Widget/` because they compile as separate binaries).

## Notes

This is a personal-use tool. It connects your own subscription and reuses the official CLIs' OAuth clients. "Claude" and "Codex/ChatGPT" are trademarks of Anthropic and OpenAI respectively.
