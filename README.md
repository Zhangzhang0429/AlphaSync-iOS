# AlphaSync iOS（手机端）

把安卓版 AlphaSync（索尼相机 PTP/IP 无线传图）移植到 iOS 的 Swift 工程。

- 语言/框架：Swift 5 + SwiftUI，iOS 17+，仅 iPhone
- 协议：与安卓端逐字节兼容的 PTP/IP（含厂商扩展），可连接同一套相机端 APK
- 构建：XcodeGen 描述工程，`xcodegen generate` 一键生成 `.xcodeproj`
- 无需本机装 Xcode：用仓库里的 GitHub Actions 在免费 macOS 云机器上出 IPA

## 目录结构

```
AlphaSync/
├── App/AlphaSyncApp.swift        App 入口 + 三 Tab 根视图
├── Protocol/                     PTP/IP 协议层（安卓端逐字节移植）
│   ├── PtpCodec.swift            帧/载荷编解码、Probe、FriendlyName、Hex
│   ├── TCPStream.swift           POSIX socket 封装（读线程 + 锁串行写）
│   ├── PtpIpClient.swift         控制连接：握手、事务、事件、PING/STAT/LIST_DIR 等
│   ├── DataChannel.swift         文件端口：START/DATA/END、批量取件
│   ├── Discovery.swift           UDP 广播/快扫/整段扫描
│   ├── PairingClient.swift       两步配对（PAIR_BEGIN/PAIR_EXCHANGE）
│   └── ObjectRepository.swift    会话管理 + 目录页 + 缩略图/预览 + 断点续传
├── Models/Models.swift           相机信息、配对记录、传输项、设置
├── Data/
│   ├── IdentityStore.swift       设备码 / GUID / 友好名
│   ├── PairingStore.swift        已配对相机表（本地镜像）
│   ├── SettingsStore.swift       全局设置
│   ├── StorageSinks.swift        落盘（Documents/AlphaSync）+ 存相册
│   ├── ThumbStore.swift          缩略图/预览磁盘缓存（LRU 限额）
│   └── TransferStore.swift       传输队列（.part 断点续传）
├── Services/
│   ├── ConnectionCenter.swift    连接状态机、心跳、事件、配对编排
│   └── LiveSync.swift            自动同步（边拍边传）巡检
├── Views/                        主界面/文件/传输/预览/配对/设置/本地文件
└── Assets.xcassets/AppIcon       应用图标
```

## 功能清单（与安卓手机端对齐）

| 功能 | 安卓端 | iOS 端 |
| --- | --- | --- |
| 扫描/发现相机（UDP 广播+快扫） | ✅ | ✅ |
| 两步配对（相机屏显示 6 位码） | ✅ | ✅ |
| 设备信息页（型号/序列号/固件/SSID） | ✅ | ✅ |
| 心跳电量/镜头/SD 容量 | ✅ | ✅ |
| 目录浏览 + 缩略图网格（新→旧） | ✅ | ✅ |
| 大图预览 + EXIF 信息 | ✅ | ✅ |
| 批量下载原图（含 RAW） | ✅ | ✅ |
| 断点续传（.part + 增量） | ✅ | ✅ |
| 传输队列（暂停/继续/重试/删除） | ✅ | ✅ |
| 边拍边传（自动同步新照片） | ✅ | ⚠️ 仅前台（见下） |
| 深色模式 / 动态取色 | ✅ | ✅ |
| 缓存限额 / 清理 | ✅ | ✅ |
| 已配对相机管理 | ✅ | ✅ |

## ⚠️ iOS 平台的已知限制

1. **后台边拍边传**：iOS 不允许 App 在后台保持长连接。自动同步在 App 前台时正常工作；
   退到后台后 iOS 会挂起网络，回到前台自动续跑。想边拍边传时请保持 App 在前台
   （可顺手开「设置 → 自动锁定 → 永不」避免锁屏断网）。
2. **RAW 文件**：系统相册不支持 ARW，RAW 只能保存到应用目录（可在「文件」App 的
   AlphaSync 文件夹中看到/分享）。jpg/mp4/mov 可在「设置 → 同时保存到系统相册」开启后
   自动进相册。
3. **本地网络权限**：首次启动会弹「本地网络」权限询问，必须点允许，否则无法发现相机。
4. **未签名 IPA 有效期为 7 天**（爱思助手 Apple ID 免费签名），到期后用爱思重签一次即可。

## 本地构建（有 Mac 时）

```bash
brew install xcodegen
xcodegen generate
open AlphaSync.xcodeproj
# Xcode 里选好签名 Team，⌘R 真机运行
```

## 云构建（无 Mac，小白推荐）

把仓库推到自己的 GitHub（公开），在 Actions 页手动运行
`Build iOS (unsigned IPA)`，产物在 Artifacts 下载 → 爱思助手签名安装。
详见《教程-GitHub与爱思签名.md》。

## 说明

- 本项目是从安卓端 `Phone/`（MIT 协议）移植的实现，协议与安卓端线格式逐字节兼容，
  相机端仍需安装原版 `AlphaSync-Camera` APK。
- 源码仅供学习交流。索尼私有接口来自逆向，请自行评估使用风险（与原项目免责声明一致）。
