param(
    # 跳过 APK 打包后的体积统计（CI 上无所谓，本地想看时加这个）
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# 发布前的统一自检。任何一个环节失败就退出码非 0。
#
# 目的：把"发版前必须做的事"从记忆变成可执行步骤。
# v2.0.0 那次 HAL 全 0 的事故，是因为**测试覆盖不到资源打包**——
# 现在 asset_bundle_test / bundle_load_test / e2e_regression_test 专门堵这个洞，
# 本脚本只是把该跑的都串起来。
# ---------------------------------------------------------------------------

$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot

$envScript = "D:\dsh_work\_sdk\env.ps1"
if (Test-Path $envScript) { . $envScript }

$failures = @()

# 运行一个检查步骤。
#
# 注意：这里**不用** $LASTEXITCODE 做判定。原因是在 PowerShell 里，
# $LASTEXITCODE 反映的是**最后一次**原生命令的退出码，而 Step 内部还会
# 调 Write-Host / Select-Object 等 cmdlet，很容易读到与预期无关的值
# （最初就因此把「测试全过」误判成失败）。改为让每个检查自己得出结论，
# 失败就 throw，Step 只负责捕获。
function Step($name, [scriptblock]$action) {
    Write-Host ""
    Write-Host "=== $name ===" -ForegroundColor Cyan
    try {
        & $action
        Write-Host "  OK" -ForegroundColor Green
    }
    catch {
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        $script:failures += $name
    }
}

try {
    Step "flutter analyze" {
        # 用 cmd 调 .bat：PowerShell 5.1 会把原生命令的 stderr 当错误记录，
        # 在 $ErrorActionPreference=Stop 下会让脚本"看起来失败"但实际成功。
        $out = & cmd /c "flutter analyze 2>&1"
        $code = $LASTEXITCODE
        $out | Select-Object -Last 3 | ForEach-Object { Write-Host "  $_" }
        if ($code -ne 0) { throw "analyzer 退出码 $code（存在 error/warning）" }
    }

    Step "flutter test" {
        $out = & cmd /c "flutter test 2>&1"
        $code = $LASTEXITCODE
        ($out | Select-String -Pattern "All tests passed|Some tests failed" |
            Select-Object -Last 1) | ForEach-Object { Write-Host "  $_" }
        if ($code -ne 0) { throw "测试未全部通过（退出码 $code）" }
    }

    Step "数据一致性 (validate_data.py)" {
        # 这段绕了三个坑，都是 PowerShell 5.1 + 中文 Python 脚本的经典组合：
        #
        #   1. **不能用文本匹配判定**：脚本输出中文，在 GBK 控制台下经管道会
        #      变乱码，正则永远匹配不上 → 改用退出码（validate_data.py 约定
        #      有 error 就 exit 1）。
        #   2. **不能写 `2>&1`**：5.1 会把 stderr 封装成 RemoteException 对象
        #      混进管道。
        #   3. **`$ErrorActionPreference='Stop'` 遇到任何 stderr 输出都会抛
        #      异常**，消息还是空的，表现为"FAILED 但看不出原因"。所以要在这
        #      一个步骤内临时放宽 EAP，跑完再恢复。
        #
        # 输出重定向到临时文件，同时避开管道编码问题。
        $tmp = [System.IO.Path]::GetTempFileName()
        $saved = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & python tools\validate_data.py --data assets\data *> $tmp
            $code = $LASTEXITCODE
            $ErrorActionPreference = $saved
            Get-Content $tmp -Encoding UTF8 | Select-Object -Last 3 |
                ForEach-Object { Write-Host "  $_" }
            if ($code -ne 0) { throw "数据校验未通过（退出码 $code）" }
        }
        finally {
            $ErrorActionPreference = $saved
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    Step "中文覆盖率 (check_zh_coverage.py)" {
        $out = & python tools\check_zh_coverage.py 2>&1
        $out | Select-String -Pattern "HAL  |LL  |结果" | Select-Object -First 4 | ForEach-Object { Write-Host "  $_" }
        if ((-not ($out -match "全部检查通过"))) { throw "中文覆盖率未达标" }
    }

    Step "密钥未入库" {
        $tracked = & git ls-files 2>$null
        $leak = $tracked | Select-String "key\.properties|\.jks$|\.keystore$"
        if ($leak) { throw "以下敏感文件被 git 跟踪：$($leak -join ', ')" }
        Write-Host "  key.properties / *.jks 均未被跟踪"
    }

    Step "资源已打包（APK 内容）" {
        $apk = Join-Path $projectRoot "build\app\outputs\flutter-apk\app-release.apk"
        if (-not (Test-Path $apk)) {
            Write-Host "  未构建 APK，跳过（发版前请先 flutter build apk --release）"
            return
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $apk))
        try {
            foreach ($lib in @("hal", "ll", "reg")) {
                $n = ($zip.Entries | Where-Object { $_.FullName -like "*assets/data/functions/$lib/*" }).Count
                Write-Host ("  functions/{0}: {1} 个文件" -f $lib, $n)
                if ($n -eq 0) { throw "APK 里缺 functions/$lib/ 数据" }
            }
        }
        finally { $zip.Dispose() }
    }

    # ---- 汇总 ----
    Write-Host ""
    if ($failures.Count -eq 0) {
        Write-Host "=== 全部通过 ===" -ForegroundColor Green
        exit 0
    }
    Write-Host "=== 失败项 ===" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  ✗ $_" -ForegroundColor Red }
    exit 1
}
finally {
    Pop-Location
}
