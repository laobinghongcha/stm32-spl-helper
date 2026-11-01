param(
    # 版本号递增方式：build 只加 versionCode，patch/minor/major 同时改 versionName
    [ValidateSet("build", "patch", "minor", "major")]
    [string]$Bump = "patch",

    # 只验证已有产物，不重新构建
    [switch]$VerifyOnly,

    # 不动版本号，直接用当前 version 构建
    [switch]$NoBump
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# 一键发版：递增版本号 → 构建 → 验签 → 校验版本 → 汇总产物
#
# 为什么要有这个脚本：升级安装要求两件事同时成立
#   1. 签名一致（否则 Android 直接拒绝，报 INSTALL_FAILED_UPDATE_INCOMPATIBLE）
#   2. versionCode 比已装的大（否则静默不装，或报 DOWNGRADE）
# 手工改 pubspec 很容易漏掉 +1（versionCode 不变就等于没升级），
# 所以把这两件事固化成脚本，并且**构建后回读 APK 校验**，
# 而不是只相信 pubspec 写对了。
# ---------------------------------------------------------------------------

$projectRoot = Split-Path -Parent $PSScriptRoot
$pubspecPath = Join-Path $projectRoot "pubspec.yaml"
$outputDir = Join-Path $projectRoot "build\app\outputs"

# 环境（与 README 里记录的一致，已配成用户级环境变量时也可省略）
if (-not $env:JAVA_HOME) { $env:JAVA_HOME = "D:\Jave" }
if (-not $env:ANDROID_HOME) { $env:ANDROID_HOME = "<ANDROID_SDK>" }
if (-not $env:FLUTTER_ROOT) {
    $env:FLUTTER_ROOT = "D:\Android Studio\Flutter\flutter_windows_3.47.7-stable\flutter"
}
$env:Path = "$env:FLUTTER_ROOT\bin;$env:JAVA_HOME\bin;$env:ANDROID_HOME\platform-tools;$env:ANDROID_HOME\build-tools\36.0.0;$env:Path"

$flutter = Join-Path $env:FLUTTER_ROOT "bin\flutter.bat"
$apksigner = Join-Path $env:ANDROID_HOME "build-tools\36.0.0\apksigner.bat"
$aapt2 = Join-Path $env:ANDROID_HOME "build-tools\36.0.0\aapt2.exe"

function Read-Version {
    $text = [System.IO.File]::ReadAllText($pubspecPath, [System.Text.Encoding]::UTF8)
    $m = [regex]::Match($text, '(?m)^version:\s*([0-9]+)\.([0-9]+)\.([0-9]+)\+([0-9]+)\s*$')
    if (-not $m.Success) {
        throw "pubspec.yaml 里的 version 行格式不对，应形如 1.0.0+1"
    }
    return [pscustomobject]@{
        Major   = [int]$m.Groups[1].Value
        Minor   = [int]$m.Groups[2].Value
        Patch   = [int]$m.Groups[3].Value
        Code    = [int]$m.Groups[4].Value
        Raw     = $m.Value.Trim()
        Line    = $m.Value.Trim()
    }
}

function Write-Version($major, $minor, $patch, $code) {
    $text = [System.IO.File]::ReadAllText($pubspecPath, [System.Text.Encoding]::UTF8)
    $newLine = "version: $major.$minor.$patch+$code"
    $updated = [regex]::Replace(
        $text,
        '(?m)^version:\s*[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+\s*$',
        $newLine
    )
    # 写回时保持无 BOM（pubspec 若有 BOM，YAML 解析会报错）
    [System.IO.File]::WriteAllText(
        $pubspecPath,
        $updated,
        (New-Object System.Text.UTF8Encoding($false))
    )

    # 同步 lib/utils/app_info.dart 的 appVersion（"关于"页显示用）。
    # 不同步的话 test/settings_test.dart 的版本一致性测试会失败——
    # 这正是它存在的意义，所以这里主动保持一致。
    $infoPath = Join-Path $projectRoot "lib\utils\app_info.dart"
    if (Test-Path $infoPath) {
        $info = [System.IO.File]::ReadAllText($infoPath, [System.Text.Encoding]::UTF8)
        $infoUpdated = [regex]::Replace(
            $info,
            "appVersion\s*=\s*'[0-9]+\.[0-9]+\.[0-9]+'",
            "appVersion = '$major.$minor.$patch'"
        )
        [System.IO.File]::WriteAllText(
            $infoPath,
            $infoUpdated,
            (New-Object System.Text.UTF8Encoding($false))
        )
    }
}

# ---- 1. 递增版本号 ----
$before = Read-Version
if (-not $NoBump -and -not $VerifyOnly) {
    $major = $before.Major
    $minor = $before.Minor
    $patch = $before.Patch
    switch ($Bump) {
        "build" { }
        "patch" { $patch += 1 }
        "minor" { $minor += 1; $patch = 0 }
        "major" { $major += 1; $minor = 0; $patch = 0 }
    }
    # versionCode 永远 +1：它是 Android 判断"能不能装"的唯一依据
    Write-Version $major $minor $patch ($before.Code + 1)
}

$current = Read-Version
Write-Host ""
Write-Host "=== 发版 ===" -ForegroundColor Cyan
Write-Host ("  版本号  {0}.{1}.{2}  (versionCode {3})" -f $current.Major, $current.Minor, $current.Patch, $current.Code)
if (-not $NoBump -and -not $VerifyOnly) {
    Write-Host ("  上一版  {0}" -f $before.Raw) -ForegroundColor DarkGray
}

# ---- 2. 检查签名配置 ----
$keyProps = Join-Path $projectRoot "android\key.properties"
$keystore = Join-Path $projectRoot "android\release-keystore.jks"
if (-not (Test-Path $keyProps) -or -not (Test-Path $keystore)) {
    Write-Host ""
    Write-Warning "未找到签名配置（android\key.properties 或 release-keystore.jks）。"
    Write-Warning "构建会回退到 debug 签名，产物**无法覆盖安装**正式包。"
    Write-Warning "如需正式签名，先运行：powershell -File tools\make_keystore.ps1"
}

# ---- 3. 构建 ----
if (-not $VerifyOnly) {
    Write-Host ""
    Write-Host "  构建中…" -ForegroundColor DarkGray
    # 用 cmd 调 flutter.bat 而不是直接 & $flutter：
    # Gradle/Kotlin 会往 stderr 打警告（KGP 弃用提示等），
    # PowerShell 5.1 把原生命令的 stderr 当错误记录，
    # 在 $ErrorActionPreference = "Stop" 下会让脚本"看起来失败"但实际构建成功。
    # 这里把 stderr 合并进 stdout，只在退出码非 0 时判失败。
    $buildLog = & cmd /c "`"$flutter`" build apk --release 2>&1"
    $buildExit = $LASTEXITCODE
    $buildLog | Select-Object -Last 4 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    if ($buildExit -ne 0) {
        $buildLog | Select-Object -Last 40 | ForEach-Object { Write-Host "  $_" }
        throw "flutter build apk --release 失败（退出码 $buildExit）"
    }
}

# Gradle 直接产出在 apk/release/，Flutter 会另存一份到 flutter-apk/
$apk = Join-Path $outputDir "apk\release\app-release.apk"
if (-not (Test-Path $apk)) {
    $apk = Join-Path $outputDir "flutter-apk\app-release.apk"
}
if (-not (Test-Path $apk)) {
    throw "找不到构建产物。已检查 build\app\outputs\apk\release 与 flutter-apk。"
}

# ---- 4. 验签 ----
Write-Host ""
Write-Host "=== 签名校验 ===" -ForegroundColor Cyan
$certOut = & $apksigner verify --print-certs $apk 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    throw "apksigner 校验失败：$certOut"
}
$dn = ([regex]::Match($certOut, 'certificate DN:\s*(.+)')).Groups[1].Value.Trim()
$digest = ([regex]::Match($certOut, 'SHA-256 digest:\s*([0-9a-f]+)')).Groups[1].Value.Trim()
Write-Host "  证书  $dn"
Write-Host "  指纹  $digest"
if ($dn -match 'Android Debug') {
    Write-Host "  ⚠ 这是 debug 签名，不能覆盖安装正式包" -ForegroundColor Yellow
} else {
    Write-Host "  这是发行签名" -ForegroundColor Green
}

# ---- 5. 回读 APK 里的版本号并与 pubspec 对比 ----
Write-Host ""
Write-Host "=== 版本校验 ===" -ForegroundColor Cyan
$badging = & $aapt2 dump badging $apk 2>&1 | Out-String
$vc = ([regex]::Match($badging, "versionCode='(\d+)'")).Groups[1].Value
$vn = ([regex]::Match($badging, "versionName='([^']*)'")).Groups[1].Value
$pkg = ([regex]::Match($badging, "package: name='([^']*)'")).Groups[1].Value

Write-Host "  包名        $pkg"
Write-Host "  versionCode $vc"
Write-Host "  versionName $vn"

$expectedCode = "$($current.Code)"
$expectedName = "$($current.Major).$($current.Minor).$($current.Patch)"
$ok = $true
if ($vc -ne $expectedCode) {
    Write-Host "  ✗ versionCode 与 pubspec 不符（期望 $expectedCode，实际 $vc）" -ForegroundColor Red
    $ok = $false
}
if ($vn -ne $expectedName) {
    Write-Host "  ✗ versionName 与 pubspec 不符（期望 $expectedName，实际 $vn）" -ForegroundColor Red
    $ok = $false
}
if ($ok) { Write-Host "  与 pubspec 一致" -ForegroundColor Green }

# ---- 6. 汇总 ----
$sizeMb = [math]::Round((Get-Item $apk).Length / 1MB, 2)
$hash = (Get-FileHash $apk -Algorithm SHA256).Hash

Write-Host ""
Write-Host "=== 产物 ===" -ForegroundColor Cyan
Write-Host "  路径   $apk"
Write-Host "  大小   $sizeMb MB"
Write-Host "  SHA256 $hash"
Write-Host ""
Write-Host "  覆盖安装：adb install -r `"$apk`"" -ForegroundColor DarkGray
Write-Host "  手机上已装的 versionCode 必须小于 $vc 才能升级成功。" -ForegroundColor DarkGray

if (-not $ok) { exit 1 }
exit 0
