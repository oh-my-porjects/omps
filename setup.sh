#!/usr/bin/env bash
set -e

SCRIPT_VERSION="2026.04.17.1"

# Oh My Projects 平台一键部署脚本
# 用法:
#   ./setup.sh          首次部署（含 SSH 检查 + clone workspace）
#   ./setup.sh update   拉取最新代码并重建
#
# 快速开始（无需提前 clone）:
#   curl -O https://raw.githubusercontent.com/oh-my-porjects/omps/main/setup.sh
#   chmod +x setup.sh && sudo ./setup.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

WORKSPACE_REPO="git@github.com:oh-my-porjects/omps-dev-workspace.git"
WORKSPACE_DIR="omps-platform"

TOTAL_STEPS=13
MODE="install"
if [[ "$1" == "update" ]]; then
  MODE="update"
  TOTAL_STEPS=5
fi

CURRENT_STEP=0
LOG_FILE=$(mktemp /tmp/omps-setup-XXXXXX.log)

STEP_START=0
step() {
  # 上一步耗时
  if [[ $STEP_START -gt 0 ]]; then
    local elapsed=$(( $(date +%s) - STEP_START ))
    echo -e "   ${DIM}耗时 ${elapsed}s${NC}"
  fi
  CURRENT_STEP=$((CURRENT_STEP + 1))
  STEP_START=$(date +%s)
  echo ""
  echo -e "${BOLD}── [$CURRENT_STEP/$TOTAL_STEPS] $1 ──────────────────────────${NC}"
}
# 最后一步结束时调用
step_done() {
  if [[ $STEP_START -gt 0 ]]; then
    local elapsed=$(( $(date +%s) - STEP_START ))
    echo -e "   ${DIM}耗时 ${elapsed}s${NC}"
    STEP_START=0
  fi
}
info()  { echo -e "   ${BLUE}▸${NC} $1"; }
ok()    { echo -e "   ${GREEN}✓${NC} $1"; }

# 方向键选择函数
# 用法: select_option "提示" "选项1" "选项2"
# 结果存在 SELECTED（0=第一项）
select_option() {
  local prompt="$1"; shift
  local options=("$@")
  local count=${#options[@]}
  local current=0
  tput civis 2>/dev/null
  draw_menu() {
    for i in "${!options[@]}"; do
      tput el 2>/dev/null
      if [[ $i -eq $current ]]; then
        echo -e "     ${BLUE}>${NC} ${BOLD}${options[$i]}${NC}"
      else
        echo -e "       ${DIM}${options[$i]}${NC}"
      fi
    done
  }
  echo -e "$prompt"
  draw_menu
  while true; do
    IFS= read -rsn1 key
    case "$key" in
      $'\x1b')
        read -rsn2 rest
        case "$rest" in
          '[A') [[ $current -gt 0 ]] && current=$((current - 1)) || true ;;
          '[B') [[ $current -lt $((count - 1)) ]] && current=$((current + 1)) || true ;;
        esac
        ;;
      '') break ;;
    esac
    for ((i = 0; i < count; i++)); do tput cuu1 2>/dev/null; done
    draw_menu
  done
  tput cnorm 2>/dev/null
  SELECTED=$current
}
warn()  { echo -e "   ${YELLOW}!${NC} $1"; }
fail()  { echo -e "   ${RED}✗${NC} $1"; echo -e "   ${DIM}日志: $LOG_FILE${NC}"; exit 1; }

# 静默执行命令，失败时显示日志尾部
run_quiet() {
  local desc="$1"; shift
  > "$LOG_FILE"
  local code=0
  "$@" >>"$LOG_FILE" 2>&1 </dev/null || code=$?
  if [[ $code -ne 0 ]]; then
    echo -e "   ${RED}✗${NC} $desc"
    echo -e "   ${DIM}─── 错误日志（最后 30 行）───${NC}"
    tail -30 "$LOG_FILE" | sed 's/^/   /'
    echo -e "   ${DIM}────────────────────────────${NC}"
    return $code
  fi
  return 0
}

# 后台运行 + spinner
run_spin() {
  local desc="$1"; shift
  > "$LOG_FILE"
  "$@" >>"$LOG_FILE" 2>&1 </dev/null &
  local pid=$!
  local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r   ${BLUE}%s${NC} %s" "${chars:i%${#chars}:1}" "$desc"
    i=$((i + 1))
    sleep 0.1
  done
  local code=0
  wait "$pid" || code=$?
  printf "\r\033[K"
  if [[ $code -ne 0 ]]; then
    echo -e "   ${RED}✗${NC} $desc"
    echo -e "   ${DIM}─── 错误日志（最后 30 行）───${NC}"
    tail -30 "$LOG_FILE" | sed 's/^/   /'
    echo -e "   ${DIM}────────────────────────────${NC}"
    return $code
  fi
  return 0
}

OS="$(uname -s)"
ARCH="$(uname -m)"

# ══════════════════════════════════════
# 更新模式
# ══════════════════════════════════════

if [[ "$MODE" == "update" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

  echo ""
  echo -e "${BLUE}  ┌──────────────────────────────────┐${NC}"
  echo -e "${BLUE}  │   Oh My Projects 平台更新  ${DIM}$SCRIPT_VERSION${NC}${BLUE}  │${NC}"
  echo -e "${BLUE}  └──────────────────────────────────┘${NC}"

  step "拉取最新代码"
  cd "$SCRIPT_DIR"

  if [[ -d .git ]]; then
    run_quiet "更新主仓库" git fetch --all
    run_quiet "重置主仓库" git reset --hard origin/$(git rev-parse --abbrev-ref HEAD)
    ok "主仓库已更新"
  fi

  for dir in admin-server admin-web runtime cli-server omps-mcp project-admin-web project-template module-template; do
    if [[ -d "$dir/.git" ]]; then
      cd "$SCRIPT_DIR/$dir"
      run_quiet "拉取 $dir" git fetch --all
      run_quiet "重置 $dir" git reset --hard origin/$(git rev-parse --abbrev-ref HEAD)
      cd "$SCRIPT_DIR"
      ok "$dir 已更新"
    fi
  done

  step "重建 Admin Server"
  cd "$SCRIPT_DIR"
  SERVER_HASH=$(git -C admin-server rev-parse --short HEAD 2>/dev/null || echo "unknown")
  BUILD_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  export BUILD_COMMIT="$SERVER_HASH" BUILD_TIME CACHE_BUST="$SERVER_HASH"
  run_spin "构建镜像 ($SERVER_HASH)..." docker compose build --no-cache server
  # 验证镜像内 VERSION 与源码 HEAD 一致（防御 Docker cache 异常）
  if [[ "$SERVER_HASH" != "unknown" ]]; then
    IMAGE_VERSION=$(docker run --rm omps-platform-server cat /app/VERSION 2>/dev/null | tr -d '\r\n')
    if [[ "$IMAGE_VERSION" != "$SERVER_HASH" ]]; then
      fail "镜像版本校验失败（预期 $SERVER_HASH，实际 '$IMAGE_VERSION'），可能命中旧 cache"
    fi
  fi
  ok "Admin Server 构建完成"

  step "重启 Admin 平台"
  run_quiet "重启容器" docker compose up -d --force-recreate
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
    run_spin "编译 Go 二进制..." docker run --rm -v "$SCRIPT_DIR/cli-server:/app" -w /app golang:1.26 \
      sh -c "CGO_ENABLED=0 GOOS=$GO_OS GOARCH=$GO_ARCH go build -o cli-server ./cmd/server"
    ok "CLI Server 构建完成"
  else
    warn "cli-server/ 目录不存在，跳过"
  fi

  step "重建 omps-mcp"
  if [[ -d "$SCRIPT_DIR/omps-mcp" ]]; then
    GO_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    GO_ARCH=$( [[ "$ARCH" == "arm64" ]] && echo arm64 || echo amd64 )
    run_spin "编译 omps-mcp 二进制..." docker run --rm -v "$SCRIPT_DIR/omps-mcp:/app" -w /app golang:1.26 \
      sh -c "CGO_ENABLED=0 GOOS=$GO_OS GOARCH=$GO_ARCH go build -o omps-mcp ./cmd/omps-mcp"
    ok "omps-mcp 构建完成（stdio 工具，由 Claude CLI 按需 spawn）"
  else
    warn "omps-mcp/ 目录不存在，跳过"
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
  echo -e "${GREEN}  ┌──────────────────────────────────┐${NC}"
  echo -e "${GREEN}  │   更新完成                       │${NC}"
  echo -e "${GREEN}  └──────────────────────────────────┘${NC}"
  echo ""
  echo "   服务状态:"
  docker ps --filter "label=com.docker.compose.project=omps-platform" --format "   ✓ {{.Names}}  {{.Status}}" 2>/dev/null || true
  echo ""
  exit 0
fi

# ══════════════════════════════════════
# 首次部署模式
# ══════════════════════════════════════

echo ""
echo -e "${BLUE}  ┌──────────────────────────────────┐${NC}"
echo -e "${BLUE}  │   Oh My Projects 平台部署  ${DIM}$SCRIPT_VERSION${NC}${BLUE}  │${NC}"
echo -e "${BLUE}  └──────────────────────────────────┘${NC}"
echo ""
echo -e "   系统: ${BOLD}$OS $ARCH${NC}"

# ── 1. SSH 端口（仅 Linux）──

if [[ "$OS" == "Linux" ]]; then
  step "检查 SSH 端口"

  SSHD_CONFIG="/etc/ssh/sshd_config"
  CURRENT_PORT=$(grep -E "^Port " "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}')
  # 如果没有显式配置 Port，默认是 22
  [[ -z "$CURRENT_PORT" ]] && CURRENT_PORT=22

  if [[ "$CURRENT_PORT" == "22" ]]; then
    warn "当前 SSH 端口为 22，建议修改以提高安全性"
    read -rep "$(echo -e "   ${BLUE}▸${NC} 输入新端口（默认 19822）: ")" NEW_PORT
    NEW_PORT="${NEW_PORT:-19822}"

    # 校验端口号
    if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [[ "$NEW_PORT" -lt 1024 || "$NEW_PORT" -gt 65535 ]]; then
      fail "端口号无效（需要 1024-65535）"
    fi

    # 提示云服务商安全组
    echo ""
    echo -e "   ${YELLOW}┌──────────────────────────────────────────────────┐${NC}"
    echo -e "   ${YELLOW}│  ⚠ 云服务商安全组也要放行（否则会失联）          │${NC}"
    echo -e "   ${YELLOW}└──────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "   阿里云 / 腾讯云 / AWS / 华为云等都有独立的「安全组」"
    echo -e "   （云端防火墙），与服务器本地 ufw 是两层，必须都放行。"
    echo ""
    echo -e "   请登录云控制台 → 实例 → ${BOLD}安全组${NC} → 入方向，放行 TCP："
    echo -e "     ${BOLD}${NEW_PORT}${NC}   SSH 新端口（改完后 22 端口即失效）"
    echo -e "     ${BOLD}80${NC}     Nginx Gateway（前端回源用，未放行会报 522）"
    echo ""
    echo -e "   ${DIM}未放行会导致 sshd 重启后直接失联，只能走控制台 VNC 救援。${NC}"
    echo ""
    read -rp "$(echo -e "   ${BLUE}▸${NC} 已在云安全组放行 ${BOLD}${NEW_PORT}${NC} 和 ${BOLD}80${NC}？按回车继续（Ctrl+C 取消）")" _

    # 修改 sshd 配置
    if grep -qE "^Port " "$SSHD_CONFIG"; then
      sudo sed -i "s/^Port .*/Port $NEW_PORT/" "$SSHD_CONFIG"
    elif grep -qE "^#Port " "$SSHD_CONFIG"; then
      sudo sed -i "s/^#Port .*/Port $NEW_PORT/" "$SSHD_CONFIG"
    else
      echo "Port $NEW_PORT" | sudo tee -a "$SSHD_CONFIG" > /dev/null
    fi

    # 重启 sshd
    if sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh 2>/dev/null; then
      ok "SSH 端口已修改为 $NEW_PORT"
      echo ""
      echo -e "   ${YELLOW}┌──────────────────────────────────────┐${NC}"
      echo -e "   ${YELLOW}│  重要：请记住新的 SSH 端口           │${NC}"
      echo -e "   ${YELLOW}│${NC}  ssh -p ${BOLD}$NEW_PORT${NC} root@<IP>"
      echo -e "   ${YELLOW}│${NC}  不要关闭当前终端，先用新端口测试  "
      echo -e "   ${YELLOW}└──────────────────────────────────────┘${NC}"
      echo ""
    else
      fail "sshd 重启失败，请手动检查配置"
    fi
  else
    ok "SSH 端口: $CURRENT_PORT"
  fi
else
  # macOS 跳过，不计入步骤
  CURRENT_STEP=$((CURRENT_STEP + 1))
fi

# ── 2. 防火墙（仅 Linux）──

if [[ "$OS" == "Linux" ]]; then
  step "配置防火墙"

  # 确定当前 SSH 端口
  SSH_PORT="${NEW_PORT:-$CURRENT_PORT}"
  SSH_PORT="${SSH_PORT:-22}"

  if ! command -v ufw &>/dev/null; then
    info "安装 ufw..."
    run_quiet "安装 ufw" apt-get update -qq
    run_quiet "安装 ufw" apt-get install -y ufw
  fi

  add_firewall_rules() {
    ufw allow "$SSH_PORT/tcp" comment 'SSH' >/dev/null 2>&1
    ufw allow "80/tcp" comment 'Nginx Gateway' >/dev/null 2>&1
    ufw allow from 172.16.0.0/12 to any port 9100 proto tcp comment 'CLI Server (Docker internal)' >/dev/null 2>&1
    # 确保 8181 不对外开放
    ufw delete allow 8181/tcp >/dev/null 2>&1
    info "放行 $SSH_PORT/tcp (SSH)"
    info "放行 80/tcp (Nginx Gateway)"
    info "放行 9100/tcp (CLI Server，仅 Docker 内部)"
  }

  if ufw status 2>/dev/null | grep -q "Status: active"; then
    add_firewall_rules
    ok "防火墙已启用，规则已更新"
  else
    info "启用防火墙..."
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    add_firewall_rules
    yes | ufw enable >/dev/null 2>&1
    ok "防火墙已启用"
  fi
else
  CURRENT_STEP=$((CURRENT_STEP + 1))
fi

# ── 3. SSH Key ──

step "检查 SSH Key"

SSH_KEY="$HOME/.ssh/id_ed25519"
SSH_PUB="$SSH_KEY.pub"

if [[ -f "$SSH_PUB" ]]; then
  ok "SSH Key 已存在"
else
  info "生成 SSH Key..."
  mkdir -p "$HOME/.ssh"
  ssh-keygen -t ed25519 -C "omps-setup" -f "$SSH_KEY" -N "" >/dev/null 2>&1
  ok "SSH Key 已生成"
fi

# 检查是否能连接 GitHub
if ssh -T git@github.com </dev/null 2>&1 | grep -q "successfully authenticated"; then
  ok "GitHub SSH 连接正常"
else
  echo ""
  echo -e "   ${YELLOW}┌────────────────────────────────────────┐${NC}"
  echo -e "   ${YELLOW}│  请将以下公钥添加到 GitHub             │${NC}"
  echo -e "   ${YELLOW}└────────────────────────────────────────┘${NC}"
  echo ""
  echo -e "   ${DIM}$(cat "$SSH_PUB")${NC}"
  echo ""
  echo -e "   步骤:"
  echo -e "   1. 复制上面的公钥"
  echo -e "   2. 打开 ${BLUE}https://github.com/settings/ssh/new${NC}"
  echo -e "   3. Title 填: ${BOLD}omps-$(hostname)${NC}"
  echo -e "   4. Key 粘贴公钥，点击 Add SSH key"
  echo ""

  while true; do
    read -rp "$(echo -e "   ${BLUE}▸${NC} 已添加？按回车验证...")" _
    if ssh -T git@github.com </dev/null 2>&1 | grep -q "successfully authenticated"; then
      ok "GitHub SSH 连接成功"
      break
    else
      warn "连接失败，请确认公钥已添加后重试"
    fi
  done
fi

# ── 3. Docker ──

step "检查 Docker"

install_docker_mac() {
  if command -v brew &>/dev/null; then
    run_spin "安装 Docker Desktop..." brew install --cask docker
    info "请启动 Docker Desktop，等待就绪后重新运行此脚本"
    exit 0
  else
    fail "未安装 Homebrew，请先安装: https://brew.sh"
  fi
}

install_docker_linux() {
  info "通过官方脚本安装 Docker..."
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  run_spin "安装 Docker..." sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
  if ! command -v docker &>/dev/null; then
    fail "Docker 安装失败"
  fi
  # root 用户不需要加 docker 组
  if [[ "$EUID" -ne 0 ]]; then
    sudo usermod -aG docker "$USER"
    warn "已将当前用户加入 docker 组，如遇权限问题请重新登录"
  fi
  ok "Docker 安装完成"
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

docker compose version </dev/null &>/dev/null || fail "Docker Compose 未安装，请升级 Docker"
ok "Docker Compose $(docker compose version --short </dev/null)"

# ── 4. 克隆 Workspace ──

step "克隆 Workspace"

# 判断是否已在 workspace 目录中
if [[ -f "docker-compose.yml" && -d "admin-server" ]]; then
  ok "已在 workspace 目录中，跳过克隆"
  SCRIPT_DIR="$(pwd)"
else
  if [[ -d "$WORKSPACE_DIR" ]]; then
    cd "$WORKSPACE_DIR"
    run_quiet "更新 workspace" git pull --ff-only
    ok "$WORKSPACE_DIR/ 已更新"
  else
    run_spin "克隆仓库..." git clone --recursive "$WORKSPACE_REPO" "$WORKSPACE_DIR"
    cd "$WORKSPACE_DIR"
    ok "Workspace 克隆完成"
  fi
  SCRIPT_DIR="$(pwd)"
fi

# 拉取子仓库
cd "$SCRIPT_DIR"
if [[ -f "pull.sh" ]]; then
  info "拉取子仓库..."
  bash pull.sh
  ok "子仓库就绪"
fi

# ── 4. WireGuard ──

step "检查 WireGuard"

if command -v wg &>/dev/null; then
  ok "WireGuard 已安装"
else
  info "安装 WireGuard..."
  case "$OS" in
    Darwin)
      if command -v brew &>/dev/null; then
        run_quiet "安装 wireguard-tools" brew install wireguard-tools
      else
        warn "请手动安装: brew install wireguard-tools"
      fi
      ;;
    Linux)
      if command -v apt-get &>/dev/null; then
        run_quiet "更新包索引" sudo apt-get update -qq
        run_quiet "安装 wireguard-tools" sudo apt-get install -y wireguard-tools
      elif command -v yum &>/dev/null; then
        run_quiet "安装 wireguard-tools" sudo yum install -y wireguard-tools
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

# 配置 WireGuard 免密 sudo
if command -v wg &>/dev/null; then
  WG_PATH=$(which wg)
  WG_QUICK_PATH=$(which wg-quick)
  SUDOERS_FILE="/etc/sudoers.d/omps-wireguard"
  if [[ ! -f "$SUDOERS_FILE" ]] || ! sudo -n true 2>/dev/null || ! sudo grep -qF "$WG_QUICK_PATH" "$SUDOERS_FILE" 2>/dev/null; then
    info "配置 WireGuard 免密 sudo..."
    SUDOERS_LINE="$USER ALL=(ALL) NOPASSWD: $WG_QUICK_PATH, $WG_PATH"
    echo "$SUDOERS_LINE" | sudo tee "$SUDOERS_FILE" > /dev/null && sudo chmod 440 "$SUDOERS_FILE" && ok "WireGuard sudo 已配置" || warn "sudo 配置失败"
  else
    ok "WireGuard sudo 已配置"
  fi
fi

# ── 5. Node.js ──

step "检查 Node.js"

install_node_mac() {
  if command -v brew &>/dev/null; then
    run_spin "安装 Node.js..." brew install node
  else
    fail "未安装 Homebrew，请先安装: https://brew.sh"
  fi
}

install_node_linux() {
  if command -v apt-get &>/dev/null; then
    run_spin "安装 Node.js 22..." bash -c "curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt-get install -y nodejs"
  elif command -v yum &>/dev/null; then
    run_spin "安装 Node.js 22..." bash -c "curl -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash - && sudo yum install -y nodejs"
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

# ── 6. Claude CLI ──

step "安装 Claude CLI"

if command -v claude &>/dev/null; then
  ok "Claude CLI 已安装"
else
  run_spin "安装中..." npm install -g @anthropic-ai/claude-code
  ok "Claude CLI 安装完成"
fi

# ── 7. Codex CLI ──

step "安装 Codex CLI"

if command -v codex &>/dev/null; then
  ok "Codex CLI 已安装"
else
  run_spin "安装中..." npm install -g @openai/codex
  ok "Codex CLI 安装完成"
fi

# ── 8. 部署模式选择 + API 前缀 ──

step "配置部署模式"
cd "$SCRIPT_DIR"

DEPLOY_CONFIG="$SCRIPT_DIR/.deploy-mode"
ENV_FILE="$SCRIPT_DIR/.env"
WEB_MODE="local"
API_PREFIX=""
ADMIN_DOMAIN=""

# 读取或生成 API 前缀（8 位短 UUID）
if [[ -f "$ENV_FILE" ]] && grep -q "API_PREFIX=" "$ENV_FILE"; then
  API_PREFIX=$(grep "API_PREFIX=" "$ENV_FILE" | cut -d= -f2)
  # 如果是旧的长 UUID，自动截短
  if [[ ${#API_PREFIX} -gt 8 ]]; then
    API_PREFIX=${API_PREFIX:0:8}
    sed -i "s/^API_PREFIX=.*/API_PREFIX=$API_PREFIX/" "$ENV_FILE"
    ok "API 前缀已截短: /$API_PREFIX"
  else
    ok "API 前缀: /$API_PREFIX"
  fi
else
  FULL_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]')
  API_PREFIX=${FULL_UUID:0:8}
  echo "API_PREFIX=$API_PREFIX" >> "$ENV_FILE"
  ok "已生成 API 前缀: /$API_PREFIX"
fi

# 生成 nginx 配置
mkdir -p /omps/admin-service/nginx
sed "s/\${API_PREFIX}/$API_PREFIX/g" "$SCRIPT_DIR/nginx/default.conf.template" > /omps/admin-service/nginx/default.conf
ok "Nginx 配置已生成"

# 部署模式
if [[ -f "$DEPLOY_CONFIG" ]]; then
  WEB_MODE=$(cat "$DEPLOY_CONFIG")
  if [[ "$WEB_MODE" == "external" ]] && grep -q "ADMIN_DOMAIN=" "$ENV_FILE" 2>/dev/null; then
    ADMIN_DOMAIN=$(grep "ADMIN_DOMAIN=" "$ENV_FILE" | cut -d= -f2)
  fi
  ok "已有配置: admin-web $( [[ "$WEB_MODE" == "external" ]] && echo "独立部署 ($ADMIN_DOMAIN)" || echo '本机部署' )"
else
  echo ""
  select_option "   admin-web 前端部署方式：" "本机部署（Docker 容器）" "独立部署（Cloudflare Pages 等）"
  if [[ $SELECTED -eq 1 ]]; then
    WEB_MODE="external"
    echo ""
    read -rep "   请输入指向本服务器的域名（如 api.example.com）: " ADMIN_DOMAIN
    if [[ -z "$ADMIN_DOMAIN" ]]; then
      fail "域名不能为空，外部部署必须配置域名"
    fi
    echo "ADMIN_DOMAIN=$ADMIN_DOMAIN" >> "$ENV_FILE"
    ok "admin-web 独立部署，API 域名: $ADMIN_DOMAIN"
    warn "记得云服务商安全组已放行 ${BOLD}80/tcp${NC}，否则 Cloudflare 回源会报 522"
  else
    WEB_MODE="local"
    # 本机部署需要放行 3000 端口
    if [[ "$OS" == "Linux" ]] && command -v ufw &>/dev/null; then
      ufw allow 3000/tcp comment 'Admin Web' >/dev/null 2>&1
      info "放行 3000/tcp (Admin Web)"
    fi
    ok "admin-web 本机部署"
  fi
  echo "$WEB_MODE" > "$DEPLOY_CONFIG"
fi

# ── 9. Admin 平台 ──

step "部署 Admin 平台"
cd "$SCRIPT_DIR"

SERVER_HASH=$(git -C admin-server rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
export BUILD_COMMIT="$SERVER_HASH" BUILD_TIME CACHE_BUST="$SERVER_HASH"
run_spin "构建 Admin Server ($SERVER_HASH)..." docker compose build --no-cache server
# 验证镜像内 VERSION 与源码 HEAD 一致（防御 Docker cache 异常）
if [[ "$SERVER_HASH" != "unknown" ]]; then
  IMAGE_VERSION=$(docker run --rm omps-platform-server cat /app/VERSION 2>/dev/null | tr -d '\r\n')
  if [[ "$IMAGE_VERSION" != "$SERVER_HASH" ]]; then
    fail "镜像版本校验失败（预期 $SERVER_HASH，实际 '$IMAGE_VERSION'），可能命中旧 cache"
  fi
  ok "镜像版本校验通过 ($IMAGE_VERSION)"
fi
if [[ "$WEB_MODE" == "local" ]]; then
  run_quiet "启动容器（含 web）" docker compose --profile with-web up -d
else
  run_quiet "启动容器（无 web）" docker compose up -d
fi

info "等待 Admin Server 就绪..."
for i in $(seq 1 30); do
  HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" "http://localhost:80/$API_PREFIX/api/dashboard" -H "Authorization: Bearer test" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" == "401" || "$HTTP_CODE" == "200" ]]; then break; fi
  sleep 2
done
ok "Admin 平台已启动"

# ── 9. CLI Server 构建 ──

step "构建 CLI Server"
CLI_PID=""

if [[ -d "$SCRIPT_DIR/cli-server" ]]; then
  GO_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  GO_ARCH=$( [[ "$ARCH" == "arm64" ]] && echo arm64 || echo amd64 )
  run_spin "编译 Go 二进制..." docker run --rm -v "$SCRIPT_DIR/cli-server:/app" -w /app golang:1.26 \
    sh -c "CGO_ENABLED=0 GOOS=$GO_OS GOARCH=$GO_ARCH go build -o cli-server ./cmd/server"
  ok "CLI Server 构建完成"
else
  warn "cli-server/ 目录不存在，跳过"
fi

# ── 9.5 omps-mcp 构建（stdio 工具，无需启动）──

step "构建 omps-mcp"

if [[ -d "$SCRIPT_DIR/omps-mcp" ]]; then
  GO_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  GO_ARCH=$( [[ "$ARCH" == "arm64" ]] && echo arm64 || echo amd64 )
  run_spin "编译 omps-mcp 二进制..." docker run --rm -v "$SCRIPT_DIR/omps-mcp:/app" -w /app golang:1.26 \
    sh -c "CGO_ENABLED=0 GOOS=$GO_OS GOARCH=$GO_ARCH go build -o omps-mcp ./cmd/omps-mcp"
  ok "omps-mcp 构建完成（stdio 工具，Claude CLI 按需 spawn）"
else
  warn "omps-mcp/ 目录不存在，跳过"
fi

# ── 10. CLI Server 启动 ──

step "启动 CLI Server"

if [[ -f "$SCRIPT_DIR/cli-server/cli-server" ]]; then
  # 先清理所有已有进程
  pkill -f "cli-server/cli-server" 2>/dev/null || true
  sleep 1

  if [[ "$OS" == "Linux" ]] && command -v systemctl &>/dev/null; then
    # Linux: 统一用 systemd 管理
    SERVICE_FILE="/etc/systemd/system/omps-cli-server.service"
    sudo tee "$SERVICE_FILE" > /dev/null <<UNIT
[Unit]
Description=OMPS CLI Server
After=network.target docker.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$SCRIPT_DIR/cli-server
ExecStart=$SCRIPT_DIR/cli-server/cli-server
Restart=always
RestartSec=5
Environment=CLI_SERVER_TOKEN=dev-cli-token-2026
Environment=PORT=9100

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
    sudo systemctl enable omps-cli-server >/dev/null 2>&1
    sudo systemctl restart omps-cli-server
    sleep 2
    if systemctl is-active omps-cli-server >/dev/null 2>&1; then
      ok "CLI Server 已启动（systemd 服务）"
    else
      warn "CLI Server 启动失败，查看: journalctl -u omps-cli-server"
    fi
  else
    # macOS: 用 nohup
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
  fi
else
  warn "CLI Server 二进制不存在，跳过启动"
fi

# ── 开机自启（Linux Docker）──

if [[ "$OS" == "Linux" ]] && command -v systemctl &>/dev/null; then
  sudo systemctl enable docker 2>/dev/null && info "Docker 已设置开机自启"
fi

# ── 创建初始账号 ──

TEMP_USER=""
TEMP_PASS=""
ENTRY_PATH=""

for i in $(seq 1 15); do
  if curl -sf "http://localhost:80/$API_PREFIX/api/dashboard" >/dev/null 2>&1 || curl -sf "http://localhost:80/$API_PREFIX/api/auth/me" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

TEMP_RESULT=$(curl -sf -X POST "http://localhost:80/$API_PREFIX/api/auth/create-temp-account" -H "Content-Type: application/json" 2>/dev/null)
if [[ $? -eq 0 && -n "$TEMP_RESULT" ]]; then
  TEMP_USER=$(echo "$TEMP_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('username',''))" 2>/dev/null)
  TEMP_PASS=$(echo "$TEMP_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('password',''))" 2>/dev/null)
  ENTRY_PATH=$(echo "$TEMP_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('entry_path',''))" 2>/dev/null)
fi

step_done

# ── 摘要 ──

echo ""
echo -e "${GREEN}  ┌──────────────────────────────────┐${NC}"
echo -e "${GREEN}  │   部署完成                       │${NC}"
echo -e "${GREEN}  └──────────────────────────────────┘${NC}"
echo ""
echo -e "${YELLOW}请保存以下信息（仅显示一次）${NC}"

# 平台前端配置
API_DOMAIN="${ADMIN_DOMAIN:-服务器IP}"
echo ""
echo -e "   ${BLUE}┌──────────────────────────────────────┐${NC}"
echo -e "   ${BLUE}│  平台前端配置                        │${NC}"
echo -e "   ${BLUE}├──────────────────────────────────────┤${NC}"
echo -e "   ${BLUE}│${NC} API 入口  ${BOLD}/${API_PREFIX}${NC}"
if [[ "$WEB_MODE" == "local" ]]; then
  echo -e "   ${BLUE}│${NC} 前端地址  ${BOLD}http://localhost:3000${NC}"
else
  echo -e "   ${BLUE}│${NC} 环境变量  ${BOLD}VITE_API_BASE = https://${API_DOMAIN}/${API_PREFIX}${NC}"
fi
echo -e "   ${BLUE}└──────────────────────────────────────┘${NC}"

# 平台入口信息
if [[ -n "$TEMP_USER" && -n "$ENTRY_PATH" ]]; then
  echo ""
  echo -e "   ${YELLOW}┌──────────────────────────────────────┐${NC}"
  echo -e "   ${YELLOW}│  平台入口信息                        │${NC}"
  echo -e "   ${YELLOW}├──────────────────────────────────────┤${NC}"
  echo -e "   ${YELLOW}│${NC} 平台入口  ${BOLD}/${ENTRY_PATH}${NC}"
  echo -e "   ${YELLOW}│${NC} 临时账号  ${BOLD}${TEMP_USER}${NC}"
  echo -e "   ${YELLOW}│${NC} 临时密码  ${BOLD}${TEMP_PASS}${NC}"
  echo -e "   ${YELLOW}└──────────────────────────────────────┘${NC}"
fi

echo ""
echo "   服务状态:"
docker ps --filter "label=com.docker.compose.project=omps-platform" --format "   ✓ {{.Names}}  {{.Status}}" 2>/dev/null || true
if systemctl is-active omps-cli-server >/dev/null 2>&1; then
  echo "   ✓ cli-server  Running (systemd)"
fi
echo ""
echo -e "   CLI:"
echo -e "   claude  ${DIM}$(claude --version 2>/dev/null | head -1 || echo '未安装')${NC}"
echo -e "   codex   ${DIM}$(codex --version 2>/dev/null | head -1 || echo '未安装')${NC}"
echo ""
rm -f "$LOG_FILE"
