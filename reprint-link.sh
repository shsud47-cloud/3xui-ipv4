#!/usr/bin/env bash
# Reprint the IPv4 Reality share link from /etc/x-ui without echoing private key.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "need root"; exit 1; }
[[ -f /etc/x-ui/reality-share.txt ]] || { echo "missing /etc/x-ui/reality-share.txt — run install first"; exit 1; }
# Prefer stored link; refresh IP if --refresh-ip
if [[ "${1:-}" == "--refresh-ip" ]]; then
  [[ -f /etc/x-ui/reality-ipv4.env ]] || { echo "missing reality-ipv4.env"; exit 1; }
  # shellcheck disable=SC1091
  source /etc/x-ui/reality-ipv4.env
  ip=""
  for u in https://api4.ipify.org https://ipv4.icanhazip.com https://v4.ident.me; do
    ip=$(curl -4 -fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]"') || true
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
  done
  [[ -n "$ip" ]] || { echo "cannot detect IPv4"; exit 1; }
  echo "vless://${UUID}@${ip}:${REALITY_PORT}?type=tcp&encryption=none&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&spx=%2F&flow=xtls-rprx-vision#VLESS-Reality-${REALITY_PORT}"
else
  grep '^VLESS_LINK=' /etc/x-ui/reality-share.txt | cut -d= -f2-
  grep '^PANEL_URL=' /etc/x-ui/reality-share.txt
fi
