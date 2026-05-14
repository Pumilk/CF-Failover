# cf-failover

阿里云等流量受限前置机器的 Cloudflare DNS 自动故障切换工具。
监控主前置，断网后自动调用 CF API 切到备用 IP。

## 特性

- 交互式菜单，零文件编辑
- ping + TCP 双探测
- 多备用 IP 自动轮换
- systemd 守护，开机自启

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/Pumilk/CF-Failover/main/install.sh | sudo bash
sudo cf-failover.sh
```

## 配置流程

按菜单顺序 1 → 2 → 3 → 7 即可。

需要准备：
- Cloudflare API Token（权限模板选 **"编辑区域 DNS"**）
- Zone ID（CF 域名概览页右下角）
- 至少 2 个前置 IP

## License

MIT
