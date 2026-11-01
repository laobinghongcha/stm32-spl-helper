#!/usr/bin/env pwsh
# 生成发布签名密钥库并写好 android/key.properties。
#
# 用法（在项目根目录执行）：
#   pwsh tools/make_keystore.ps1
#
# 为什么用脚本而不是手敲 keytool：参数多、容易写错，
# 而且 key.properties 的字段名必须和 build.gradle.kts 里读的一致，
# 写一次固化下来更稳。
#
# 注意：
#   - 生成后请把密钥库文件与口令**另行备份**。丢了这个文件，
#     就用同一个包名发布不了新版本（Android 要求同包名同签名）。
#   - key.properties 与 *.jks 都在 .gitignore 里，不会进版本库。

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$androidDir = Join-Path $projectRoot "android"
$keystorePath = Join-Path $androidDir "release-keystore.jks"
$propsPath = Join-Path $androidDir "key.properties"

if (Test-Path $keystorePath) {
    Write-Host "密钥库已存在：$keystorePath"
    Write-Host "如需重新生成，请先手动删除该文件（注意：重新生成后旧包无法覆盖安装）。"
    exit 1
}

$keyAlias = "stm32_spl_helper"

# 口令：默认随机生成，也允许用环境变量覆盖（便于固定口令重建）
$storePass = $env:KEYSTORE_PASSWORD
if ([string]::IsNullOrWhiteSpace($storePass)) {
    # 用 RNGCryptoServiceProvider 而不是 RandomNumberGenerator.Fill：
    # 后者是 .NET Core 才有的静态方法，Windows PowerShell 5.1 跑在
    # .NET Framework 上，调用会报 "does not contain a method named 'Fill'"。
    $bytes = New-Object byte[] 24
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    $storePass = [Convert]::ToBase64String($bytes).Replace("/", "A").Replace("+", "B").Substring(0, 24)
}
$keyPass = $storePass

Write-Host "正在生成密钥库（有效期 10000 天 ≈ 27 年）…"
& keytool -genkeypair `
    -v `
    -keystore $keystorePath `
    -alias $keyAlias `
    -keyalg RSA `
    -keysize 2048 `
    -validity 10000 `
    -storepass $storePass `
    -keypass $keyPass `
    -dname "CN=STM32 SPL Helper, OU=Personal, O=Personal, L=, ST=, C=CN"

if ($LASTEXITCODE -ne 0) {
    Write-Error "keytool 执行失败（退出码 $LASTEXITCODE）。请确认 JDK 的 bin 在 PATH 里。"
    exit 1
}

# key.properties 的键名必须与 android/app/build.gradle.kts 里读的一致。
#
# 必须写成**无 BOM** 的 UTF-8：Java 的 Properties.load 会把 BOM 当成
# 第一个键名的一部分，于是读到的是 "\uFEFFstorePassword"，
# 结果 Gradle 报 "SigningConfig release is missing required property
# storePassword"。PowerShell 5.1 的 `Set-Content -Encoding UTF8` 恰好会
# 写 BOM，所以这里用 .NET API 显式指定不带 BOM 的编码。
$propsContent = @"
storePassword=$storePass
keyPassword=$keyPass
keyAlias=$keyAlias
storeFile=release-keystore.jks
"@
[System.IO.File]::WriteAllText(
    $propsPath,
    $propsContent,
    (New-Object System.Text.UTF8Encoding($false))
)

Write-Host ""
Write-Host "已生成："
Write-Host "  密钥库  $keystorePath"
Write-Host "  配置    $propsPath"
Write-Host ""
Write-Host "请立即备份这两个文件与下面的口令："
Write-Host "  storePassword / keyPassword = $storePass"
Write-Host "  keyAlias = $keyAlias"
Write-Host ""
Write-Host "之后执行 flutter build apk --release 就会用这套签名。"
