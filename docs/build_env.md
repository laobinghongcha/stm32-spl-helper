# 构建环境

本项目的构建链路是 **Flutter → Gradle → Android SDK**。
本文记录在一台「没有预装 Flutter/Android SDK、且只能访问国内镜像」的机器上
从零跑通构建的完整步骤，供复现和排错使用。

如果你机器上已有完整环境，跳到 [最简命令](#最简命令) 即可。

---

## 版本要求

| 组件 | 版本 | 说明 |
|---|---|---|
| Flutter | 3.47.8 (stable) | Dart 3.13.7 |
| JDK | 17 | AGP 9 要求 JDK 17+ |
| Android SDK Platform | 36 | `compileSdk` 用 |
| Android SDK Platform | 34 | `share_plus` 等插件还需要 |
| Build Tools | 35.0.0 / 36.0.0 | |
| NDK | 28.2.13676358 | `shared_preferences_android` 的 `jni` 依赖需要 |
| CMake | 3.22.1 | 同上，编译 JNI 用 |
| Gradle | 9.3.1 | 由 Flutter 工程的 wrapper 指定 |

---

## 从零搭建

### 1. Flutter SDK

```powershell
curl.exe -L -o flutter.zip `
  "https://storage.flutter-io.cn/flutter_infra_release/releases/stable/windows/flutter_windows_3.47.8-stable.zip"
Expand-Archive flutter.zip -DestinationPath D:\sdk
```

`storage.flutter-io.cn` 是官方中国镜像，比 `storage.googleapis.com` 快得多。

### 2. JDK 17

```powershell
curl.exe -L -o jdk.zip "https://aka.ms/download-jdk/microsoft-jdk-17-windows-x64.zip"
Expand-Archive jdk.zip -DestinationPath D:\sdk\jdk
```

### 3. Android SDK 组件

`dl.google.com` 在某些网络下会超时。用腾讯镜像：

```powershell
$base = "https://mirrors.cloud.tencent.com/AndroidSDK"
# 平台
curl.exe -L -o platform-36.zip "$base/platform-36_r02.zip"
curl.exe -L -o platform-34.zip "$base/platform-34-ext7_r03.zip"
# 构建工具
curl.exe -L -o build-tools-35.zip "$base/build-tools_r35_windows.zip"
# NDK（约 750 MB）
curl.exe -L -o ndk.zip "$base/android-ndk-r28c-windows.zip"
# CMake
curl.exe -L -o cmake.zip "$base/cmake-3.22.1-windows.zip"
# platform-tools
curl.exe -L -o platform-tools.zip "$base/platform-tools_r37.0.1-win.zip"
```

解压后按 `android/platforms/android-36/`、`android/build-tools/35.0.0/`、
`android/ndk/28.2.13676358/`、`android/cmake/3.22.1/`、`android/platform-tools/`
的固定布局摆放。注意解压后可能多一层同名目录，要摊平。

> **CMake 要放在 `bin/` 子目录下**（`cmake/3.22.1/bin/cmake.exe`）。
> 官方 zip 解压出来是平铺的，Gradle 找不到会报
> `[CXX1300] CMake '3.22.1' was not found in SDK`。

### 4. Gradle 镜像

工程依赖 AGP、Kotlin 插件、AndroidX 等，全部走公网会很慢甚至超时。
在 `GRADLE_USER_HOME/init.d/` 下放一个 `cn-mirrors.gradle`：

```groovy
def CN_MAVEN = [
    'https://maven.aliyun.com/repository/google',
    'https://maven.aliyun.com/repository/central',
    'https://maven.aliyun.com/repository/gradle-plugin',
    'https://mirrors.cloud.tencent.com/nexus/repository/maven-public',
]

def noProjectRepos = [] as Set

def applyMirrors = { repoHandler ->
    repoHandler.removeAll { r ->
        def u = (r.hasProperty('url') && r.url != null) ? r.url.toString() : ''
        return u.contains('dl.google.com') ||
               u.contains('repo1.maven.org') ||
               u.contains('plugins.gradle.org')
    }
    CN_MAVEN.each { u -> repoHandler.maven { url = u } }
}

beforeSettings { settings -> applyMirrors(settings.pluginManagement.repositories) }

settingsEvaluated { settings ->
    try {
        def mode = settings.dependencyResolutionManagement.repositoriesMode.get()
        if (mode.name().contains('FAIL_ON_PROJECT_REPOS')) {
            applyMirrors(settings.dependencyResolutionManagement.repositories)
            noProjectRepos << settings.rootDir.absolutePath
        }
    } catch (Throwable ignored) { }
}

allprojects { proj ->
    if (noProjectRepos.contains(proj.rootDir.absolutePath)) return
    applyMirrors(proj.buildscript.repositories)   // 插件子项目也要走镜像
    applyMirrors(proj.repositories)
}
```

两个坑：

- **必须把 `dl.google.com` 的仓库整个移除**，不能只是「在它前面加镜像」。
  Gradle 遇到解析失败仍会去试后面那个不可达地址，每次卡几分钟超时。
- **插件子项目（`share_plus` 等）有独立的 `buildscript`**，
  只改 `allprojects.repositories` 不够，要连 `buildscript.repositories` 一起改。
- Flutter 自带的 included build（`flutter_tools/gradle`）声明了
  `FAIL_ON_PROJECT_REPOS`，不能往里注入 project 仓库，否则直接报错。

### 5. Gradle 发行版

Flutter 工程的 wrapper 指向 `services.gradle.org`，这个域名在国内经常超时。
预先用镜像塞进 `GRADLE_USER_HOME/wrapper/dists/`：

```powershell
$hashDir = "$env:GRADLE_USER_HOME\wrapper\dists\gradle-9.3.1-all\9ot9r568e8zfvvd4mn8rbu1j0"
New-Item -ItemType Directory -Force $hashDir
curl.exe -L -o "$hashDir\gradle-9.3.1-all.zip" `
  "https://mirrors.cloud.tencent.com/gradle/gradle-9.3.1-all.zip"
Expand-Archive "$hashDir\gradle-9.3.1-all.zip" -DestinationPath $hashDir
New-Item -ItemType File "$hashDir\gradle-9.3.1-all.zip.ok"
```

> 那个哈希目录名是 Gradle 按 distributionUrl 算出来的，不能自己编。
> 若不确定，先跑一次构建让它创建目录（会卡在下载），Ctrl+C 后看目录名。

### 6. 环境变量

一次性设置（新终端生效）：

```powershell
$env:FLUTTER_ROOT   = "D:\sdk\flutter"
$env:JAVA_HOME      = "D:\sdk\jdk\jdk-17.0.21.0.2+1"
$env:ANDROID_HOME   = "D:\sdk\android"
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:PUB_CACHE      = "D:\sdk\pubcache"
$env:GRADLE_USER_HOME = "D:\sdk\gradle-home"
$env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
$env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
$env:Path = "$env:FLUTTER_ROOT\bin;$env:JAVA_HOME\bin;$env:ANDROID_HOME\platform-tools;$env:Path"
```

> **Windows 上还有个坑**：如果 `TEMP` / `APPDATA` 所在目录被安全软件
> 或沙箱限制写入，`dart pub` 会报 `Creation of temporary directory failed`。
> 把 `TEMP`/`TMP`/`APPDATA` 指到一个可写目录即可。

---

## 最简命令

环境就绪后：

```powershell
cd <项目根>
flutter pub get
flutter analyze           # No issues found
flutter test              # 全部通过
flutter build apk --release
```

产物：`build/app/outputs/flutter-apk/app-release.apk`

> Gradle 原始产物在 `build/app/outputs/apk/release/app-release.apk`，
> Flutter 另外复制一份到 `flutter-apk/`。两者字节相同，用哪个都行。

---

## 排错

| 报错 | 原因 | 处理 |
|---|---|---|
| `Failed to find Platform SDK with path: platforms;android-34` | 缺 android-34 | 装上（`share_plus` 需要） |
| `[CXX1300] CMake '3.22.1' was not found` | CMake 没在 `bin/` 下 | 见上文第 3 步 |
| `NDK not configured` | 缺 NDK | 装 28.2.13676358 到 `ndk/` 下 |
| `Cannot snapshot .../libapp.so: not a regular file` | 构建目录被中断写坏 | `Remove-Item -Recurse build` 后重来 |
| `Creation of temporary directory failed` | TEMP 不可写 | 重设 `TEMP`/`TMP`/`APPDATA` |
| `Cannot access output property 'outputDir'` | 同上，增量构建状态损坏 | 清 `build/` |
| `repository 'maven' was added by settings file` | init script 往 `FAIL_ON_PROJECT_REPOS` 的 build 注入了仓库 | 见上文第 4 步的分支处理 |
