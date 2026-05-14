#!/usr/bin/env bash
set -e
REPO="https://raw.githubusercontent.com/Pumilk/CF-Failover/main"
DEST="/usr/local/bin/cf-failover.sh"
[[ $EUID -ne 0 ]] && { echo "需要 sudo"; exit 1; }

echo "[*] 下载脚本..."
curl -fsSL "$REPO/cf-failover.sh" -o "$DEST"
chmod +x "$DEST"

if ! command -v python3 >/dev/null; then
  echo "[*] 安装 python3..."
  if command -v apt >/dev/null; then apt update && apt install -y python3
  elif command -v dnf >/dev/null; then dnf install -y python3
  elif command -v yum >/dev/null; then yum install -y python3
  elif command -v apk >/dev/null; then apk add python3
  fi
fi

echo "[+] 安装完成，运行: sudo cf-failover.sh"
