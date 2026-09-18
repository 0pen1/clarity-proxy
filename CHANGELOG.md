# Changelog

## 3.4 (2026-09-18)

- **热更 fallback 假成功根治**：公证版 host 的 sendMessage IPC entitlement 被 NESM 拒（devid entitlements 只有 `-systemextension` 后缀值，NESM 检查要裸 `app-proxy-provider`），fallback 落回冷启时若会话仍 connected，`startVPNTunnel` 被 NESM skip（no-op）→ 新配置永远到不了 provider，GUI 卡「连接中…」。现在 fallback 先 `stopVPNTunnel` 并等 disconnected（10s 超时上报 stopTimeout）再 start。真机事故：GUI 加 pid → 热更被拒 → fallback skip → forever「连接中…」。

## 2.9 (2026-09-15)

- **gk 断连自愈**：网关重启/IPC 消失不再导致 bridge 永久失效——flow 提前 open（客户端字节缓冲于 NE），上游连接指数退避重连（250ms→10s），恢复后自动重发 IPC 头续传。真机验证 8s 断窗 9.1s 恢复，provider 状态机不再僵死。
- race 修复：waiting 分支先置 reconnecting 再 cancel（否则 cancelled 回调先到会 teardown flow）。

## 2.8 (2026-09-15)

- gk 模式 flow 提前 open（自愈第一步，见 2.9）。

## 2.7 (2026-09-15)

- TCPBridge 重连循环骨架（waiting/failed 排程重连）。

## 2.6 (2026-09-14)

- `--include-pid`：按祖先链 pid 精确匹配子树，零误伤（pid 死后警告）。

## 2.5 (2026-09-14)

- `--include-tree`：进程树匹配（祖先链任一路径命中）；gatekeeper 数据面进程无条件放行（回环防护）。

## 2.4 / 2.3 (2026-09-14)

- Provider.bridges 并发修复（NSLock）；SOCKS 会话内 TLS MITM 支持。

## 2.2 (2026-09-14)

- Phase 2 全链路 e2e：TCP IPC fallback（unix socket 被扩展沙箱拒）。
