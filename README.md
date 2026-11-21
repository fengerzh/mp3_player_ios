# 随听

一个简洁的 iPhone MP3 播放器，支持整文件夹导入、播放进度记忆、倍速播放和 Siri 语音控制。界面风格与安卓版 [mp3_player](https://github.com/fengerzh/mp3_player) 保持一致。

## 功能

- **整文件夹导入**：从「文件」App 选一个文件夹，自动递归扫描其中所有音频文件；复制在后台执行，界面实时显示导入进度，不卡死
- **按文件夹管理曲库**：可在不同文件夹之间切换，每个文件夹独立记忆上次播放的曲目和进度
- **播放控制**：播放/暂停、上一曲/下一曲、拖动进度条跳转、播完自动下一曲
- **倍速播放**：1× / 1.25× / 1.5× / 2× / 3×
- **后台播放**：切到后台或锁屏后继续播放
- **Siri 语音控制**：无需付费开发者账号，见下方说明
- **存储可控**：同一文件夹重复导入为增量同步（复用已有文件、保留进度，只新增或删除差异）；单曲按文件名去重；文件夹可左滑删除；启动时自动清理孤儿文件；音频目录不进 iCloud 备份

## Siri 语音控制

对 Siri 说以下任意一句即可控制播放：

- 「嘿 Siri，用随听继续播放」
- 「嘿 Siri，随听继续播放」
- 「嘿 Siri，用随听暂停播放」
- 「嘿 Siri，随听暂停」

「继续播放」会从上次保存的进度接着播，不是从头开始。基于 **App Intents** 实现，不需要 Siri capability、不需要加入付费开发者计划。短语在首次安装或重装后需要跟 Siri 说几遍磨合识别。注意：裸喊「继续播放」不带 App 名字会被系统音乐 App 抢占，所以短语里都带「随听」。

## 构建与安装

1. 用 Xcode 打开 `MP3Player.xcodeproj`
2. 选择目标设备（模拟器或你自己的 iPhone）
3. 在 Signing 里选自己的 Apple ID（Personal Team），勾上「Automatically manage signing」
4. 真机首次安装需要在 iPhone 上信任开发者：*设置 → 通用 → VPN 与设备管理*，并在 *设置 → 隐私与安全性 → 开发者模式* 中打开开发者模式
5. Command + R 运行

免费 Apple ID 签名的 App **7 天后会过期**，到期后重新用 Xcode 构建安装一次即可，歌曲和进度数据不会丢。

命令行构建（Xcode 某些版本的 Swift 宏插件沙箱问题需要加 `-disable-sandbox`）：

```bash
# 模拟器
xcodebuild -project MP3Player.xcodeproj -scheme MP3Player \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  OTHER_SWIFT_FLAGS="-disable-sandbox" build

# 真机（DEVICE_ID 换成你手机的 UDID）
xcodebuild -project MP3Player.xcodeproj -scheme MP3Player \
  -destination 'platform=iOS,id=DEVICE_ID' \
  -allowProvisioningUpdates OTHER_SWIFT_FLAGS="-disable-sandbox" build
```

## 技术栈

- Swift 5 / SwiftUI / AVFoundation，最低 iOS 17
- App Intents + AppShortcutsProvider（Siri、快捷指令、聚焦搜索通用）
- 本地 JSON 持久化曲库元数据，音频文件复制进 App 沙盒 Documents/Tracks
- 无第三方依赖，无 CocoaPods / SPM

## 项目结构

```
MP3Player/
├── MP3PlayerApp.swift   — App 入口，全局 tint 主题
├── ContentView.swift    — 主界面、文件夹切换、导入进度遮罩
├── Models.swift         — LibraryStore、Folder/Track 数据模型、导入/增量同步/清理逻辑
├── AudioEngine.swift    — AVPlayer 播放引擎、进度保存与恢复
├── SiriSupport.swift    — 共享 PlaybackController、Siri Intents、短语注册
└── Info.plist           — 显示名「随听」、后台音频模式
```
