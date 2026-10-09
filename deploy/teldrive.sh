#!/usr/bin/env bash
# Teldrive 一键部署：自动加 swap、装 Docker、本地 PostgreSQL，Teldrive 只监听 127.0.0.1:8080
set -euo pipefail
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

read -rp "你的 Telegram 用户名（不带 @）: " TG_USER < /dev/tty

# 1. 没有 swap 就加 2G
if ! swapon --show | grep -q .; then
  echo ">> 添加 2G swap"
  $SUDO fallocate -l 2G /swapfile
  $SUDO chmod 600 /swapfile
  $SUDO mkswap /swapfile >/dev/null
  $SUDO swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | $SUDO tee -a /etc/fstab >/dev/null
fi

# 2. 安装 Docker
if ! command -v docker >/dev/null 2>&1; then
  echo ">> 安装 Docker"
  curl -fsSL https://get.docker.com | $SUDO sh
fi

# 3. 配置
mkdir -p ~/teldrive && cd ~/teldrive
if [ -f config.toml ]; then
  echo "!! ~/teldrive/config.toml 已存在，为避免覆盖密钥，脚本停止。"; exit 1
fi
DB_PASS=$(openssl rand -hex 16)
JWT_SECRET=$(openssl rand -hex 32)
ENC_KEY=$(openssl rand -hex 32)

cat > config.toml <<EOF
[db]
data-source = "postgres://teldrive:${DB_PASS}@postgres/postgres"

[jwt]
allowed-users = ["${TG_USER}"]
secret = "${JWT_SECRET}"

[tg]
ntp = true

[tg.uploads]
encryption-key = "${ENC_KEY}"
EOF
chmod 600 config.toml
touch storage.db

cat > docker-compose.yml <<EOF
services:
  postgres:
    image: groonga/pgroonga:latest-alpine-17
    restart: always
    environment:
      - POSTGRES_USER=teldrive
      - POSTGRES_PASSWORD=${DB_PASS}
      - POSTGRES_DB=postgres
    volumes:
      - pg_data:/var/lib/postgresql/data
  teldrive:
    image: ghcr.io/tgdrive/teldrive
    restart: always
    depends_on:
      - postgres
    volumes:
      - ./config.toml:/config.toml
      - ./storage.db:/storage.db
    ports:
      - "127.0.0.1:8080:8080"
volumes:
  pg_data:
EOF

# 4. 启动
echo ">> 启动容器"
$SUDO docker compose up -d
sleep 10
$SUDO docker compose ps
echo
free -h
echo
echo "完成。请备份 ~/teldrive/config.toml（丢了加密密钥，文件就解不开）。"
