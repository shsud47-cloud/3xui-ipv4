# 3x-ui 一键搭建（纯 IPv4 / VLESS+Reality）

给租用容器用的脚本：**全程 IPv4**，Xray 默认 `26.3.27`（兼容不完整指纹），Reality 默认 **2087**（也可选 **443**；禁止 22/8443）。

通过 **jsDelivr CDN** 拉取公开仓 `shsud47-cloud/3xui-ipv4`（GitHub 源，`@stable` 标签，避免 `@main` 长缓存），避免部分地区 / 容器 DNS 解析不了 `raw.githubusercontent.com`。

## 一键安装（root）

就这一条（`-4` 强制 IPv4）。装的时候脚本会在终端里问你端口（直接回车 = 默认）：

```bash
curl -4 -fsSL https://cdn.jsdelivr.net/gh/shsud47-cloud/3xui-ipv4@stable/install-3xui-ipv4.sh | bash
```

若提示 `Could not resolve host`（容器 `resolv.conf` 坏了），先修好 DNS 再跑同一条：

```bash
rm -f /etc/resolv.conf; printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >/etc/resolv.conf
```

会出现类似提示（经 `/dev/tty`，兼容 `curl|bash`）：

```text
======== 端口设置（直接回车 = 默认）========
禁止占用: 22 / 8443（SSH/宿主机保留）；Reality 可用 443
==========================================
面板端口 [2096]:
Reality端口 [2087]:
```

无终端（非交互）时自动用默认 `2096` / `2087`。

不写 `--public-ip` 时会自动探测公网 IPv4。需要强制指定时：

```bash
curl -4 -fsSL https://cdn.jsdelivr.net/gh/shsud47-cloud/3xui-ipv4@stable/install-3xui-ipv4.sh | bash -s -- --public-ip 1.2.3.4
```

## 默认

| 项 | 值 | 说明 |
|---|---|---|
| 面板端口 | `2096` | 安装时询问；HTTP + 随机 path |
| Reality 端口 | `2087` | 安装时询问；**可用 `443`**；禁止 `22` / `8443` |
| SNI / dest | `www.apple.com` | 可改 `--sni` |
| Xray | `26.3.27` | `--xray-ver` |
| 3x-ui | `v3.11.0` | `--xui-tag` |

## 脚本稳定性

- 启动时若 DNS 不可用，会自动写入 `1.1.1.1` / `8.8.8.8`
- 拉 3x-ui 官方安装包、Xray 二进制：`curl -4` + 每源 3 次重试 + jsDelivr / GitHub / ghfast 镜像回退
- 失败时打印已尝试的 URL 和排查命令

## 常用参数

- `--sni HOST`：伪装域名
- `--public-ip IP`：强制链接里的 IPv4（默认自动探测）
- `--skip-install`：面板已装，只关 v6 + 降级 Xray + 加 Reality
- `--force`：同端口已有入站时覆盖
- `--dry-run`：只打印步骤
- `--panel-port` / `--reality-port`（或环境变量 `PANEL_PORT` / `REALITY_PORT`）：非交互覆盖，跳过询问

## 注意

- 装在 Incus/LXC 容器里时，宿主机必须把面板口和 Reality 口 DNAT/proxy 进容器；**22 / 8443** 为系统保留勿占用。Reality 用 **443** 时宿主机需把 443 放进容器。
- 写库前用 `systemctl stop x-ui`（3.11.x 无 `x-ui stop/restart` 子命令），sqlite 用 `.timeout` 避免 PRAGMA 回显污染。
- 装失败半截可直接再跑同一条命令；或先卸干净再装。

## 重打分享链接

```bash
bash reprint-link.sh
```
