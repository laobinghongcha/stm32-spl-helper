param(
    # 只跑检查，不构建
    [switch]$CheckOnly,

    # 覆盖已有 dist 产物
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# 把已构建的 APK 打包成可上传 GitHub Releases 的一组文件。
#
# 产出（dist/）：
#   stm32-helper-<版本>.apk   签名安装包
#   SHA256SUMS.txt            校验值，用户下载后可自行核对
#   RELEASE_NOTES.md          发布说明正文，可直接粘进 Release 描述
#
# 本脚本**不构建**，只打包与校验。构建请用 tools/release.ps1。
# 这样职责分明：release.ps1 管"版本号 + 构建 + 验签"，
# 本脚本管"整理发布物"，可以反复跑而不触发重新构建。
# ---------------------------------------------------------------------------

$projectRoot = Split-Path -Parent $PSScriptRoot
$pubspecPath = Join-Path $projectRoot "pubspec.yaml"
$distDir = Join-Path $projectRoot "dist"

# 从统一的 env 脚本取构建环境（存在则用，不存在则用系统 PATH）
$envScript = "D:\dsh_work\_sdk\env.ps1"
if (Test-Path $envScript) { . $envScript }

function Get-Version {
    $text = [System.IO.File]::ReadAllText($pubspecPath, [System.Text.Encoding]::UTF8)
    $m = [regex]::Match($text, '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$')
    if (-not $m.Success) { throw "pubspec.yaml 的 version 行格式不对" }
    [pscustomobject]@{
        Name = $m.Groups[1].Value
        Code = [int]$m.Groups[2].Value
        Raw  = $m.Value.Trim()
    }
}

$ver = Get-Version
Write-Host ""
Write-Host "=== 打包发布物 ===" -ForegroundColor Cyan
Write-Host ("  版本    {0}  (versionCode {1})" -f $ver.Name, $ver.Code)

# ---- 1. 定位 APK ----
$apkCandidates = @(
    (Join-Path $projectRoot "build\app\outputs\flutter-apk\app-release.apk"),
    (Join-Path $projectRoot "build\app\outputs\apk\release\app-release.apk")
)
$apk = $apkCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $apk) {
    throw "找不到已构建的 APK。先跑：powershell -File tools\release.ps1 -NoBump"
}
Write-Host "  APK     $apk"

# ---- 2. 校验签名与版本（不信任文件名，直接读 APK）----
$buildTools = $null
foreach ($v in @("36.0.0", "35.0.0", "34.0.0")) {
    $p = Join-Path $env:ANDROID_HOME "build-tools\$v\apksigner.bat"
    if (Test-Path $p) { $buildTools = Split-Path $p -Parent; break }
}
if (-not $buildTools) { throw "找不到 build-tools（apksigner）" }

$apksigner = Join-Path $buildTools "apksigner.bat"
$aapt2 = Join-Path $buildTools "aapt2.exe"

Write-Host ""
Write-Host "=== 校验 ===" -ForegroundColor Cyan

$badging = & $aapt2 dump badging $apk 2>&1 | Out-String
$pkg = ([regex]::Match($badging, "package: name='([^']*)'")).Groups[1].Value
$vc = ([regex]::Match($badging, "versionCode='(\d+)'")).Groups[1].Value
$vn = ([regex]::Match($badging, "versionName='([^']*)'")).Groups[1].Value
Write-Host "  包名        $pkg"
Write-Host "  versionCode $vc"
Write-Host "  versionName $vn"

$fail = @()
if ($vc -ne "$($ver.Code)") { $fail += "versionCode 不符（APK=$vc, pubspec=$($ver.Code)）" }
if ($vn -ne $ver.Name) { $fail += "versionName 不符（APK=$vn, pubspec=$($ver.Name)）" }

$certOut = & $apksigner verify --print-certs $apk 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { $fail += "apksigner 验签失败：$certOut" }
$dn = ([regex]::Match($certOut, 'certificate DN:\s*(.+)')).Groups[1].Value.Trim()
$digest = ([regex]::Match($certOut, 'SHA-256 digest:\s*([0-9a-f]+)')).Groups[1].Value.Trim()
Write-Host "  证书        $dn"
Write-Host "  指纹        $digest"

if ($dn -match 'Android Debug') {
    $fail += "这是 debug 签名，不能对外发布（先跑 tools\make_keystore.ps1）"
}

# 资源完整性：v2.0.0 的"HAL 全 0"事故就是这里没做检查
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $apk))
try {
    foreach ($lib in @("hal", "ll", "reg")) {
        $n = ($zip.Entries | Where-Object { $_.FullName -like "*assets/data/functions/$lib/*" }).Count
        Write-Host ("  资源 {0,-4}   {1} 个文件" -f $lib, $n)
        if ($n -eq 0) { $fail += "APK 里没有 functions/$lib/ 的数据（会显示成 0 个函数）" }
    }
}
finally { $zip.Dispose() }

if ($fail.Count -gt 0) {
    Write-Host ""
    Write-Host "校验未通过：" -ForegroundColor Red
    $fail | ForEach-Object { Write-Host "  ✗ $_" -ForegroundColor Red }
    exit 1
}
Write-Host "  全部通过" -ForegroundColor Green

if ($CheckOnly) { exit 0 }

# ---- 3. 产出 dist ----
if ((Test-Path $distDir) -and -not $Force) {
    $existing = Get-ChildItem $distDir -File
    if ($existing) {
        Write-Host ""
        Write-Warning "dist/ 下已有文件：$($existing.Name -join ', ')"
        Write-Warning "加 -Force 覆盖，或先手动清理。"
        exit 1
    }
}
New-Item -ItemType Directory -Force -Path $distDir | Out-Null

$apkName = "stm32-helper-$($ver.Name).apk"
$apkOut = Join-Path $distDir $apkName
Copy-Item $apk $apkOut -Force

$hash = (Get-FileHash $apkOut -Algorithm SHA256).Hash.ToLower()
$sizeMb = [math]::Round((Get-Item $apkOut).Length / 1MB, 2)

# SHA256SUMS：`<hash>  <文件名>` 双空格，与 sha256sum 输出格式一致
$sums = "$hash  $apkName"
[System.IO.File]::WriteAllText(
    (Join-Path $distDir "SHA256SUMS.txt"),
    "$sums`n",
    (New-Object System.Text.UTF8Encoding($false))
)

# ---- 4. 发布说明 ----
$notesPath = Join-Path $distDir "RELEASE_NOTES.md"
if (-not (Test-Path $notesPath)) {
    $template = Join-Path $projectRoot "docs\release_notes_template.md"
    if (Test-Path $template) {
        Copy-Item $template $notesPath -Force
    } else {
        [System.IO.File]::WriteAllText($notesPath, "# v$($ver.Name)`n`n", (New-Object System.Text.UTF8Encoding($false)))
    }
}

Write-Host ""
Write-Host "=== 产物 ===" -ForegroundColor Cyan
Write-Host ("  {0}" -f $apkOut)
Write-Host ("  大小   {0} MB" -f $sizeMb)
Write-Host ("  SHA256 {0}" -f $hash)
Write-Host ("  校验值 {0}" -f (Join-Path $distDir "SHA256SUMS.txt"))
Write-Host ("  说明   {0}" -f $notesPath)
Write-Host ""
Write-Host "下一步：把 dist/ 下的 .apk 与 SHA256SUMS.txt 上传到 GitHub Releases。" -ForegroundColor DarkGray
Write-Host "详见 docs/RELEASING.md" -ForegroundColor DarkGray

exit 0
