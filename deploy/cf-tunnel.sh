#!/usr/bin/env bash
# 给 Teldrive 加 Cloudflare Tunnel（cloudflared 容器，与 teldrive 同一网络）
set -euo pipefail
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
cd ~/teldrive

read -rsp "粘贴 Cloudflare Tunnel Token（输入不会显示）: " CF_TOKEN < /dev/tty; echo
[ -n "$CF_TOKEN" ] || { echo "Token 为空，已退出"; exit 1; }

umask 077
echo "TUNNEL_TOKEN=${CF_TOKEN}" > .env

if ! grep -q 'cloudflared:' docker-compose.yml; then
  cat > docker-compose.override.yml <<'EOF'
services:
  cloudflared:
    image: cloudflare/cloudflared:latest
    restart: always
    command: tunnel --no-autoupdate run
    environment:
      - TUNNEL_TOKEN=${TUNNEL_TOKEN}
    depends_on:
      - teldrive
EOF
fi

$SUDO docker compose up -d
sleep 8
$SUDO docker compose logs --tail 15 cloudflared
echo
echo "看到 Registered tunnel connection 就成功了。"
