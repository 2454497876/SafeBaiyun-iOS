# 没有 Mac 怎么安装？（两条路）

> 核心事实：**编译 iOS 应用只需要"苹果的编译服务"，不一定需要你手头的 Mac 电脑**。
> GitHub Actions 免费提供 macOS 云编译机（公共仓库不花钱），本工程已配好一键构建脚本（`.github/workflows/build-ipa.yml`）。
> 装到 iPhone 这一步，也只需要 Windows 电脑 + 免费 Apple ID，不需要 Mac。

| 路径 | 花费 | 需要什么 | 有效期 | 适合 |
|---|---|---|---|---|
| **A. GitHub Actions + Sideloadly（免费）** | 0 元 | 一台 Windows 电脑 + 免费 Apple ID + 免费 GitHub 账号 | 7 天/次（到期重装，2 分钟） | 手头有 Windows 电脑 |
| **B. 付费开发者账号 + Codemagic + TestFlight（网页全流程）** | $99/年 | 只要 iPhone 和网络（全程网页操作，不需要任何电脑） | 1 年（一劳永逸） | 没有 Windows / 想省事 |

> ⚠️ 不推荐淘宝/网上的"免签名安装"服务：属于灰产，有盗号与恶意签名风险。
> ⚠️ 免费签名（路径 A）的 Apple ID 仅用于自装，不影响你手机其他功能。

---

## 路径 A：免费方案（推荐，需一台 Windows 电脑）

### 第 1 步：把工程放到 GitHub（约 5 分钟）
1. 注册 GitHub 账号：https://github.com/signup （免费）
2. 登录后点右上角 `+` → `New repository`
   - 仓库名随意，如 `SafeBaiyun-iOS`
   - **Public（公开）**：公开仓库才免费使用 macOS 云构建机
   - 勾选 `Add a README` 与否均可，其他默认，点 Create
3. 把 `SafeBaiyun-iOS` 文件夹里的**全部内容**（含 `.github` 隐藏文件夹）上传：
   - 进入仓库 → `Add file` → `Upload files` → 把整个文件夹拖进去 → Commit
   - 确认仓库里能看到 `.github/workflows/build-ipa.yml`

### 第 2 步：触发构建（约 3 分钟）
1. 打开仓库顶部 `Actions` 标签 → 左侧 `Build IPA`
2. 点 `Run workflow` → `Run workflow`（绿色按钮）
3. 等任务跑完（macOS 机器编译约 2-3 分钟），进入这次运行的详情页

### 第 3 步：下载 IPA
1. 运行详情页底部 `Artifacts` → 下载 `SafeBaiyun-ipa`
2. 解压得到 `SafeBaiyun-unsigned.ipa`

### 第 4 步：用 Sideloadly 签名安装到 iPhone（约 5 分钟）
1. Windows 电脑下载 Sideloadly：https://sideloadly.io/ （免费）
2. iPhone 用数据线连 Windows，解锁并点"信任此电脑"
3. 打开 Sideloadly：
   - 拖入 `SafeBaiyun-unsigned.ipa`
   - Apple ID 填你的（免费即可）
   - 点 `Start`，首次会提示"信任此电脑"，iPhone 上输一次锁屏密码
4. 安装完成后，iPhone `设置 → 通用 → VPN与设备管理 → 你的 Apple ID → 信任`
5. 打开"平安回家(离线)"，填 MAC 和 Key 即可开门（用法同 README 第四节）

### 7 天到期怎么办？
免费 Apple ID 签名的应用 **7 天**后失效，打不开时重复「第 4 步」重装一次（约 2 分钟）。
到期前 Sideloadly 打开也会有"即将到期"提示，重装即可，数据（MAC/Key）不丢。

---

## 路径 B：付费方案（$99/年，全程网页，不需要任何电脑）

适合没有 Windows 电脑、或不想每周重装的人。全程在手机/浏览器完成：

1. **注册 Apple 开发者账号（$99/年）**
   - https://developer.apple.com/programs/enroll/ ，按网页流程填写（个人开发者即可，需身份信息）
2. **注册 Bundle ID**
   - 登录 https://developer.apple.com/account → `Identifiers` → `+` → `App IDs`
   - 填 `com.safebaiyun.app`（或任意唯一值）
3. **生成 App Store Connect API Key（用于云端自动签名）**
   - 打开 https://appstoreconnect.apple.com/access/integrations → `+` 新建密钥
   - 下载 `.p8` 密钥文件，记下 Key ID 和 Issuer ID（只显示一次，妥善保存）
4. **注册 Codemagic（免费额度）并配置自动构建**
   - https://codemagic.io/start/ 用 GitHub 登录，授权读取你的仓库
   - 选择 `SafeBaiyun-iOS` 仓库 → iOS 构建设置：
     - `Build type: iOS app`
     - `Code signing: App Store Connect API Key`，填入上一步的 Key ID / Issuer ID / .p8
     - `Distribution: TestFlight`（首次会引导你在 App Store Connect 建 App 记录）
   - 点构建，完成后会自动上传到 TestFlight
5. **iPhone 上安装**
   - App Store 下载官方 **TestFlight** App，用同一 Apple ID 登录
   - 等 Apple 审核通过内测构建（通常几十分钟~几小时，TestFlight 会通知）
   - 在 TestFlight 里点"平安回家(离线)"安装（内测版 90 天有效，到期重新构建一次即可）

> 该路径的优点是**一年不用管**；缺点是每年 $99 和首次配置略繁琐。
> 如果以后有 Mac 了，直接用 README 第三节的本地方案即可，三条路共用同一个工程。

---

## 遇到问题？

| 现象 | 处理 |
|---|---|
| Actions 报错找不到工程 | 确认上传时 `.github` 文件夹在仓库根目录、`SafeBaiyun.xcodeproj` 也在根目录 |
| Actions 一直不跑 | 手动点 `Run workflow`；或确认仓库是 Public |
| Sideloadly 报 Apple ID 错误 | 换一个 Apple ID；关闭 iPhone 上"查找"的其它账号登录冲突 |
| 安装后图标是灰色/打不开 | 未信任证书：`设置 → 通用 → VPN与设备管理 → 信任` |
| TestFlight 提示不可用 | 等待审核通过；确认构建状态为 `Ready to Submit` / `In TestFlight` |
