# HISVPN

多平台代理客户端，支持 Android / iOS / Windows / macOS / Linux。

## 构建

```bash
git submodule update --init --recursive
flutter pub get
```

| 平台 | 命令 |
|---|---|
| Android | `dart setup.dart android` |
| Windows | `dart setup.dart windows` |
| macOS | `dart setup.dart macos` |
| Linux | `dart setup.dart linux` |
| iOS | `flutter build ios --release --no-codesign` |

Go 核心与 Rust 辅助程序在 `flutter build` 时由构建钩子自动编译，无需手动操作。

- iOS 构建与 VPN 隧道状态见 [docs/IOS_BUILD.md](docs/IOS_BUILD.md)
- CI 出包：`.github/workflows/build-ios.yml`（macOS runner 自动产出未签名 IPA）
