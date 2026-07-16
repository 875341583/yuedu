# 阅界 一键构建脚本
# 用法: powershell -ExecutionPolicy Bypass -File build.ps1 [web|windows|apk]

param([string]$target = "windows")

$projectRoot = "D:\projects\yuedu"
$engineDir = "$projectRoot\engine"
$dllPath = "$engineDir\target\release\typeset_engine.dll"
$cargo = "D:\rust\cargo\bin\cargo.exe"
$flutter = "D:\flutter\bin\flutter.bat"

Write-Host "=== 阅界构建 === 目标: $target" -ForegroundColor Cyan

# Step 1: Rust
Write-Host "[1/3] Rust编译..." -ForegroundColor Yellow
Set-Location $engineDir
& $cargo build --release 2>$null
if (-not (Test-Path $dllPath)) { Write-Host "Rust编译失败!" -ForegroundColor Red; exit 1 }
Write-Host "  OK: $([System.IO.FileInfo]::new($dllPath).Length) bytes" -ForegroundColor Green

# Step 2: DLL
Write-Host "[2/3] 复制DLL..." -ForegroundColor Yellow
Copy-Item $dllPath "$projectRoot\windows\typeset_engine.dll" -Force
Write-Host "  OK" -ForegroundColor Green

# Step 3: Flutter
Write-Host "[3/3] Flutter构建..." -ForegroundColor Yellow
Set-Location $projectRoot
switch ($target) {
    "web"     { & $flutter build web --release 2>$null }
    "windows" { & $flutter build windows --debug 2>$null }
    "apk"     { & $flutter build apk --debug 2>$null }
    default   { Write-Host "未知目标: $target" -ForegroundColor Red; exit 1 }
}
Write-Host "  OK" -ForegroundColor Green
Write-Host "=== 构建完成 ===" -ForegroundColor Cyan
