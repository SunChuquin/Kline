# iOS App 使用 GitHub Actions 免费自动构建 IPA 完整指南

> **适用场景**：在 Windows 电脑上开发 iOS App，无需 Mac，利用 GitHub Actions 云端 macOS 环境自动构建 `.ipa` 文件，配合 TrollStore 安装到设备。

**作者**：sunchuquin  
**日期**：2026-08-26  
**示例项目**：Kline（Bundle ID: `com.sunck.Kline`）

---

## 📋 目录

1. [前置条件](#前置条件)
2. [第一步：生成证书和描述文件](#第一步生成证书和描述文件)
3. [第二步：配置 GitHub Secrets](#第二步配置-github-secrets)
4. [第三步：创建工作流配置文件](#第三步创建工作流配置文件)
5. [第四步：推送代码触发构建](#第四步推送代码触发构建)
6. [第五步：下载并安装 IPA](#第五步下载并安装-ipa)
7. [常见问题排查](#常见问题排查)
8. [进阶提示](#进阶提示)

---

## 前置条件

| 项目 | 说明 |
| :--- | :--- |
| Apple ID | 免费即可（无需支付 $99/年） |
| iOS 项目源码 | 已有 `.xcodeproj` 或 `.xcworkspace` |
| GitHub 仓库 | 公开仓库（构建时长无限）或私有仓库（每月 2000 分钟免费） |
| Windows 工具 | Appuploader（生成证书用） |
| 目标设备 | iPad/iPhone，已开启开发者模式 |

> **免费账号限制**：签名的 IPA 安装后有效期为 **7 天**，过期需重新构建安装。

---

## 第一步：生成证书和描述文件

### 1.1 下载并安装 Appuploader

- 官网下载：`http://www.applicationloader.net/`
- 下载 Windows 版，解压后运行 `appuploader.exe`
- **前置依赖**：确保已安装 iTunes 和 iCloud（用于识别 iOS 设备）

### 1.2 登录 Appuploader

- 选择 **App 登录（App / xcode）** 方式
- 输入 Apple ID 和密码（需开启双重验证）
- 免费账号请勾选 **"未支付 688"** 选项
- 成功后可见账号类型为 `XCODE_FREE_USER`

### 1.3 生成开发证书 (.p12)

1. 左侧菜单点击 **「证书」**
2. 点击 **「新建」** → 选择 **`iOS App Development`**
3. 生成后下载 `.p12` 文件，**记下证书密码**
4. 用 PowerShell 将 `.p12` 转成 Base64：

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("你的证书.p12")) > cert_base64.txt
```

### 1.4 注册设备（可选）

- 如果设备未注册过，点击 **「设备」** → **「读取设备」** → **「注册」**
- Appuploader 会自动同步 Apple ID 下已注册的所有设备
- 建议将所有目标设备的 UDID 都注册到账号下

### 1.5 生成开发描述文件 (.mobileprovision)

1. 左侧菜单点击 **「描述文件」**
2. 点击 **「新建」** → 选择 **`iOS App Development`**
3. 选择刚才生成的证书
4. **勾选所有目标设备**（这样同一个 IPA 可安装到多台设备）
5. 填写描述文件名称（如 `MyDevProfile`），生成并下载 `.mobileprovision`
6. 用 PowerShell 转成 Base64：

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("描述文件.mobileprovision")) > profile_base64.txt
```

---

## 第二步：配置 GitHub Secrets

### 2.1 进入 Secrets 管理页面

- 打开你的 GitHub 仓库
- 点击顶部的 **Settings** 标签
- 左侧菜单找到 **Secrets and variables** → **Actions**
- 点击 **New repository secret**

### 2.2 添加三个 Secrets

| Secret 名称 | 值来源 |
| :--- | :--- |
| `CERTIFICATE_BASE64` | `cert_base64.txt` 的全部内容 |
| `CERTIFICATE_PASSWORD` | 生成 `.p12` 时设置的证书密码 |
| `PROVISION_PROFILE_BASE64` | `profile_base64.txt` 的全部内容 |

> ⚠️ **注意**：Base64 内容不要有多余空格、换行或引号，直接复制粘贴即可。

---

## 第三步：创建工作流配置文件

### 3.1 创建 ExportOptions.plist

在项目根目录创建 `ExportOptions.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
    <key>teamID</key>
    <string>你的团队ID（如 4G3V8W86TN）</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>你的Bundle ID（如 com.sunck.Kline）</key>
        <string>描述文件名称（如 MyDevProfile）</string>
    </dict>
</dict>
</plist>
```

> **获取 Team ID**：登录 Appuploader → 首页即可看到团队 ID。

### 3.2 创建 build.yml 工作流

创建 `.github/workflows/build.yml`：

```yaml
name: Build iOS IPA

on:
  push:
    branches: [ main ]
  workflow_dispatch:

jobs:
  build:
    runs-on: macos-latest
    
    steps:
      - uses: actions/checkout@v4
      
      - name: Setup Xcode
        uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: latest-stable

      - name: Import Certificate and Profile
        env:
          CERT_B64: ${{ secrets.CERTIFICATE_BASE64 }}
          CERT_PASS: ${{ secrets.CERTIFICATE_PASSWORD }}
          PROFILE_B64: ${{ secrets.PROVISION_PROFILE_BASE64 }}
        run: |
          echo "$CERT_B64" | base64 -d > cert.p12
          echo "$PROFILE_B64" | base64 -d > profile.mobileprovision
          
          security create-keychain -p temp build.keychain
          security unlock-keychain -p temp build.keychain
          security import cert.p12 -k build.keychain -P "$CERT_PASS" -A
          security set-key-partition-list -S apple-tool:,apple: -s -k temp build.keychain
          
          mkdir -p ~/Library/MobileDevice/Provisioning\ Profiles
          cp profile.mobileprovision ~/Library/MobileDevice/Provisioning\ Profiles/

      - name: Build Archive
        run: |
          # 使用 .xcworkspace（如使用 CocoaPods）
          xcodebuild -workspace Kline.xcworkspace \
            -scheme Kline \
            -configuration Release \
            -sdk iphoneos \
            -archivePath build/Kline.xcarchive \
            archive
          # 如使用 .xcodeproj，改为 -project Kline.xcodeproj

      - name: Export IPA
        run: |
          xcodebuild -exportArchive \
            -archivePath build/Kline.xcarchive \
            -exportOptionsPlist ExportOptions.plist \
            -exportPath build/

      - name: Upload IPA
        uses: actions/upload-artifact@v4
        with:
          name: Kline
          path: build/*.ipa
```

### 3.3 最终文件结构

```
项目根目录/
├── .github/
│   └── workflows/
│       └── build.yml          # 工作流文件
├── Kline.xcodeproj/            # Xcode 项目
├── Kline/                      # 源代码
├── ExportOptions.plist         # 导出配置
└── ...其他文件
```

---

## 第四步：推送代码触发构建

```bash
# 添加远程仓库
git remote add origin https://github.com/你的用户名/仓库名.git

# 推送代码
git branch -M main
git add .
git commit -m "添加 GitHub Actions 自动构建配置"
git push -u origin main
```

推送后，打开 GitHub 仓库的 **Actions** 标签页，即可看到工作流正在运行。

---

## 第五步：下载并安装 IPA

1. 构建成功后（绿色 ✅），在 Actions 页面底部找到 **Artifacts**
2. 点击下载 `Kline.zip`（名称取决于工作流中的 `name` 配置）
3. 解压得到 `.ipa` 文件
4. 通过微信、网盘、AirDrop 等方式传输到 iOS 设备
5. 用 **TrollStore** 打开 `.ipa` 文件进行安装

---

## 常见问题排查

| 报错信息 | 可能原因 | 解决方案 |
| :--- | :--- | :--- |
| `Provisioning profile does not include device` | 描述文件未包含目标设备的 UDID | 在 Appuploader 重新生成描述文件，勾选所有设备 |
| `No signing certificate matching "Apple Development"` | 证书未正确导入或已过期 | 检查 `CERTIFICATE_BASE64` 是否正确，重新生成证书 |
| `The workspace ... does not contain a scheme named ...` | Scheme 名称不匹配 | 确认 `-workspace` 和 `-scheme` 参数与项目一致 |
| `base64: invalid input` | Base64 字符串含多余换行或空格 | 重新复制 Secrets 中的 Base64 内容 |
| `xcodebuild: error: The project '...' does not contain a scheme` | 项目缺少共享 Scheme | 在 Xcode 中设置 Scheme 为 Shared 并提交 `.xcscheme` 文件 |

---

## 进阶提示

### 1. 支持多设备（同一 Bundle ID）

在生成描述文件时，**勾选所有目标设备的 UDID**，同一个 IPA 即可安装到多台设备。

### 2. 多 Target 项目

如果项目有多个 Target（如主 App + Extension），需要在 `ExportOptions.plist` 的 `provisioningProfiles` 字典中为每个 Bundle ID 指定对应的描述文件：

```xml
<key>provisioningProfiles</key>
<dict>
    <key>com.sunck.Kline</key>
    <string>MyDevProfile</string>
    <key>com.sunck.Kline.NotificationExtension</key>
    <string>MyExtensionProfile</string>
</dict>
```

### 3. 私有仓库 vs 公开仓库

| 仓库类型 | Actions 免费时长 | 适合场景 |
| :--- | :--- | :--- |
| 公开仓库 | **无限** | 开源项目、个人学习、愿意公开代码 |
| 私有仓库 | 每月 **2000 分钟** | 商业项目、闭源产品、初期调试 |

> 私有仓库可随时切换为公开，切换后 Stars 和 Forks 会重置，但 Actions 时长限制会立即解除。

### 4. 添加日志输出

在代码中大量使用 `os_log` 输出日志，方便在 Windows 上通过设备日志分析问题，弥补无法源码级调试的不足。

---

## 🎉 总结

通过这套方案，你可以：
- ✅ 在 **Windows 笔记本** 上完成全部 iOS 开发工作
- ✅ 利用 **GitHub Actions 免费云服务**自动构建 IPA
- ✅ 配合 **TrollStore** 将应用安装到多台设备
- ✅ 整个过程 **无需 Mac，无需 Xcode**

---

**文档版本**：1.0  
**更新日期**：2026-08-26  
**相关项目**：Kline (com.sunck.Kline)