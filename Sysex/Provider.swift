import Foundation
import NetworkExtension
import Network
import OSLog

let log = Logger(subsystem: "local.clarity", category: "extension")

private let PROC_PIDPATHINFO_MAXSIZE: UInt32 = UInt32(MAXPATHLEN * 4)

// MARK: - 进程信息(内存缓存,按 audit token)

struct ProcInfo {
    var pid: UInt32
    var path: String?
    // 祖先进程路径链(发起进程 → pid 1,含发起进程自身)。NE 的 audit token
    // 只标识发起连接的进程,进程树语义靠这里展开:连接发起时实时回溯 ppid,
    // 子进程(Claude 调 bash 跑 curl 等)的祖先链天然包含 claude。
    // 链不完整(祖先已退出/孤儿挂 launchd/超限)时 truncated=true,匹配语义降级。
    var ancestors: [String] = []
    // 与 ancestors 对齐的 pid 链(ancestors[i] 的进程 pid = ancestorPids[i])。
    // --include-pid 按祖先 pid 精确匹配子树,零误伤(路径 contains 会命中
    // 其他 claude 实例;pid 是唯一标识)。
    var ancestorPids: [UInt32] = []
    var truncated: Bool = false
}

final class ProcInfoCache {
    static let shared = ProcInfoCache()
    private var cache: [Data: ProcInfo] = [:]
    private let queue = DispatchQueue(label: "local.clarity.proccache")
    private static let maxAncestry = 64

    func info(fromAuditToken tokenData: Data?) -> ProcInfo? {
        guard let tokenData = tokenData, tokenData.count == MemoryLayout<audit_token_t>.size else {
            return nil
        }
        return queue.sync {
            if let cached = cache[tokenData] { return cached }
            let token = tokenData.withUnsafeBytes {
                $0.baseAddress!.assumingMemoryBound(to: audit_token_t.self).pointee
            }
            let pid = audit_token_to_pid(token)
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(PROC_PIDPATHINFO_MAXSIZE))
            defer { buf.deallocate() }
            let path: String? = proc_pidpath(pid, buf, PROC_PIDPATHINFO_MAXSIZE) > 0
                ? String(cString: buf) : nil
            var info = ProcInfo(pid: UInt32(pid), path: path)
            (info.ancestors, info.ancestorPids, info.truncated) = ancestryChain(pid: pid, buf: buf)
            cache[tokenData] = info
            return info
        }
    }

    /// ppid 回溯生成祖先链(含自身):路径 + 对齐的 pid。走公开 sysctl
    /// KERN_PROC_PID(kinfo_proc.kp_eproc.e_ppid),无需特权。防环 + 上限;
    /// 链中断置 truncated。
    private func ancestryChain(pid: pid_t, buf: UnsafeMutablePointer<UInt8>) -> ([String], [UInt32], Bool) {
        var paths: [String] = []
        var pids: [UInt32] = []
        var visited: Set<pid_t> = []
        var cur = pid
        var truncated = false
        while cur > 1 {
            if paths.count >= Self.maxAncestry || visited.contains(cur) {
                truncated = true
                break
            }
            visited.insert(cur)
            var kp = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, cur]
            guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else {
                truncated = true  // 进程已退出/sysctl 失败——链断
                break
            }
            pids.append(UInt32(cur))
            if proc_pidpath(cur, buf, PROC_PIDPATHINFO_MAXSIZE) > 0 {
                paths.append(String(cString: buf))
            } else {
                paths.append("")  // pid 可取但路径拿不到(短命进程)——保持对齐
            }
            cur = kp.kp_eproc.e_ppid
        }
        return (paths, pids, truncated)
    }
}

// MARK: - 进程过滤配置

struct FilterRule {
    // 进程树匹配模式:
    //   false(默认)= 旧语义,仅发起连接的进程 path.contains(include)
    //   true  = 祖先链任一命中(include-tree)——Claude 调工具的子进程流量全覆盖。
    //           链不完整(truncated)时降级为保守策略:视为不匹配放行(避免误伤
    //           正常孤儿进程),审计可见 ancestry_incomplete。
    var treeMode = false
    // nil = 全部拦截
    var includePaths: [String] = []
    var excludePaths: [String] = []
    // --include-pid:祖先链 pid 精确匹配——只拦指定进程及其枝干,零误伤
    // (路径 contains 会命中其他 claude 实例;pid 是唯一标识,重用窗口极小)。
    // 非空时按 pid 匹配,忽略 includePaths(两种树匹配互斥,pid 优先)。
    var includePids: [UInt32] = []
    // 始终放行本扩展自身与系统关键进程
    private let alwaysExclude = [
        "/System/",
        "/usr/libexec/",
        "/usr/sbin/",
        "/sbin/",
    ]
    // gatekeeper 数据面进程必须无条件放行(含 tree 模式):树匹配会把它
    // 也圈进 claude 祖先链(从 claude 的 shell 启动)→ gatekeeper 出网回环
    // 被自己截获 → 死循环。按路径 contains 排除。
    private let infraExclude = [
        "gatekeeper",
        "/local.clarity.",
        "/NetProxy.app/",
    ]

    func shouldIntercept(_ info: ProcInfo) -> Bool {
        guard let path = info.path else { return false }
        // gatekeeper/扩展自身:无条件放行(回环防护,任何模式)
        if infraExclude.contains(where: { path.contains($0) }) { return false }
        // 祖先链里也查:数据面 dialOut 的发起进程是 gatekeeper 本身,上面已放行;
        // 这里再兜一层(比如改名部署)。
        if treeMode && info.ancestors.contains(where: { anc in
            infraExclude.contains { anc.contains($0) } }) { return false }
        // 上游代理回环流量由 NENetworkRule 层面排除;此处兜底
        if alwaysExclude.contains(where: { path.hasPrefix($0) }) && includePaths.isEmpty {
            return false
        }
        if excludePaths.contains(where: { path.contains($0) }) { return false }
        if !includePids.isEmpty {
            // pid 树匹配:祖先链(含发起进程自身)的 pid 精确命中。
            return info.ancestorPids.contains { p in includePids.contains(p) }
        }
        if includePaths.isEmpty { return true }
        if treeMode {
            // 祖先链任一命中即拦(含发起进程自身)。链不完整且未命中 → 放行
            // (孤儿进程不误伤;真要全拦的用户用非 tree 模式全拦兜底)。
            return info.ancestors.contains { anc in
                includePaths.contains { pat in anc.contains(pat) }
            }
        }
        return includePaths.contains(where: { path.contains($0) })
    }
}

// MARK: - 上游连接桥接

/// 把 NEAppProxyTCPFlow 双向桥接到上游连接(direct / socks5:// / gatekeeper IPC)。
/// SOCKS5 握手为最小实现:无认证 CONNECT,远端地址用域名优先(避免扩展内做 DNS)。
/// gatekeeper 模式:先发 IPC 头(u32 BE 长度 + JSON),再泵裸流——
/// 头在 completion 里确认送达后才 open flow,硬保证头先于任何 flow 字节。
///
/// gk 模式断连自愈:gatekeeper 重启/升级时 IPC 端口短暂消失,旧实现一次性
/// fail-close teardown——flow 报错关闭,且频繁的失败 bridge 会拖垮 NESM
/// provider 状态机(真机 3 次僵死,重启 Mac 唯一解)。现在 gk 模式的
/// waiting/failed 走指数退避重连(250ms 起,2x,封顶 10s,无上限),重连成功
/// 后重新发 IPC 头并恢复双向泵——客户端 TCP 侧只感受到延迟,连接不断。
/// 客户端主动断开(flow read EOF)仍立即收尾;非 gk 上游维持一次性语义。
final class TCPBridge {
    enum Upstream {
        case direct(Network.NWEndpoint)
        case socks5(host: String, port: UInt16, target: String, targetPort: UInt16)
        // gatekeeper IPC:unix socket 路径或 127.0.0.1 TCP fallback;
        // target = 被拦截 flow 的真实目标(IP:port,来自 remoteEndpoint)。
        // ancestors = 发起进程祖先路径链(进程树归因给 gatekeeper)。
        case gk(path: String?, host: String?, port: UInt16?, pid: UInt32, proc: String, ancestors: [String], ancestorPids: [UInt32], target: String, targetPort: UInt16)
    }

    let flow: NEAppProxyTCPFlow
    private var conn: NWConnection!
    private let logCtx: String
    var onDone: ((TCPBridge) -> Void)?
    private let upstream: Upstream
    // gk 重连状态（conn 重建须在串行队列上;用全局队列 + 锁足够——回调本身串行到队列）
    private var reconnectAttempts = 0
    private var reconnecting = false
    private var flowOpen = false
    private let queue = DispatchQueue(label: "local.clarity.bridge")

    init(flow: NEAppProxyTCPFlow, upstream: Upstream, upstreamHost: String, upstreamPort: UInt16) {
        self.flow = flow
        self.upstream = upstream
        self.logCtx = flow.metaData.sourceAppSigningIdentifier ?? "?"
        self.conn = Self.makeConn(upstream: upstream)
    }

    private static func makeConn(upstream: Upstream) -> NWConnection {
        switch upstream {
        case .direct(let ep):
            return NWConnection(to: ep, using: .tcp)
        case .socks5(let upstreamHost, let upstreamPort, _, _):
            return NWConnection(
                host: NWEndpoint.Host(upstreamHost),
                port: NWEndpoint.Port(rawValue: upstreamPort)!,
                using: .tcp)
        case .gk(let path, let host, let port, _, _, _, _, _, _):
            if let path = path {
                return NWConnection(to: .unix(path: path), using: .tcp)
            }
            return NWConnection(
                host: NWEndpoint.Host(host ?? "127.0.0.1"),
                port: NWEndpoint.Port(rawValue: port ?? 8444)!,
                using: .tcp)
        }
    }

    func start() {
        attachHandler(conn)
        conn.start(queue: queue)
    }

    private func attachHandler(_ c: NWConnection) {
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.reconnectAttempts = 0
                switch self.mode {
                case .direct:
                    self.openFlowIfNeeded()
                    self.pumpFlowToConn()
                    self.pumpConnToFlow()
                case .socksHandshake:
                    self.doSocksHandshake()
                case .gkHeader:
                    self.sendGkHeader()
                case .relaying:
                    break
                }
            case .failed(let err):
                log.error("bridge \(self.logCtx, privacy: .public) conn failed: \(err, privacy: .public)")
                if case .gk = self.upstream {
                    self.reconnecting = true
                    self.scheduleReconnectQueued(reason: "failed")
                } else {
                    self.teardown(err)
                }
            case .cancelled:
                // 主动 cancel:重连流程里自己 cancel 旧 conn 后会走到这——
                // 若正在重连则忽略(reconnect 已排程);否则是最终收尾。
                if !self.reconnecting {
                    self.teardown(nil)
                }
            case .waiting(let werr):
                // gatekeeper 不在/挂起:不再一次性 fail-close——排程重连。
                // 先置 reconnecting 再 cancel:否则 cancelled 回调会在 async 的
                // scheduleReconnect 排程之前到达,race 判"非重连中"→ teardown,
                // flow 被关掉(真机:客户端 0s 空响应)。
                // 安全语义保留:重连成功前客户端字节不发往上游(连接停滞即
                // 显式信号),恢复后自动续传。
                if case .gk = self.upstream {
                    log.error("bridge \(self.logCtx, privacy: .public) gk conn waiting: \(werr, privacy: .public) — scheduling reconnect")
                    self.reconnecting = true
                    self.conn.cancel()
                    self.scheduleReconnectQueued(reason: "waiting")
                } else {
                    log.error("bridge \(self.logCtx, privacy: .public) conn waiting: \(werr, privacy: .public)")
                }
            case .preparing:
                log.info("bridge \(self.logCtx, privacy: .public) preparing")
            default:
                log.info("bridge state update")
                break
            }
        }
    }

    /// gk 断连退避重连:250ms 起 2x 封顶 10s,无上限(gatekeeper 恢复即续)。
    /// 调用方已置 reconnecting=true(防 cancelled race);这里排程延迟重拨。
    private func scheduleReconnectQueued(reason: String) {
        // 状态回调可能在桥的 queue 上;统一回自己的 queue 排程。
        queue.async { [weak self] in
            guard let self else { return }
            let delay = min(10.0, 0.25 * pow(2.0, Double(self.reconnectAttempts)))
            self.reconnectAttempts += 1
            log.info("bridge \(self.logCtx, privacy: .public) reconnect #\(self.reconnectAttempts) in \(Int(delay * 1000))ms (\(reason, privacy: .public))")
            self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.conn = Self.makeConn(upstream: self.upstream)
                self.attachHandler(self.conn)
                // 重连成功后回到 gkHeader 阶段重新发 IPC 头(协议状态从头走)。
                if self.mode == .relaying { self.mode = .gkHeader }
                self.reconnecting = false
                self.conn.start(queue: self.queue)
            }
        }
    }

    private enum Mode { case direct, socksHandshake, gkHeader, relaying }
    private var mode: Mode = .direct
    private var socksTarget: (host: String, port: UInt16)?

    func startSocks(target host: String, port: UInt16) {
        mode = .socksHandshake
        socksTarget = (host, port)
        start()
    }

    func startGk() {
        mode = .gkHeader
        start()
    }

    /// gk 拦截入口：flow 立即 open（客户端字节进 NE 内核缓冲，gk 断线窗口不 RST），
    /// IPC 头随后在重连成功时送达。安全语义不变：gk 不可达期间字节不外发。
    func startGkWithFlowOpen() {
        mode = .gkHeader
        openFlowIfNeeded()
        start()
    }

    /// 发送 IPC 头(u32 BE 长度 + JSON);在 completion 里确认送达后才
    /// open flow + 起泵——硬保证头先于任何 flow 字节。
    private func sendGkHeader() {
        guard case .gk(_, _, _, let pid, let proc, let ancestors, let ancestorPids, let target, let targetPort) = upstream else {
            teardown(POSIXError(POSIXError.EINVAL)); return
        }
        struct GkHeader: Codable {
            let v: Int
            let pid: UInt32
            let proc: String
            let anc: [String]?
            let ancpids: [UInt32]?
            let dst: String
            let dport: UInt16
        }
        let hdr = GkHeader(v: 1, pid: pid, proc: proc, anc: ancestors.isEmpty ? nil : ancestors, ancpids: ancestorPids.isEmpty ? nil : ancestorPids, dst: target, dport: targetPort)
        var body: Data
        do { body = try JSONEncoder().encode(hdr) } catch {
            teardown(error); return
        }
        var packet = Data(count: 4)
        packet[0] = UInt8((body.count >> 24) & 0xff)
        packet[1] = UInt8((body.count >> 16) & 0xff)
        packet[2] = UInt8((body.count >> 8) & 0xff)
        packet[3] = UInt8(body.count & 0xff)
        packet.append(body)
        conn.send(content: packet, completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            if let err { self.teardown(err); return }
            self.startRelay()
        })
    }

    private func doSocksHandshake() {
        guard let t = socksTarget else { teardown(POSIXError(POSIXError.EINVAL)); return }
        // greeting: VER=5 NMETHODS=1 METHOD=0(no auth)
        conn.send(content: Data([0x05, 0x01, 0x00]), completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            if let err { self.teardown(err); return }
            self.conn.receive(minimumIncompleteLength: 2, maximumLength: 2) { data, _, _, err in
                guard let data = data, data.count == 2, data[0] == 0x05, data[1] == 0x00 else {
                    self.teardown(err ?? POSIXError(POSIXError.EPROTO)); return
                }
                self.sendSocksConnect(host: t.host, port: t.port)
            }
        })
    }

    private func sendSocksConnect(host: String, port: UInt16) {
        var req = Data([0x05, 0x01, 0x00, 0x03]) // CONNECT + domain
        let hostBytes = Array(host.utf8)
        req.append(UInt8(hostBytes.count))
        req.append(contentsOf: hostBytes)
        req.append(UInt8(port >> 8)); req.append(UInt8(port & 0xff))
        conn.send(content: req, completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            if let err { self.teardown(err); return }
            // 回复头: VER REP RSV ATYP ADDR(变长) PORT;多读一些再按 ATYP 截断
            self.conn.receive(minimumIncompleteLength: 4, maximumLength: 262) { data, _, _, err in
                guard let data = data, data.count >= 4, data[0] == 0x05 else {
                    self.teardown(err ?? POSIXError(POSIXError.EPROTO)); return
                }
                if data[1] != 0x00 {
                    log.error("socks connect rejected rep=\(data[1])")
                    self.teardown(POSIXError(POSIXError.ECONNREFUSED)); return
                }
                let atyp = data[3]
                let addrLen: Int
                switch atyp {
                case 0x01: addrLen = 4
                case 0x03: addrLen = Int(data.count > 4 ? data[4] : 0) + 1
                default: addrLen = 16
                }
                if data.count < 4 + addrLen + 2 {
                    // 极少见:回复分片。简化处理:再收一次剩余。
                    self.finishSocksAfterExtra()
                    return
                }
                self.startRelay()
            }
        })
    }

    private func finishSocksAfterExtra() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, _, _ in
            self?.startRelay()
        }
    }

    private func startRelay() {
        mode = .relaying
        openFlowIfNeeded()
        pumpFlowToConn()
        pumpConnToFlow()
    }

    /// flow 提前 open（handleNewFlow 返回 true 后尽快）：open 之前客户端字节
    /// 无处缓冲，gk 断线重连窗口内客户端会拿到 RST（真机 Broken pipe）。
    /// open 后字节在 NE 内核缓冲排队，重连成功恢复泵后自动续传。
    private func openFlowIfNeeded() {
        guard !flowOpen else { return }
        flowOpen = true
        Task { try await flow.open(withLocalEndpoint: nil) }
    }

    private func pumpFlowToConn() {
        flow.readData { [weak self] data, err in
            guard let self else { return }
            if err == nil, let data = data, !data.isEmpty {
                self.conn.send(content: data, completion: .contentProcessed { err2 in
                    if err2 == nil { self.pumpFlowToConn() } else { self.teardown(err2) }
                })
            } else {
                self.conn.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                    self.closeConnHalf()
                })
                flow.closeReadWithError(nil)
            }
        }
    }

    private func pumpConnToFlow() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, err in
            guard let self else { return }
            if let data = data, !data.isEmpty {
                flow.write(data) { werr in
                    if werr == nil { self.pumpConnToFlow() } else { self.teardown(werr) }
                }
            } else if isComplete || err != nil {
                flow.closeWriteWithError(err)
                self.conn.cancel()
            } else {
                pumpConnToFlow()
            }
        }
    }

    private func closeConnHalf() {
        // flow 读端关闭:上游可以继续给我们写?TCP 半关场景少见,直接整体收尾简单可靠
        conn.cancel()
    }

    private func teardown(_ err: Error?) {
        conn.cancel()
        flow.closeReadWithError(err)
        flow.closeWriteWithError(err)
        onDone?(self)
    }
}

// MARK: - Provider

// 注意:本文件 import 了 Network,因此不能在此处 override handleNewUDPFlow
// (其参数是 NetworkExtension.NWEndpoint 类,与 Network.NWEndpoint 枚举同名歧义)。
// UDP override 在 UDPFlow.swift 的 BaseProvider 中。
class Provider: BaseProvider {
    /// providerConfiguration 里取出来的规则
    private var filter = FilterRule()
    private var upstreamMode = "direct" // direct | socks5 | gk
    private var socksHost = "127.0.0.1"
    private var socksPort: UInt16 = 1080
    // gatekeeper IPC(上游为 gk 时生效):unix socket 优先,否则 127.0.0.1 TCP
    private var ipcPath: String?
    private var ipcHost: String?
    private var ipcPort: UInt16?
    // 强引用所有活跃 bridge,防止 handleNewFlow 返回后被释放。
    // bridges 在 NWConnection 的全局队列回调里被 append/removeAll——
    // 并发 teardown 时无锁 removeAll(where:) 直接崩溃(真机 EXC_BREAKPOINT,
    // 崩溃栈 Array.replaceSubrange ← removeAll(where:) ← handleNewFlow 闭包),
    // 所有访问必须持锁。
    private let bridgesLock = NSLock()
    private var bridges: [TCPBridge] = []

    private func addBridge(_ b: TCPBridge) {
        bridgesLock.lock(); bridges.append(b); bridgesLock.unlock()
    }

    private func removeBridge(_ b: TCPBridge) {
        bridgesLock.lock(); bridges.removeAll { $0 === b }; bridgesLock.unlock()
    }

    // handleNewFlow 内的便捷包装(避免与局部变量名冲突的可读性别名)
    fileprivate func selfBridges_add(_ b: TCPBridge) { addBridge(b) }
    fileprivate func selfBridges_remove(_ b: TCPBridge) { removeBridge(b) }

    override func startProxy(options: [String: Any]? = nil) async throws {
        if let conf = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration {
            applyConfig(conf)
        }
        let modeDesc: String
        if !filter.includePids.isEmpty { modeDesc = "pid:\(filter.includePids)" }
        else if filter.treeMode { modeDesc = "tree" }
        else { modeDesc = "flat" }
        log.info("starting: mode=\(self.upstreamMode, privacy: .public) match=\(modeDesc, privacy: .public) include=\(self.filter.includePaths, privacy: .public) exclude=\(self.filter.excludePaths, privacy: .public) ipc=\(self.ipcPath ?? self.ipcHost.map { "\($0):\(self.ipcPort ?? 0)" } ?? "none", privacy: .public)")

        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = [
            NENetworkRule(
                remoteNetwork: nil, remotePrefix: 0,
                localNetwork: nil, localPrefix: 0,
                protocol: .any, direction: .outbound)
        ]
        // 排除回环:上游 socks5 走 127.0.0.1,provider 自身连接必须能出去
        settings.excludedNetworkRules = [
            NENetworkRule(
                remoteNetwork: NWHostEndpoint(hostname: "127.0.0.1", port: "1"),
                remotePrefix: 32,
                localNetwork: nil, localPrefix: 0,
                protocol: .any, direction: .outbound),
        ]
        try await setTunnelNetworkSettings(settings)
    }

    /// providerConfiguration → 内存规则（startProxy 冷启与 handleAppMessage 热更共用）。
    private func applyConfig(_ conf: [String: Any]) {
        if let inc = conf["includeProcessPaths"] as? [String] { filter.includePaths = inc }
        if let exc = conf["excludeProcessPaths"] as? [String] { filter.excludePaths = exc }
        if let m = conf["upstreamMode"] as? String { upstreamMode = m }
        if let h = conf["upstreamHost"] as? String { socksHost = h }
        if let p = conf["upstreamPort"] as? Int { socksPort = UInt16(clamping: p) }
        if let s = conf["ipcPath"] as? String, !s.isEmpty { ipcPath = s }
        if let h = conf["ipcHost"] as? String, !h.isEmpty { ipcHost = h }
        if let p = conf["ipcPort"] as? Int, p > 0 { ipcPort = UInt16(clamping: p) }
        if let t = conf["treeMode"] as? Bool { filter.treeMode = t }
        else if let t = conf["treeMode"] as? Int { filter.treeMode = (t != 0) }
        if let pids = conf["includePids"] as? [Int] {
            filter.includePids = pids.map { UInt32(clamping: max(0, $0)) }
        } else if let pids = conf["includePids"] as? [NSNumber] {
            filter.includePids = pids.map { $0.uint32Value }
        }
    }

    /// 运行时热更新（NEProvider.sendMessage 通道）：Host CLI 把**全量**新配置字典
    /// 推给活着的 provider——不重启进程、不碰 NESM 状态机，加/删 pid 从此绕开
    /// "必须 sudo kill 扩展进程"的循环（真机两天 5 次事故的根治）。
    /// 热更只改内存 FilterRule；持久化由 Host CLI 的 saveToPreferences 负责
    /// （冷启时 startProxy 仍从 providerConfiguration 读）。
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        handleAppMessageBody(messageData) { ack in
            completionHandler?(ack)
        }
    }

    /// 热更处理体（独立函数，completion 形态由上面的官方 override 调用）。
    private func handleAppMessageBody(_ messageData: Data, completion: @escaping (Data?) -> Void) {
        // 消息形态：{"type":"config","config":{...providerConfiguration 形态...}}。
        // 手动 JSONSerialization 解析（providerConfiguration 本就是 plist 混合类型）。
        guard let obj = try? JSONSerialization.jsonObject(with: messageData, options: []),
              let dict = obj as? [String: Any],
              dict["type"] as? String == "config",
              let conf = dict["config"] as? [String: Any] else {
            log.error("handleAppMessage: unrecognized message")
            completion(Data("{}".utf8))
            return
        }
        applyConfig(conf)
        let modeDesc: String
        if !filter.includePids.isEmpty { modeDesc = "pid:\(filter.includePids)" }
        else if filter.treeMode { modeDesc = "tree" }
        else { modeDesc = "flat" }
        log.info("hot-reloaded: mode=\(self.upstreamMode, privacy: .public) match=\(modeDesc, privacy: .public) include=\(self.filter.includePaths, privacy: .public) exclude=\(self.filter.excludePaths, privacy: .public) ipc=\(self.ipcPath ?? self.ipcHost.map { "\($0):\(self.ipcPort ?? 0)" } ?? "none", privacy: .public)")
        // 回执：当前生效的匹配集（Host CLI 验证用）。
        let ack: [String: Any] = [
            "ok": true,
            "match": modeDesc,
            "includePids": filter.includePids.map { Int($0) },
            "includePaths": filter.includePaths,
        ]
        completion((try? JSONSerialization.data(withJSONObject: ack)) ?? Data("{}".utf8))
    }

    override func stopProxy(with reason: NEProviderStopReason) async {
        log.info("stopProxy reason=\(reason.rawValue)")
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let info = ProcInfoCache.shared.info(
            fromAuditToken: flow.metaData.sourceAppAuditToken)
        guard let info else {
            log.debug("no process info, bypass: \(flow.metaData.sourceAppSigningIdentifier ?? "?")")
            return false
        }
        guard filter.shouldIntercept(info) else { return false }

        guard let tcp = flow as? NEAppProxyTCPFlow,
              let remote = tcp.remoteEndpoint as? NWHostEndpoint else {
            // UDP 交给系统(无法在扩展内做透明 UDP 上游,SOCKS UDP 需 ASSOCIATE)
            return false
        }
        let (host, port) = Self.parse(remote)
        let ancTag = info.ancestors.isEmpty ? "" : " anc=" + (info.ancestors.last(where: { $0.contains("claude") || $0.contains("node") }) ?? info.ancestors.first ?? "?")
        log.info("intercept \(info.path ?? "?", privacy: .public)\(ancTag, privacy: .public) -> \(host, privacy: .public):\(port)")

        let bridge: TCPBridge
        if upstreamMode == "gk" {
            bridge = TCPBridge(flow: tcp, upstream: .gk(
                path: ipcPath, host: ipcHost, port: ipcPort,
                pid: info.pid, proc: info.path ?? "", ancestors: info.ancestors,
                ancestorPids: info.ancestorPids, target: host, targetPort: port),
                upstreamHost: ipcHost ?? "127.0.0.1", upstreamPort: ipcPort ?? 8444)
            selfBridges_add(bridge)
            bridge.onDone = { [weak self] b in self?.selfBridges_remove(b) }
            bridge.startGkWithFlowOpen()
        } else if upstreamMode == "socks5" {
            bridge = TCPBridge(flow: tcp, upstream: .socks5(
                host: socksHost, port: socksPort, target: host, targetPort: port),
                upstreamHost: socksHost, upstreamPort: socksPort)
            selfBridges_add(bridge)
            bridge.onDone = { [weak self] b in self?.selfBridges_remove(b) }
            bridge.startSocks(target: host, port: port)
        } else {
            let ep = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
            bridge = TCPBridge(flow: tcp, upstream: .direct(ep),
                               upstreamHost: "", upstreamPort: 0)
            selfBridges_add(bridge)
            bridge.onDone = { [weak self] b in self?.selfBridges_remove(b) }
            bridge.start()
        }
        return true
    }

    static func parse(_ ep: NWHostEndpoint) -> (String, UInt16) {
        // NWHostEndpoint 的 hostname 对 IP 流量就是 IP 字符串
        let host = ep.hostname
        let port = UInt16(ep.port) ?? 0
        return (host, port)
    }
}
