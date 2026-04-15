# Oh My Projects

一键部署 Oh My Projects 平台。

## 快速开始（Linux）

```bash
curl -fsSL https://raw.githubusercontent.com/oh-my-porjects/omps/main/setup.sh -o setup.sh && sudo bash setup.sh
```

脚本会自动完成：SSH Key 配置、Docker 安装、Node.js 安装、WireGuard 安装、Claude CLI / Codex CLI 安装、Admin 平台部署、CLI Server 构建启动。

首次部署完成后会生成临时账号密码（仅显示一次），登录后请创建正式账号并绑定 OTP。

## 更新

```bash
sudo ./setup.sh update
```

## 要求

- Linux（Ubuntu/Debian/CentOS）或 macOS
- 需要 GitHub SSH 访问权限
