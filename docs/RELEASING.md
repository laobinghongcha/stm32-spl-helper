# 发布说明

本文档面向**维护者**，说明如何把新版本发布到 GitHub Releases。
普通用户请直接看 [README](../README.md) 或 Releases 页面。

---

## 发布前检查清单

```
[ ] flutter analyze       → No issues found
[ ] flutter test          → 全部通过
[ ] python tools/validate_data.py --data assets/data   → 全部检查通过
[ ] python tools/check_zh_coverage.py                  → 覆盖率达标
[ ] 改动过数据？→ python tools/build_multi_lib.py 重跑并提交 assets/
[ ] pubspec.yaml 的 version 已递增（versionCode 必须比上一版大）
[ ] lib/utils/app_info.dart 的 appVersion 已同步
[ ] 没有把 android/key.properties 或 *.jks 提交进来
```

前四项可用一条命令跑：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/ci_check.ps1
```

---

## 构建签名 APK

### 1. 准备签名密钥（只需一次）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/make_keystore.ps1
```

脚本会生成 `android/release-keystore.jks` 与 `android/key.properties`，
并**打印出口令**。这两样东西已在 `.gitignore` 里，**不会被提交**。

> ⚠️ **务必备份 `release-keystore.jks` 和口令**。
> 丢了它就无法用同一个包名发布后续版本——已安装的用户永远收不到更新，
> 只能卸载重装（数据全丢）。

### 2. 一键发版

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/release.ps1 -Bump patch
```

脚本会：

1. 递增 `versionCode`（永远 +1）并按 `-Bump` 调整 `versionName`
2. 同步 `lib/utils/app_info.dart` 的 `appVersion`
3. 构建 release APK
4. 用 `apksigner verify` 验签并打印证书指纹
5. **回读 APK 里真实的 versionCode/versionName**，与 pubspec 比对

第 5 步是关键：只相信 APK 里真正写进去的值。

### 3. 打包发布物

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/make_github_release.ps1
```

在 `dist/` 下产出可直接上传 GitHub Releases 的文件：

```
dist/
  stm32-helper-2.0.2.apk        签名安装包
  SHA256SUMS.txt                校验值（用户可自行核对）
  RELEASE_NOTES.md              发布说明正文，复制到 Release 描述里
```

---

## 上传到 GitHub

**方式 A：网页手动上传（推荐，最省事）**

1. 打开仓库 → Releases → **Draft a new release**
2. Tag 填 `v2.0.2`（与 `versionName` 一致，前面加 `v`）
3. Title 填 `STM32 库函数助手 v2.0.2`
4. 描述：把 `dist/RELEASE_NOTES.md` 的内容粘进去
5. 附件：把 `dist/` 下的 `.apk` 与 `SHA256SUMS.txt` 一起拖进去
6. 点 **Publish release**

**方式 B：命令行 gh**

```bash
gh release create v2.0.2 \
  dist/stm32-helper-2.0.2.apk \
  dist/SHA256SUMS.txt \
  --title "STM32 库函数助手 v2.0.2" \
  --notes-file dist/RELEASE_NOTES.md
```

---

## 为什么 APK 不进仓库

`*.apk` 已在 `.gitignore` 里。原因：

1. **单文件 57 MB**，GitHub 单文件上限 100 MB，几次发版就逼近
2. **Git 历史不可删**：二进制一旦提交，即使后来 `git rm`，它仍留在
   `.git` 里，clone 的人照样要下。想真正清掉只能重写历史（`filter-repo`），
   所有 fork 和已 clone 的副本都会失效
3. Releases 本来就是这个用途：带版本标签、下载计数、校验值

> 如果之前的提交里已经混进了 APK，新仓库初始化时**不要**带上旧 `.git`。
> 发布包里的源码仓库是重新 `git init` 的干净历史。

---

## 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | 签名与已装版本不一致 | 确认用的是同一个 `release-keystore.jks`；对比 `apksigner` 指纹 |
| 装完还是旧版 / `DOWNGRADE` | `versionCode` 没增大 | `release.ps1` 已强制 +1 并回读校验；手改 pubspec 时别忘 |
| 装机后某库函数全 0 | assets 子目录没在 pubspec 声明 | Flutter 的 assets 声明**不递归**；`test/asset_bundle_test.dart` 会拦住 |
| 构建报 `dl.google.com` 超时 | 网络环境 | 见 `docs/build_env.md`，用国内镜像 |
