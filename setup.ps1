# Oh My Projects 平台一键部署脚本
# Windows PowerShell

$ErrorActionPreference = "Stop"

function Info($msg)  { Write-Host "[INFO] $msg" -ForegroundColor Blue }
function OK($msg)    { Write-Host "[ OK ] $msg" -ForegroundColor Green }
function Warn($msg)  { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Fail($msg)  { Write-Host "[FAIL] $msg" -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "========================================" -ForegroundColor Blue
Write-Host "  Oh My Projects 平台部署" -ForegroundColor Blue
Write-Host "========================================" -ForegroundColor Blue
Write-Host ""

# ── 1. Docker ──

$dockerExists = Get-Command docker -ErrorAction SilentlyContinue
if ($dockerExists) {
    $dockerInfo = docker info 2>&1
    if ($LASTEXITCODE -eq 0) {
        OK "Docker 已就绪"
    } else {
        Warn "Docker 已安装但未运行，请启动 Docker Desktop"
        Start-Process "Docker Desktop" -ErrorAction SilentlyContinue
        Info "等待 Docker 启动..."
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Seconds 2
            docker info 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { break }
        }
        docker info 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "Docker 启动超时" }
        OK "Docker 已启动"
    }
} else {
    Warn "Docker 未安装"
    Write-Host ""
    Write-Host "请手动安装 Docker Desktop:" -ForegroundColor Yellow
    Write-Host "  1. 下载: https://www.docker.com/products/docker-desktop" -ForegroundColor Yellow
    Write-Host "  2. 安装后启动 Docker Desktop" -ForegroundColor Yellow
    Write-Host "  3. 确保 WSL2 已启用" -ForegroundColor Yellow
    Write-Host "  4. 安装完成后重新运行此脚本" -ForegroundColor Yellow
    Write-Host ""
    Fail "Docker 未安装"
}

$composeVer = docker compose version 2>&1
if ($LASTEXITCODE -eq 0) {
    OK "Docker Compose 已安装"
} else {
    Fail "Docker Compose 未安装，请升级 Docker Desktop"
}

# ── 2. Node.js ──

$nodeExists = Get-Command node -ErrorAction SilentlyContinue
$needNode = $false

if ($nodeExists) {
    $nodeVer = (node -v) -replace 'v','' -split '\.' | Select-Object -First 1
    if ([int]$nodeVer -ge 20) {
        OK "Node.js $(node -v)"
    } else {
        Warn "Node.js 版本过低 ($(node -v))，需要 20+"
        $needNode = $true
    }
} else {
    Warn "Node.js 未安装"
    $needNode = $true
}

if ($needNode) {
    $wingetExists = Get-Command winget -ErrorAction SilentlyContinue
    if ($wingetExists) {
        Info "通过 winget 安装 Node.js..."
        winget install OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements
        # 刷新 PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    } else {
        Fail "请手动安装 Node.js: https://nodejs.org"
    }
    $nodeCheck = Get-Command node -ErrorAction SilentlyContinue
    if (-not $nodeCheck) { Fail "Node.js 安装失败，请重新打开终端后重试" }
    OK "Node.js $(node -v) 安装完成"
}

# ── 3. CLI 工具 ──

Write-Host ""
Info "检查 CLI 工具..."

$claudeExists = Get-Command claude -ErrorAction SilentlyContinue
if ($claudeExists) {
    OK "Claude CLI 已安装"
} else {
    Info "安装 Claude CLI..."
    npm install -g @anthropic-ai/claude-code
    OK "Claude CLI 安装完成"
}

$codexExists = Get-Command codex -ErrorAction SilentlyContinue
if ($codexExists) {
    OK "Codex CLI 已安装"
} else {
    Info "安装 Codex CLI..."
    npm install -g @openai/codex
    OK "Codex CLI 安装完成"
}

# ── 4. Admin 平台 ──

Write-Host ""
Info "部署 Admin 平台..."
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

docker compose build server
docker compose up -d

Info "等待 Admin Server 就绪..."
for ($i = 0; $i -lt 30; $i++) {
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:8181/api/dashboard" -Headers @{Authorization="Bearer test"} -UseBasicParsing -TimeoutSec 2 -ErrorAction SilentlyContinue
        if ($resp.StatusCode -eq 200 -or $resp.StatusCode -eq 401) { break }
    } catch {
        if ($_.Exception.Response.StatusCode.Value__ -eq 401) { break }
    }
    Start-Sleep -Seconds 2
}
OK "Admin 平台已启动"

# ── 5. CLI Server ──

Write-Host ""
$cliServerDir = Join-Path $scriptDir "cli-server"
if (Test-Path $cliServerDir) {
    Info "构建 CLI Server..."
    docker run --rm -v "${cliServerDir}:/app" -w /app golang:1.26 sh -c "CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -o cli-server.exe ./cmd/server"

    # 停止旧进程
    Get-Process -Name "cli-server" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    Info "启动 CLI Server..."
    $cliExe = Join-Path $cliServerDir "cli-server.exe"
    Start-Process -FilePath $cliExe -WorkingDirectory $cliServerDir -WindowStyle Hidden -RedirectStandardOutput (Join-Path $cliServerDir "cli-server.log") -RedirectStandardError (Join-Path $cliServerDir "cli-server-err.log")
    Start-Sleep -Seconds 2

    $proc = Get-Process -Name "cli-server" -ErrorAction SilentlyContinue
    if ($proc) {
        OK "CLI Server 已启动 (PID: $($proc.Id), 端口 9100)"
    } else {
        Warn "CLI Server 启动失败，查看日志: cli-server\cli-server.log"
    }
} else {
    Warn "cli-server/ 目录不存在，跳过"
}

# ── 摘要 ──

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  部署完成" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "  管理后台     http://localhost:3000"
Write-Host "  API          http://localhost:8181"
Write-Host "  CLI Server   http://localhost:9100"
Write-Host ""
Write-Host "  服务状态:"
docker ps --filter "label=com.docker.compose.project=omps-platform" --format "    √ {{.Names}}  {{.Status}}"
Write-Host ""
Write-Host "  CLI:"
Write-Host "    claude  $(try { claude --version 2>&1 } catch { '未安装' })"
Write-Host "    codex   $(try { codex --version 2>&1 } catch { '未安装' })"
Write-Host ""
