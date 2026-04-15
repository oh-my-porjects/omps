#!/usr/bin/env bash
set -e

# Oh My Projects 平台一键部署脚本
# 用法:
#   ./setup.sh          首次部署（含 SSH 检查 + clone workspace）
#   ./setup.sh update   拉取最新代码并重建
#
# 快速开始（无需提前 clone）:
#   curl -O https://raw.githubusercontent.com/oh-my-porjects/omps-setup/main/setup.sh
#   chmod +x setup.sh && ./setup.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

WORKSPACE_REPO="git@github.com:oh-my-porjects/omps-dev-workspace.git"
WORKSPACE_DIR="omps-platform"

TOTAL_STEPS=10
MODE="install"
if [[ "$1" == "update" ]]; then
  MODE="update"
  TOTAL_STEPS=5
fi

CURRENT_STEP=0
step()  { CURRENT_STEP=$((CURRENT_STEP + 1)); echo -e "\n${BOLD}[$CURRENT_STEP/$TOTAL_STEPS] $1${NC}"; }
info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()  { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

OS="$(uname -s)"
ARCH="$(uname -m)"

# ══════════════════════════════════════
# 更新模式
# ══════════════════════════════════════

if [[ "$MODE" == "update" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

  echo ""
  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}  Oh My Projects 平台更新${NC}"
  echo -e "${BLUE}========================================${NC}"
  echo ""

  step "拉取最新代码"
  cd "$SCRIPT_DIR"

  if [[ -d .git ]]; then
    info "更新主仓库..."
    git fetch --all
    git reset --hard origin/$(git rev-parse --abbrev-ref HEAD)
    ok "主仓库已更新"
  fi

  for dir in admin-server admin-web runtime cli-server project-admin-web project-template module-template; do
    if [[ -d "$dir/.git" ]]; then
      info "更新 $dir/..."
      cd "$SCRIPT_DIR/$dir"
      git fetch --all
      git reset --hard origin/$(git rev-parse --abbrev-ref HEAD)
      cd "$SCRIPT_DIR"
      ok "$dir 已更新"
    fi
  done

  step "重建 Admin Server"
  cd "$SCRIPT_DIR"
  docker compose build --no-cache server
  ok "Admin Server 构建完成"

  step "重启 Admin 平台"
  docker compose up -d --force-recreate
  info "等待 Admin Server 就绪..."
  for i in $(seq 1 30); do
    HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" http://localhost:8181/api/dashboard -H "Authorization: Bearer test" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" == "401" || "$HTTP_CODE" == "200" ]]; then break; fi
    sleep 2
  done
  ok "Admin 平台已重启"

  step "重建 CLI Server"
  if [[ -d "$SCRIPT_DIR/cli-server" ]]; then
    GO_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    GO_ARCH=$( [[ "$ARCH" == "arm64" ]] && echo arm64 || echo amd64 )
    docker run --rm -v "$SCRIPT_DIR/cli-server:/app" -w /app golang:1.26 \
      sh -c "CGO_ENABLED=0 GOOS=$GO_OS GOARCH=$GO_ARCH go build -o cli-server ./cmd/server"
    ok "CLI Server 构建完成"
  else
    warn "cli-server/ 目录不存在，跳过"
  fi

  step "重启 CLI Server"
  if [[ -f "$SCRIPT_DIR/cli-server/cli-server" ]]; then
    pkill -f "cli-server/cli-server" 2>/dev/null || true
    sleep 1
    cd "$SCRIPT_DIR/cli-server"
    nohup ./cli-server > cli-server.log 2>&1 &
    CLI_PID=$!
    cd "$SCRIPT_DIR"
    sleep 2
    if kill -0 $CLI_PID 2>/dev/null; then
      ok "CLI Server 已重启 (PID: $CLI_PID)"
    else
      warn "CLI Server 启动失败，查看日志: cli-server/cli-server.log"
    fi
  else
    warn "CLI Server 二进制不存在，跳过"
  fi

  echo ""
  echo -e "${GREEN}========================================${NC}"
  echo -e "${GREEN}  更新完成${NC}"
  echo -e "${GREEN}========================================${NC}"
  echo ""
  echo "  服务状态:"
  docker ps --filter "label=com.docker.compose.project=omps-platform" --format "    ✓ {{.Names}}  {{.Status}}" 2>/dev/null || true
  echo ""
  exit 0
fi

# ══════════════════════════════════════
# 首次部署模式
# ══════════════════════════════════════

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Oh My Projects 平台部署${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
info "系统: $OS $ARCH"

# ── 1/9 SSH Key ──

step "检查 SSH Key"

SSH_KEY="$HOME/.ssh/id_ed25519"
SSH_PUB="$SSH_KEY.pub"

if [[ -f "$SSH_PUB" ]]; then
  ok "SSH Key 已存在"
else
  info "生成 SSH Key..."
  mkdir -p "$HOME/.ssh"
  ssh-keygen -t ed25519 -C "omps-setup" -f "$SSH_KEY" -N ""
  ok "SSH Key 已生成"
fi

# 检查是否能连接 GitHub
if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
  ok "GitHub SSH 连接正常"
else
  echo ""
  echo -e "${YELLOW}────────────────────────────────────────${NC}"
  echo -e "${YELLOW}  请将以下公钥添加到 GitHub${NC}"
  echo -e "${YELLOW}────────────────────────────────────────${NC}"
  echo ""
  cat "$SSH_PUB"
  echo ""
  echo -e "${YELLOW}────────────────────────────────────────${NC}"
  echo ""
  echo "  步骤:"
  echo "  1. 复制上面的公钥"
  echo "  2. 打开 https://github.com/settings/ssh/new"
  echo "  3. Title 填: omps-$(hostname)"
  echo "  4. Key 粘贴公钥"
  echo "  5. 点击 Add SSH key"
  echo ""

  while true; do
    read -rp "$(echo -e "${BLUE}已添加到 GitHub？按回车验证连接...${NC}")" _
    if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
      ok "GitHub SSH 连接成功"
      break
    else
      warn "连接失败，请确认公钥已添加到 GitHub 后重试"
    fi
  done
fi

# ── 2/9 克隆 Workspace ──

step "克隆 Workspace"

# 判断是否已在 workspace 目录中
if [[ -f "docker-compose.yml" && -d "admin-server" ]]; then
  ok "已在 workspace 目录中，跳过克隆"
  SCRIPT_DIR="$(pwd)"
else
  if [[ -d "$WORKSPACE_DIR" ]]; then
    ok "$WORKSPACE_DIR/ 已存在"
    cd "$WORKSPACE_DIR"
  else
    info "克隆 $WORKSPACE_REPO..."
    git clone --recursive "$WORKSPACE_REPO" "$WORKSPACE_DIR"
    cd "$WORKSPACE_DIR"
    ok "Workspace 克隆完成"
  fi
  SCRIPT_DIR="$(pwd)"
fi

# ── 3/9 Docker ──

step "检查 Docker"

install_docker_mac() {
  if command -v brew &>/dev/null; then
    info "通过 Homebrew 安装 Docker Desktop..."
    brew install --cask docker
    info "请启动 Docker Desktop，等待就绪后重新运行此脚本"
    exit 0
  else
    fail "未安装 Homebrew，请先安装: https://brew.sh"
  fi
}

install_docker_linux() {
  info "通过官方脚本安装 Docker..."
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
  warn "已将当前用户加入 docker 组，请重新登录后再运行此脚本"
  exit 0
}

if command -v docker &>/dev/null; then
  if docker info &>/dev/null; then
    ok "Docker 已就绪"
  else
    warn "Docker 已安装但未运行"
    if [[ "$OS" == "Darwin" ]]; then
      info "正在启动 Docker Desktop..."
      open -a Docker
      info "等待 Docker 引擎启动..."
      for i in $(seq 1 30); do
        docker info &>/dev/null && break
        sleep 2
      done
      docker info &>/dev/null || fail "Docker 启动超时，请手动启动 Docker Desktop"
      ok "Docker 已启动"
    else
      fail "请启动 Docker: sudo systemctl start docker"
    fi
  fi
else
  warn "Docker 未安装"
  case "$OS" in
    Darwin) install_docker_mac ;;
    Linux)  install_docker_linux ;;
    *)      fail "不支持的系统: $OS" ;;
  esac
fi

docker compose version &>/dev/null || fail "Docker Compose 未安装，请升级 Docker"
ok "Docker Compose $(docker compose version --short)"

# ── 4/10 WireGuard ──

step "检查 WireGuard"

if command -v wg &>/dev/null; then
  ok "WireGuard 已安装"
else
  info "安装 WireGuard..."
  case "$OS" in
    Darwin)
      if command -v brew &>/dev/null; then
        brew install wireguard-tools
      else
        warn "请手动安装: brew install wireguard-tools"
      fi
      ;;
    Linux)
      if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y wireguard-tools
      elif command -v yum &>/dev/null; then
        sudo yum install -y wireguard-tools
      else
        warn "请手动安装 wireguard-tools"
      fi
      ;;
  esac
  if command -v wg &>/dev/null; then
    ok "WireGuard 安装完成"
  else
    warn "WireGuard 安装失败，远程部署功能可能不可用"
  fi
fi

# 配置 WireGuard 免密 sudo（cli-server 远程部署时需要）
if command -v wg &>/dev/null; then
  WG_PATH=$(which wg)
  WG_QUICK_PATH=$(which wg-quick)
  SUDOERS_FILE="/etc/sudoers.d/omps-wireguard"
  if [[ ! -f "$SUDOERS_FILE" ]] || ! sudo -n true 2>/dev/null || ! sudo grep -qF "$WG_QUICK_PATH" "$SUDOERS_FILE" 2>/dev/null; then
    info "配置 WireGuard 免密 sudo（需要输入密码）..."
    SUDOERS_LINE="$USER ALL=(ALL) NOPASSWD: $WG_QUICK_PATH, $WG_PATH"
    echo "$SUDOERS_LINE" | sudo tee "$SUDOERS_FILE" > /dev/null && sudo chmod 440 "$SUDOERS_FILE" && ok "WireGuard sudo 已配置" || warn "sudo 配置失败，远程部署时 WireGuard 可能不可用"
  else
    ok "WireGuard sudo 已配置"
  fi
fi

# ── 5/10 Node.js ──

step "检查 Node.js"

install_node_mac() {
  if command -v brew &>/dev/null; then
    info "通过 Homebrew 安装 Node.js..."
    brew install node
  else
    fail "未安装 Homebrew，请先安装: https://brew.sh"
  fi
}

install_node_linux() {
  info "通过 NodeSource 安装 Node.js 22..."
  if command -v apt-get &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
    sudo apt-get install -y nodejs
  elif command -v yum &>/dev/null; then
    curl -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash -
    sudo yum install -y nodejs
  else
    fail "不支持的包管理器，请手动安装 Node.js: https://nodejs.org"
  fi
}

NEED_NODE=false
if command -v node &>/dev/null; then
  NODE_VER=$(node -v | sed 's/v//' | cut -d. -f1)
  if [[ "$NODE_VER" -ge 20 ]]; then
    ok "Node.js $(node -v)"
  else
    warn "Node.js 版本过低 ($(node -v))，需要 20+"
    NEED_NODE=true
  fi
else
  warn "Node.js 未安装"
  NEED_NODE=true
fi

if [[ "$NEED_NODE" == "true" ]]; then
  case "$OS" in
    Darwin) install_node_mac ;;
    Linux)  install_node_linux ;;
  esac
  command -v node &>/dev/null || fail "Node.js 安装失败"
  ok "Node.js $(node -v) 安装完成"
fi

# ── 5/9 Claude CLI ──

step "安装 Claude CLI"

if command -v claude &>/dev/null; then
  ok "Claude CLI 已安装"
else
  info "安装中..."
  npm install -g @anthropic-ai/claude-code
  ok "Claude CLI 安装完成"
fi

# ── 6/9 Codex CLI ──

step "安装 Codex CLI"

if command -v codex &>/dev/null; then
  ok "Codex CLI 已安装"
else
  info "安装中..."
  npm install -g @openai/codex
  ok "Codex CLI 安装完成"
fi

# ── 7/9 Admin 平台 ──

step "部署 Admin 平台"
cd "$SCRIPT_DIR"

docker compose build server
docker compose up -d

info "等待 Admin Server 就绪..."
for i in $(seq 1 30); do
  HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" http://localhost:8181/api/dashboard -H "Authorization: Bearer test" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" == "401" || "$HTTP_CODE" == "200" ]]; then break; fi
  sleep 2
done
ok "Admin 平台已启动"

# ── 8/9 CLI Server 构建 ──

step "构建 CLI Server"
CLI_PID=""

if [[ -d "$SCRIPT_DIR/cli-server" ]]; then
  info "使用 Docker 编译（Go 1.26）..."
  GO_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  GO_ARCH=$( [[ "$ARCH" == "arm64" ]] && echo arm64 || echo amd64 )
  docker run --rm -v "$SCRIPT_DIR/cli-server:/app" -w /app golang:1.26 \
    sh -c "CGO_ENABLED=0 GOOS=$GO_OS GOARCH=$GO_ARCH go build -o cli-server ./cmd/server"
  ok "CLI Server 构建完成"
else
  warn "cli-server/ 目录不存在，跳过"
fi

# ── 9/9 CLI Server 启动 ──

step "启动 CLI Server"

if [[ -f "$SCRIPT_DIR/cli-server/cli-server" ]]; then
  pkill -f "cli-server/cli-server" 2>/dev/null || true
  sleep 1

  cd "$SCRIPT_DIR/cli-server"
  nohup ./cli-server > cli-server.log 2>&1 &
  CLI_PID=$!
  cd "$SCRIPT_DIR"
  sleep 2

  if kill -0 $CLI_PID 2>/dev/null; then
    ok "CLI Server 已启动 (PID: $CLI_PID, 端口 9100)"
  else
    warn "CLI Server 启动失败，查看日志: cli-server/cli-server.log"
  fi
else
  warn "CLI Server 二进制不存在，跳过启动"
fi

# ── 开机自启（Linux）──

if [[ "$OS" == "Linux" ]]; then
  # Docker 开机自启
  if command -v systemctl &>/dev/null; then
    sudo systemctl enable docker 2>/dev/null && info "Docker 已设置开机自启"
  fi

  # CLI Server systemd 服务
  if [[ -f "$SCRIPT_DIR/cli-server/cli-server" ]]; then
    SERVICE_FILE="/etc/systemd/system/omps-cli-server.service"
    if [[ ! -f "$SERVICE_FILE" ]]; then
      info "配置 CLI Server 开机自启..."
      sudo tee "$SERVICE_FILE" > /dev/null <<UNIT
[Unit]
Description=OMPS CLI Server
After=network.target docker.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$SCRIPT_DIR/cli-server
ExecStart=$SCRIPT_DIR/cli-server/cli-server
Restart=on-failure
RestartSec=5
Environment=CLI_SERVER_TOKEN=dev-cli-token-2026
Environment=PORT=9100

[Install]
WantedBy=multi-user.target
UNIT
      sudo systemctl daemon-reload
      sudo systemctl enable omps-cli-server
      # 用 systemd 管理，停掉手动启动的进程
      pkill -f "cli-server/cli-server" 2>/dev/null || true
      sudo systemctl start omps-cli-server
      ok "CLI Server 已配置为 systemd 服务（开机自启）"
    else
      sudo systemctl restart omps-cli-server
      ok "CLI Server systemd 服务已重启"
    fi
  fi
fi

# ── 创建初始账号 ──

TEMP_USER=""
TEMP_PASS=""
ENTRY_PATH=""

# 等待 API 就绪
for i in $(seq 1 15); do
  if curl -sf http://localhost:8181/api/dashboard >/dev/null 2>&1 || curl -sf http://localhost:8181/api/auth/me >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# 创建临时账号（仅首次部署，无账号时）
TEMP_RESULT=$(curl -sf -X POST http://localhost:8181/api/auth/create-temp-account -H "Content-Type: application/json" 2>/dev/null)
if [[ $? -eq 0 && -n "$TEMP_RESULT" ]]; then
  TEMP_USER=$(echo "$TEMP_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('username',''))" 2>/dev/null)
  TEMP_PASS=$(echo "$TEMP_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('password',''))" 2>/dev/null)
  ENTRY_PATH=$(echo "$TEMP_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('entry_path',''))" 2>/dev/null)
fi

# ── 摘要 ──

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  部署完成${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
if [[ -n "$TEMP_USER" && -n "$ENTRY_PATH" ]]; then
  echo -e "  ${YELLOW}╔══════════════════════════════════════╗${NC}"
  echo -e "  ${YELLOW}║  请保存以下信息（仅显示一次）       ║${NC}"
  echo -e "  ${YELLOW}╠══════════════════════════════════════╣${NC}"
  echo -e "  ${YELLOW}║${NC}  入口地址: ${BLUE}http://localhost:3000/${ENTRY_PATH}${NC}"
  echo -e "  ${YELLOW}║${NC}  临时账号: ${BOLD}${TEMP_USER}${NC}"
  echo -e "  ${YELLOW}║${NC}  临时密码: ${BOLD}${TEMP_PASS}${NC}"
  echo -e "  ${YELLOW}╠══════════════════════════════════════╣${NC}"
  echo -e "  ${YELLOW}║  登录后创建正式账号并绑定 OTP       ║${NC}"
  echo -e "  ${YELLOW}║  需安装 Google Authenticator 等应用  ║${NC}"
  echo -e "  ${YELLOW}╚══════════════════════════════════════╝${NC}"
else
  echo -e "  管理后台     ${BLUE}http://localhost:3000${NC}"
fi
echo ""
echo -e "  API          ${BLUE}http://localhost:8181${NC}"
echo -e "  CLI Server   ${BLUE}http://localhost:9100${NC}"
echo ""
echo "  服务状态:"
docker ps --filter "label=com.docker.compose.project=omps-platform" --format "    ✓ {{.Names}}  {{.Status}}" 2>/dev/null || true
if [[ -n "$CLI_PID" ]] && kill -0 "$CLI_PID" 2>/dev/null; then
  echo "    ✓ cli-server  Running (PID: $CLI_PID)"
fi
echo ""
echo "  CLI:"
echo "    claude  $(claude --version 2>/dev/null || echo '未安装')"
echo "    codex   $(codex --version 2>/dev/null || echo '未安装')"
echo ""
