# 3x-ui 一键搭建（纯 IPv4 / VLESS+Reality）

固定命令（root，IP 自动探测）：

```bash
curl -fsSL https://raw.githubusercontent.com/shsud47-cloud/3xui-ipv4/main/install-3xui-ipv4.sh | bash
```

指定公网 IP：

```bash
curl -fsSL https://raw.githubusercontent.com/shsud47-cloud/3xui-ipv4/main/install-3xui-ipv4.sh | bash -s -- --public-ip 1.2.3.4
```

## 默认

| 项 | 值 |
|---|---|
| Reality 端口 | **2087**（禁止 443 / 8443） |
| 面板端口 | 2096 |
| Xray | **26.3.27**（避免新版拒不完整指纹） |
| 伪装 SNI | `www.apple.com` |
| 监听 | 仅 `0.0.0.0`（不用 `[::]`） |
| 出站 / DNS / Reality dest | 强制 IPv4 |

## 容器 / Incus 必读

装在容器里时，**宿主机必须把面板口和 Reality 口 DNAT/proxy 进容器**，否则外网一定超时。  
22、8443 为租用节点保留口，不要占用。

## 仍超时可试

```bash
# 换伪装（dest 会解析成该域名的 A 记录）
bash install-3xui-ipv4.sh --skip-install --force --sni dl.google.com --public-ip 你的IPv4

# 换普通高位端口
bash install-3xui-ipv4.sh --skip-install --force --reality-port 8448 --public-ip 你的IPv4
```

常用 SNI：`www.apple.com`、`dl.google.com`、`www.microsoft.com`、`www.cloudflare.com`（按线路自测）。

## 本脚本修过的坑

1. **3x-ui 3.x `flow_override`**：`ListForInbound` 用 `client_inbounds.flow_override` 覆盖 `clients.flow`；写成空会丢掉 `xtls-rprx-vision`，分享链接有 flow、服务端没有 → 客户端超时。
2. Reality `dest` 不走 freedom 出站，必须把 SNI 解析成 **A/IPv4** 再写入 dest。
3. 入站 `listen` 固定 `0.0.0.0`，避免双栈 `[::]`。
4. 安装后再次固定 Xray 26.3.27，并校验 `config.json` 里仍有 Vision。

仓库：https://github.com/shsud47-cloud/3xui-ipv4
