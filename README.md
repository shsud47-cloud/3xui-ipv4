# 3x-ui 一键搭建（纯 IPv4 / VLESS+Reality）

给租用容器用的非交互脚本：**全程 IPv4**，Xray 默认 `26.3.27`（兼容不完整指纹），Reality 默认高位端口 **2087**（禁止 22/443/8443）。

## 一键安装（root）

```bash
curl -fsSL https://raw.githubusercontent.com/shsud47-cloud/3xui-ipv4/main/install-3xui-ipv4.sh | bash
```

自选端口（环境变量写在管道右侧才传给脚本；默认面板 `2096`、Reality `2087`）：

```bash
curl -fsSL https://raw.githubusercontent.com/shsud47-cloud/3xui-ipv4/main/install-3xui-ipv4.sh | PANEL_PORT=12345 REALITY_PORT=23456 bash
```

或用参数：

```bash
curl -fsSL https://raw.githubusercontent.com/shsud47-cloud/3xui-ipv4/main/install-3xui-ipv4.sh | bash -s -- --panel-port 12345 --reality-port 23456
```

不写 `--public-ip` 时会自动探测公网 IPv4。需要强制指定时：

```bash
curl -fsSL https://raw.githubusercontent.com/shsud47-cloud/3xui-ipv4/main/install-3xui-ipv4.sh | bash -s -- --public-ip 1.2.3.4
```

## 默认

| 项 | 值 | 说明 |
|---|---|---|
| 面板端口 | `2096` | HTTP + 随机 path；可用 `PANEL_PORT` / `--panel-port` |
| Reality 端口 | `2087` | **不是 443**；禁止 `22` / `443` / `8443` |
| SNI / dest | `www.apple.com` | 可改 `--sni` |
| Xray | `26.3.27` | `--xray-ver` |
| 3x-ui | `v3.11.0` | `--xui-tag` |

## 常用参数

- `--reality-port N` / `REALITY_PORT`：Reality 入站；禁止 22 / 443 / 8443
- `--panel-port N` / `PANEL_PORT`：面板（默认 2096）；禁止 22 / 443 / 8443
- `--sni HOST`：伪装域名
- `--public-ip IP`：强制链接里的 IPv4（默认自动探测）
- `--skip-install`：面板已装，只关 v6 + 降级 Xray + 加 Reality
- `--force`：同端口已有入站时覆盖
- `--dry-run`：只打印步骤

## 注意

- 装在 Incus/LXC 容器里时，宿主机必须把面板口和 Reality 口 DNAT/proxy 进容器；**22 / 8443 系统保留，不要占用**。
- 写库前用 `systemctl stop x-ui`（3.11.x 无 `x-ui stop/restart` 子命令），sqlite 用 `.timeout` 避免 PRAGMA 回显污染。
- 装失败半截可直接再跑同一条命令；或先卸干净再装。

## 重打分享链接

```bash
bash reprint-link.sh
```
