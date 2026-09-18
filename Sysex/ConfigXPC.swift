// 扩展侧规则热更通道（§9，Proxifier 架构复刻）：
// root 扩展进程内起 NSXPCListener（mach 服务名 = 扩展 bundle ID，
// Info.plist NetworkExtension.NEMachServiceName 同名声明驱动 launchd
// system domain 注册），宿主无沙箱直连推送全量 providerConfiguration。
// 绕开 sendProviderMessage（公证版被 NESM IPC entitlement 检查整体
// 拒绝，坑 20）。安全：校验连接方进程路径 = 本 app 宿主二进制——
// 不校验则本机任意进程可给 root 代理改上游（提权）。
import Foundation

// 宿主 ↔ 扩展共享的 XPC 协议（两端各自实现/调用，必须逐字同名）。
@objc protocol ConfigXPCProtocol {
    // 全量 providerConfiguration 字典（plist 兼容类型）。reply 字典
    // {"ok":true,"match":"...","includePids":[...]}（与 handleAppMessage
    // 回执同构，宿主验证逻辑复用）。
    @objc func pushConfig(_ conf: [String: Any], withReply reply: @escaping ([String: Any]) -> Void)
}

/// Provider 侧桥：Provider 把 applyConfig + 回执注入这里。
final class ConfigXPCServer: NSObject, NSXPCListenerDelegate {
    static let shared = ConfigXPCServer()

    // Provider 注入的处理闭包（startProxy 时设置；applyConfig 在
    // Provider 主语义里,这里只做转发,不 import 循环）。
    var applyConfig: (([String: Any]) -> [String: Any])?

    private var listener: NSXPCListener?
    private let queue = DispatchQueue(label: "local.clarity.configxpc")

    /// mach 服务名 = 扩展 bundle ID（与 Info.plist NEMachServiceName 一致）。
    static var machServiceName: String {
        Bundle.main.bundleIdentifier ?? "local.netproxy.3w73w8c23l.extension"
    }

    /// startProxy 里调用（幂等）。stopProxy 里 invalidate。
    func start() {
        queue.async { [weak self] in
            guard let self, self.listener == nil else { return }
            let l = NSXPCListener(machServiceName: Self.machServiceName)
            l.delegate = self
            l.resume()
            self.listener = l
            log.info("ConfigXPC: listening on \(Self.machServiceName, privacy: .public)")
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.invalidate()
            self?.listener = nil
            log.info("ConfigXPC: listener stopped")
        }
    }

    // MARK: NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard Self.isTrustedClient(newConnection) else {
            log.error("ConfigXPC: rejected untrusted client pid=\(newConnection.processIdentifier)")
            newConnection.invalidate()
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: ConfigXPCProtocol.self)
        newConnection.exportedObject = self
        newConnection.resume()
        return true
    }

    /// 连接方校验：pid → proc_pidpath = 本 app 宿主二进制。
    /// 不校验则本机任意进程可给 root 代理改上游（提权）。pid 在连接建立
    /// 后由系统绑定该连接,proc_pidpath 此刻读的是连接方真实路径——残余
    /// 竞态窗口毫秒级,威胁模型（本机读 App Store 分发 app 的配置）下足够。
    private static func isTrustedClient(_ conn: NSXPCConnection) -> Bool {
        let pid = pid_t(conn.processIdentifier)
        guard pid > 1 else { return false }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN * 4))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else {
            // 拿不到路径（权限/已退出）——拒绝（fail-close）
            return false
        }
        let path = String(cString: buf)
        let allowed = "/Applications/NetProxy.app/Contents/MacOS/NetProxy"
        if path == allowed { return true }
        // Xcode 调试构建: DerivedData 路径也放行（同一构建链,真机调试）
        if path.contains("DerivedData") && path.hasSuffix("/NetProxy") { return true }
        log.error("ConfigXPC: client path not trusted: \(path, privacy: .public)")
        return false
    }
}

extension ConfigXPCServer: ConfigXPCProtocol {
    func pushConfig(_ conf: [String: Any], withReply reply: @escaping ([String: Any]) -> Void) {
        guard let apply = applyConfig else {
            reply(["ok": false, "error": "provider not started"])
            return
        }
        let ack = apply(conf)
        reply(ack)
    }
}
