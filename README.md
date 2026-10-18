# 平安回家(离线) — iOS 版

将 GitHub 仓库 [dogproton/SafeBaiyun](https://github.com/dogproton/SafeBaiyun)（广州市白云区蓝牙门禁**离线**开锁 Android App）移植到 iPhone 的完整 Swift 工程。

> 协议逐行移植自原版 `LockBiz.kt` / `FDes.kt` / `ByteUtil.kt` / `UnlockRepo.kt`，已用 Python 交叉验证（DES/ECB/NoPadding 标准测试向量 + 报文结构/校验和），见 `ref/verify.py`。

---

## 一、可行性结论（先看这里）

| 方案 | 可行性 | 原因 |
|---|---|---|
| **网页 / H5 / PWA / 妙搭** | ❌ 不可行 | iPhone 上所有浏览器（Safari/Chrome/Edge）都是 WebKit 内核，**iOS Safari 不支持 Web Bluetooth API**（[MDN 兼容性表](https://developer.mozilla.org/en-US/docs/Web/API/Bluetooth) 明确 Safari on iOS = No），网页无法访问蓝牙门禁。飞书妙搭/任何 H5 平台同理，因此本功能无法用妙搭部署。 |
| **iOS 原生 App（本工程）** | ✅ 可行 | CoreBluetooth 支持完整 BLE GATT 流程，加密用系统 CommonCrypto 实现 DES/ECB/NoPadding，无需第三方依赖。 |

**结论：只能做 iOS 原生 App**，本工程即为成品源码。构建可用 Mac 本地方案，**没有 Mac 也能装**（GitHub 免费云编译 + 侧载，或付费 TestFlight 全程网页），见《无 Mac 安装指南.md》。

> 补充：如果你只求"能开门"且不介意联网/身份认证，也可以直接去 App Store 下载官方《平安回家》iOS 版；本工程是**离线**版本，不需要官方账号和网络，只需 MAC + Key。

---

## 二、你需要准备

> **没有 Mac？** 不影响。两条路都可装：① GitHub 免费云编译 + Windows 侧载（0 元，7 天重签一次）；② 付费 Apple 开发者账号 + TestFlight（$99/年，全程网页无需电脑）。详见同目录 **《无 Mac 安装指南.md》**。

1. **一台 Mac**（任意能装 Xcode 的型号，系统 macOS 13+）—— 仅"本地方案"需要；没有 Mac 见上方提示
2. **Xcode**（App Store 免费安装，建议 16 以上）—— 同上
3. **iPhone**（iOS 15 及以上）
4. **Apple ID**（免费即可，见签名说明）
5. 从安卓手机提取好的 **MAC 地址** 和 **加密 Key**（提取方法见原仓库 [extract.md](https://github.com/dogproton/SafeBaiyun/blob/main/extract.md)）

---

## 三、构建 & 安装（本地方案，需 Mac；无 Mac 走《无 Mac 安装指南.md》）

### 1. 打开工程
把 `SafeBaiyun-iOS` 整个文件夹拷贝到 Mac，双击 `SafeBaiyun.xcodeproj` 用 Xcode 打开。

### 2. 设置签名（自动签名）
- 菜单：`Xcode → Settings → Accounts`，登录你的 Apple ID。
- 回到工程，选中左侧 `SafeBaiyun` 项目 → `Targets: SafeBaiyun` → `Signing & Capabilities`
- `Team` 选择你的 Apple ID 账号，`Bundle Identifier` 保持 `com.safebaiyun.app`（如被占用可改成任意唯一值，如 `com.你的名字.safebaiyun`）。

### 3. 连接 iPhone 并运行
- iPhone 用数据线连 Mac，解锁屏幕并点"信任此电脑"。
- Xcode 顶部设备栏选择你的 iPhone，然后点 ▶ 运行（或 ⌘R）。
- 首次会提示"Developer Mode / 开发者模式"，按提示在 iPhone `设置 → 隐私与安全性 → 开发者模式` 开启并重启。

### 4. 信任开发者证书（仅首次）
运行后 iPhone 桌面出现"平安回家(离线)"图标，首次打开提示"未受信任的开发者"时：
`设置 → 通用 → VPN与设备管理 → 你的 Apple ID → 信任`。

### 签名方式说明
| 方式 | 成本 | 有效期 | 说明 |
|---|---|---|---|
| 免费 Apple ID（个人签名） | 0 元 | **7 天** | 到期后在 Xcode 里重新点一次 ▶ 即可续期，自用完全够 |
| Apple Developer 账号 | $99/年 | 1 年 | 一劳永逸，无需频繁重装 |

---

## 四、使用方法（与原 Android 版一致）

1. 打开 App，点右上角 **设置**，填入：
   - `MAC 地址`：如 `AA:BB:CC:DD:EE:FF`
   - `加密 Key`：连续十六进制字符串（从数据库 `t_device` 表提取，见原仓库 extract.md）
   - 点 **保存**（数据只存本机，不上传）
2. 回到主页，点 **开门（扫描门禁）**，走到门禁附近等待扫描
3. 在设备列表中**点选门禁设备**（通常显示为门禁名称或未知设备，可逐个尝试，选错会提示"未找到门禁服务"）
4. 自动完成：连接 → 订阅通知 → 读挑战值 → DES 加密 → 写回 → 提示"开门成功"

> ⚠️ iOS 隐私限制：App **看不到蓝牙设备的 MAC 地址**，所以不能像安卓那样按 MAC 直连，只能"扫描 + 点选"（MAC 仍用于校验和生成报文头部）。门禁就在身边时扫描，列表里一般只有一两个设备，很好辨认。

---

## 五、工程结构

```
SafeBaiyun-iOS/
├── SafeBaiyun.xcodeproj/        # Xcode 工程（直接双击打开）
├── project.yml                  # XcodeGen 备用定义（macOS: brew install xcodegen && xcodegen 可重新生成）
├── ref/verify.py                # 算法交叉验证脚本（DES 测试向量 + 报文结构）
└── SafeBaiyun/
    ├── SafeBaiyunApp.swift      # App 入口
    ├── ContentView.swift        # 主界面：扫描/开门/日志
    ├── SettingsView.swift       # 设置：MAC/Key 输入
    ├── UnlockManager.swift      # CoreBluetooth 开锁流程（对应 UnlockRepo.kt）
    ├── LockBiz.swift            # 加密协议（对应 LockBiz.kt/FDes.kt/ByteUtil.kt）
    ├── Info.plist               # 蓝牙权限声明等
    └── Assets.xcassets/         # 图标/主题色
```

## 六、已做的验证

- ✅ 加密协议：DES/ECB/NoPadding 通过 FIPS 标准测试向量；20 字节报文结构（头 0xA5、长度、类型、MAC[2:6]、校验和、尾 0x5A）校验通过
- ✅ 4 个 Swift 源文件通过 tree-sitter Swift 语法解析
- ✅ Xcode 工程文件（pbxproj）通过解析校验，目标/配置/引用全部闭合
- ⏳ 真机编译与实门开锁需在 Mac 上完成（本环境为 Linux 无法编译 iOS）

## 七、疑难排查

| 现象 | 处理 |
|---|---|
| 提示"未找到门禁服务" | 选错设备了，换列表里其他设备重试 |
| 提示"连接门禁失败" | 离门禁太远（<3-5 米），或门禁蓝牙未通电 |
| 开门失败/写入失败 | 核对 MAC 和 Key 是否与数据库完全一致（Key 大小写均可） |
| 7 天后打不开 | 免费签名到期，回 Xcode 重新点 ▶ 运行 |
| 首次运行闪退 | 检查是否已信任开发者证书（见三.4） |
