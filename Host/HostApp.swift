import Foundation
import Darwin
import NetworkExtension
import SystemExtensions
import OSLog

// MARK: - 系统扩展安装器

private let hostLog = Logger(subsystem: "local.clarity", category: "host")

final class SysexInstaller: NSObject, OSSystemExtensionRequestDelegate, @unchecked Sendable {
    static let shared = SysexInstaller()
    var continuation: CheckedContinuation<Void, Error>?

    func activate() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.continuation = c
            let req = OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: ProxyCtl.extensionBundleID,
                queue: .main)
            req.delegate = self
            OSSystemExtensionManager.shared.submitRequest(req)
        }
    }

    func deactivate() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.continuation = c
            let req = OSSystemExtensionRequest.deactivationRequest(
                forExtensionWithIdentifier: ProxyCtl.extensionBundleID,
                queue: .main)
            req.delegate = self
            OSSystemExtensionManager.shared.submitRequest(req)
        }
    }

    func discover() async throws {
        if #available(macOS 12.0, *) {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                self.continuation = c
                let req = OSSystemExtensionRequest.propertiesRequest(
                    forExtensionWithIdentifier: ProxyCtl.extensionBundleID,
                    queue: .main)
                req.delegate = self
                OSSystemExtensionManager.shared.submitRequest(req)
            }
        } else {
            print("propertiesRequest requires macOS 12+")
        }
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties)
    -> OSSystemExtensionRequest.ReplacementAction {
        hostLog.info("replacing sysex \(existing.bundleVersion) -> \(ext.bundleVersion)")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        hostLog.info("sysex awaiting user approval - check System Settings")
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        hostLog.error("sysex request failed: \(error.localizedDescription, privacy: .public)")
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        hostLog.info("sysex activate finished: \(result.rawValue)")
        continuation?.resume()
        continuation = nil
    }

    func request(_ request: OSSystemExtensionRequest,
                 foundProperties properties: [OSSystemExtensionProperties]) {
        if properties.isEmpty {
            print("NO PROPERTIES FOUND (系统没有扫描到该 identifier 的扩展)")
        } else {
            for p in properties {
                let enabled = p.responds(to: Selector(("isEnabled"))) ? (p.value(forKey: "isEnabled") as? Bool ?? false) : false
                let awaiting = p.responds(to: Selector(("isAwaitingUserApproval"))) ? (p.value(forKey: "isAwaitingUserApproval") as? Bool ?? false) : false
                print("found: \(p.bundleIdentifier) v\(p.bundleVersion) enabled=\(enabled) awaiting=\(awaiting) url=\(p.url.path)")
            }
        }
        continuation?.resume()
        continuation = nil
    }
}

// MARK: - 代理配置启停

enum ProxyCtl {
    /// 扩展 bundle ID = host 自身 bundle ID + ".extension"（由构建注入的
    /// PRODUCT_BUNDLE_IDENTIFIER 决定，fork 用户改 project.yml 即整体换标识）。
    static let extensionBundleID = (Bundle.main.bundleIdentifier ?? "local.clarity") + ".extension"

    /// 解析 --include/--include-tree/--exclude/--include-pid/--remove-pid/
    /// --upstream/--ipc/--ipc-tcp 参数并应用。
    /// 合并语义：start 默认 MERGE 到现有规则上（--include-pid A 之后 --include-pid B
    /// = 同时监控两个 pid）——NETransparentProxyManager 是全局单配置，第二次 start
    /// 若整体替换会丢掉第一次的规则。--fresh 显式回到"整体替换"。
    /// 运行连接参数（upstream/ipc）以本次命令行为准：给了一项就整体替换这一组，
    /// 一项都没给则沿用现有值。
    static func apply(args: [String], enable: Bool) async throws {
        var include: [String] = []
        var exclude: [String] = []
        var treeMode: Bool? = nil
        var includePids: [Int] = []
        var removePids: [Int] = []
        var removeInclude: [String] = []
        var fresh = false
        var upstreamMode: String? = nil
        var upstreamHost: String? = nil
        var upstreamPort: Int? = nil
        var ipcPath: String? = nil
        var ipcHost: String? = nil
        var ipcPort: Int? = nil

        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--include":
                if let v = it.next() { include.append(v) }
            case "--include-tree":
                // 进程树匹配:祖先链(发起进程→pid 1)任一路径命中即拦——
                // claude 调 bash 跑 curl 的子进程流量全覆盖(树动态生长天然支持,
                // 连接发起时实时反查,非预登记)。孤儿进程(链断)放行。
                if let v = it.next() { include.append(v); treeMode = true }
            case "--include-pid":
                // pid 树匹配:祖先链 pid 精确命中——只拦该进程及其枝干,零误伤。
                // 用法:pgrep claude 拿 pid → --include-pid <pid>;其他 claude
                // 实例/手动启动的同名进程不受影响。可重复,merge 进现有集合。
                if let v = it.next(), let p = Int(v), p > 1 { includePids.append(p) }
            case "--remove-pid":
                // 从现有监控集合移除该 pid(被监控进程退出后清规则)。
                if let v = it.next(), let p = Int(v), p > 1 { removePids.append(p) }
            case "--remove-include":
                // 从现有 include 路径集合移除该子串。
                if let v = it.next() { removeInclude.append(v) }
            case "--exclude":
                if let v = it.next() { exclude.append(v) }
            case "--fresh":
                // 忽略现有规则,从本次命令行重建(旧行为)。
                fresh = true
            case "--upstream":
                if let v = it.next() {
                    // socks5://host:port 或 direct 或 gk
                    if v.hasPrefix("socks5://") {
                        upstreamMode = "socks5"
                        let rest = v.dropFirst("socks5://".count)
                        let parts = rest.split(separator: ":")
                        if parts.count >= 1 { upstreamHost = String(parts[0]) }
                        if parts.count >= 2 { upstreamPort = Int(parts[1]) ?? 1080 }
                    } else if v == "gk" {
                        upstreamMode = "gk"
                    } else if v == "direct" {
                        upstreamMode = "direct"
                    }
                }
            case "--ipc":
                if let v = it.next() { ipcPath = v }
            case "--ipc-tcp":
                if let v = it.next() {
                    let parts = v.split(separator: ":")
                    if parts.count >= 1 { ipcHost = String(parts[0]) }
                    if parts.count >= 2 { ipcPort = Int(parts[1]) }
                }
            default:
                fputs("unknown arg \(a)\n", stderr)
            }
        }

        // 读取现有配置（merge 基线）。
        let managers = try await NETransparentProxyManager.loadAllFromPreferences()
        let manager = managers.first { m in
            (m.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                == ProxyCtl.extensionBundleID
        } ?? NETransparentProxyManager()
        let oldProto = manager.protocolConfiguration as? NETunnelProviderProtocol
        let old = oldProto?.providerConfiguration ?? [:]

        // 合并规则集合：--fresh 或首次配置时以命令行为基线；否则在现有集合上增删。
        var mergedInclude: [String]
        var mergedExclude: [String]
        var mergedPids: [Int]
        if fresh || old.isEmpty {
            mergedInclude = include
            mergedExclude = exclude
            mergedPids = includePids
        } else {
            let oldInclude = (old["includeProcessPaths"] as? [String]) ?? []
            let oldExclude = (old["excludeProcessPaths"] as? [String]) ?? []
            let oldPids = ((old["includePids"] as? [NSNumber]) ?? []).map { $0.intValue }
            mergedInclude = Array(Set(oldInclude).union(include))
            mergedExclude = Array(Set(oldExclude).union(exclude))
            mergedPids = Array(Set(oldPids).union(includePids))
        }
        for p in removePids { mergedPids.removeAll { $0 == p } }
        for s in removeInclude { mergedInclude.removeAll { $0 == s } }

        // 运行连接参数：给了一项就整体替换这一组；一项没给则沿用现有。
        let oldUpstreamMode = (old["upstreamMode"] as? String) ?? "direct"
        let oldUpstreamHost = (old["upstreamHost"] as? String) ?? "127.0.0.1"
        let oldUpstreamPort = (old["upstreamPort"] as? Int) ?? 1080
        let effUpstreamMode = upstreamMode ?? oldUpstreamMode
        let effUpstreamHost = upstreamHost ?? oldUpstreamHost
        let effUpstreamPort = upstreamPort ?? oldUpstreamPort
        let effIpcPath = ipcPath ?? (old["ipcPath"] as? String)
        let effIpcHost = ipcHost ?? (old["ipcHost"] as? String)
        let effIpcPort = ipcPort ?? (old["ipcPort"] as? Int)
        // treeMode：本次给了 --include-tree 置 true；--fresh 时按命令行（无 tree 即 false）；
        // 否则沿用现有 true（一旦开过树匹配,merge 场景保持,避免第二次 start 静默关闭）。
        let oldTreeMode = (old["treeMode"] as? Bool) ?? false
        let effTreeMode = treeMode ?? (fresh ? false : oldTreeMode)

        if effUpstreamMode == "gk" && effIpcPath == nil && effIpcHost == nil {
            fputs("--upstream gk 需要 --ipc <socket-path> 或 --ipc-tcp 127.0.0.1:<port>\n", stderr)
            exit(2)
        }
        for p in mergedPids {
            var kp = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(p)]
            if sysctl(&mib, 4, &kp, &size, nil, 0) != 0 || size == 0 {
                fputs("警告: pid \(p) 不存在(已退出?)——pid 匹配将不会命中任何流量\n", stderr)
            }
        }

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = ProxyCtl.extensionBundleID
        proto.serverAddress = "local.clarity"
        // 注意:这里不能放机密,Apple 会把 providerConfiguration 记进系统日志
        // (socket 路径/回环地址非机密,明文无妨)
        var conf: [String: Any] = [
            "includeProcessPaths": mergedInclude,
            "excludeProcessPaths": mergedExclude,
            "upstreamMode": effUpstreamMode,
            "upstreamHost": effUpstreamHost,
            "upstreamPort": effUpstreamPort,
        ]
        conf["treeMode"] = effTreeMode
        if !mergedPids.isEmpty { conf["includePids"] = mergedPids }
        if let p = effIpcPath { conf["ipcPath"] = p }
        if let h = effIpcHost { conf["ipcHost"] = h }
        if let p = effIpcPort { conf["ipcPort"] = p }
        proto.providerConfiguration = conf
        manager.protocolConfiguration = proto
        manager.localizedDescription = "NetProxy"
        manager.isEnabled = enable

        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        if enable {
            // ---- 防假成功三件套（真机教训：proxy started/status:3 都会骗人）----
            // 1. start 前清场：扩展进程存活且年龄 > 90s（不可能属于本次 start
            //    生命周期）时，NESM 会复用它——新配置不会加载。提示并给出杀进程命令。
            await ProxyCtl.checkStaleProvider()

            try manager.connection.startVPNTunnel()

            // 2. 等 connected（startVPNTunnel 只是请求，隧道真正起来需要时间）。
            let connected = await ProxyCtl.waitConnected(timeout: 15)
            guard connected else {
                print("⚠️  proxy started 但 15s 内未 connected——僵尸 provider 特征：")
                print("   1) 重试: $APP stop && sleep 5 && $APP start ...")
                print("   2) 无效则: sudo pkill -9 -f local.netproxy  再重试")
                print("   3) 仍无效: 重启 Mac（NESM/内核状态机卡死唯一解）")
                print("   诊断: /usr/bin/log show --last 2m --info --debug --predicate 'process == \"nesessionmanager\" AND eventMessage CONTAINS \"NetProxy\"'")
                return
            }

            // 3. 端到端验证：startProxy 是否真的加载了新配置——看 provider 日志里
            //    本次 start 之后是否出现 "starting:" 行（Logger 需 --info --debug 落盘，
            //    这里用 subprocess 直接查 log store）。
            let startingOK = await ProxyCtl.verifyStartProxyLogged()
            if !startingOK {
                print("⚠️  connected 但 provider 未执行 startProxy（配置未加载）——")
                print("   NESM 复用了旧 provider 进程。处置同上：pkill 后重试，或重启 Mac。")
                return
            }
            print("proxy started (match: pids=\(mergedPids) include=\(mergedInclude) tree=\(effTreeMode))")
            print("✓ verified: connected + startProxy loaded (config: pid=\(mergedPids) include=\(mergedInclude))")
        } else {
            print("proxy stopped (config saved, disabled)")
        }
    }

    /// 扩展进程年龄检查：进程启动时间早于 90 秒前 = 它不属于本次 start，
    /// NESM 将复用它（新配置不会加载）。只警告不自动杀（需要 sudo）。
    static func checkStaleProvider() async {
        // pgrep 找扩展进程
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-f", "local.netproxy.*extension.systemextension"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let pids = String(data: data, encoding: .utf8)?
            .split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) } ?? []
        guard let pid = pids.first else { return }
        // 进程启动时间：ps -o lstart
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "lstart=", "-p", String(pid)]
        let psPipe = Pipe()
        ps.standardOutput = psPipe
        ps.standardError = Pipe()
        do { try ps.run(); ps.waitUntilExit() } catch { return }
        let started = String(data: psPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !started.isEmpty else { return }
        // 解析 "Wed Sep 16 13:56:26 2026" —— 简化：用 etime（elapsed）更稳。
        let et = Process()
        et.executableURL = URL(fileURLWithPath: "/bin/ps")
        et.arguments = ["-o", "etime=", "-p", String(pid)]
        let etPipe = Pipe()
        et.standardOutput = etPipe
        et.standardError = Pipe()
        do { try et.run(); et.waitUntilExit() } catch { return }
        let etime = String(data: etPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // etime 形如 "1-02:03:04"（天:时:分:秒）或 "02:03"（分:秒）
        let secs = etime.split(separator: "-").flatMap { $0.split(separator: ":").compactMap { Int($0) } }.reduce(0) { $0 * 60 + $1 }
        if secs > 90 {
            print("⚠️  检测到运行中的扩展进程（pid \(pid)，已存活 \(etime)）——")
            print("   它早于本次 start，NESM 将复用它且不会加载新配置。")
            print("   强烈建议先: sudo kill -9 \(pid) && sleep 2  再 start（本命令未自动执行，需要 sudo）")
        }
    }

    /// 轮询 connection status 直到 connected 或超时。
    static func waitConnected(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let managers = (try? await NETransparentProxyManager.loadAllFromPreferences()) ?? []
            if let m = managers.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                    == ProxyCtl.extensionBundleID
            }), m.connection.status == .connected {
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    /// 端到端验证：provider 日志在本进程 start 后是否出现 "starting:"（startProxy 执行）。
    /// 真机教训：status:3 也可能是假成功（老 provider 不重跑 startProxy）。
    static func verifyStartProxyLogged() async -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        proc.arguments = ["show", "--last", "1m", "--info", "--debug",
                          "--predicate", "subsystem == \"local.clarity\" AND category == \"extension\"",
                          "--style", "compact"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run(); proc.waitUntilExit() } catch { return true } // log 失败不阻塞 start
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return out.contains("starting: mode=")
    }

    static func uninstallConfig() async throws {
        let managers = try await NETransparentProxyManager.loadAllFromPreferences()
        for m in managers where (m.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == ProxyCtl.extensionBundleID {
            m.isEnabled = false
            try await m.saveToPreferences()
            try await m.removeFromPreferences()
        }
        print("configuration removed")
    }

    static func status() async throws {
        let managers = try await NETransparentProxyManager.loadAllFromPreferences()
        guard let m = managers.first(where: {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                == ProxyCtl.extensionBundleID
        }) else {
            print("no configuration")
            return
        }
        let proto = m.protocolConfiguration as? NETunnelProviderProtocol
        let conf = proto?.providerConfiguration ?? [:]
        let ipcDesc = conf["ipcPath"] as? String
            ?? ((conf["ipcHost"] as? String).map { "\($0):\(conf["ipcPort"] ?? 0)" })
            ?? "none"
        let treeDesc: String
        if let pids = conf["includePids"] as? [NSNumber], !pids.isEmpty {
            treeDesc = "pid:" + pids.map { $0.stringValue }.joined(separator: ",")
        } else if (conf["treeMode"] as? Bool == true) { treeDesc = "tree" }
        else { treeDesc = "flat" }
        print("""
        enabled: \(m.isEnabled)
        status: \(m.connection.status.rawValue)
        upstream: \(conf["upstreamMode"] ?? "?")://\(conf["upstreamHost"] ?? "?"):\(conf["upstreamPort"] ?? 0)
        ipc: \(ipcDesc)
        match: \(treeDesc)
        include: \(conf["includeProcessPaths"] ?? [])
        exclude: \(conf["excludeProcessPaths"] ?? [])
        """)
    }
}

// MARK: - 入口

@main
struct HostApp {
    static func main() async {
        let allArgs = Array(CommandLine.arguments.dropFirst())
            .filter { $0 != "YES" && $0 != "NO" && !$0.hasPrefix("-NS") && $0 != "-session" }
        // 忽略 Xcode 注入的调试参数(-NSDocumentRevisionsDebugMode YES 等),保留 --include 等 CLI 选项
        var cmd = allArgs.first ?? "help"
        // apply 的参数 = 去掉命令词后的剩余项
        let args = Array(allArgs.dropFirst())
        // Xcode Run 调试时自动激活。系统扩展要求 app 位于 /Applications:
        // 若从 DerivedData 运行,先自我部署到 /Applications 再由那个副本执行
        if ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil
            && cmd == "help"
            && !Bundle.main.bundlePath.hasPrefix("/Applications") {
            let fm = FileManager.default
            let dst = "/Applications/NetProxy.app"
            print("[xcode-debug] deploying to \(dst) ...")
            try? fm.removeItem(atPath: dst)
            do {
                try fm.copyItem(atPath: Bundle.main.bundlePath, toPath: dst)
            } catch {
                print("[xcode-debug] deploy failed: \(error) — 请手动复制到 /Applications")
            }
            print("[xcode-debug] deployed. 请在 /Applications/NetProxy.app 运行 activate,或再次 Cmd+R 前先手动同步。")
            // 直接 exec 部署后的副本执行 activate
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "\(dst)/Contents/MacOS/NetProxy")
            proc.arguments = ["activate"]
            try? proc.run()
            proc.waitUntilExit()
            exit(Int32(proc.terminationStatus))
        }
        if ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil && cmd == "help" {
            cmd = "activate"
            print("[xcode-debug] auto-activating system extension...")
        }
        do {
            switch cmd {
            case "activate":
                try await SysexInstaller.shared.activate()
                print("system extension active")
            case "deactivate":
                try await SysexInstaller.shared.deactivate()
                print("system extension deactivated")
            case "uninstall":
                try await ProxyCtl.uninstallConfig()
            case "discover":
                try await SysexInstaller.shared.discover()
            case "start":
                try await ProxyCtl.apply(args: args, enable: true)
            case "stop":
                try await ProxyCtl.apply(args: args, enable: false)
            case "status":
                try await ProxyCtl.status()
            case "help", "--help", "-h":
                print("""
                NetProxy host controller

                USAGE:
                  netproxy-host activate                       安装/激活系统扩展(首次需在系统设置批准)
                  netproxy-host start [--include SUBSTR]...    启动透明代理(默认 MERGE 到现有规则)
                              [--include-tree SUBSTR]...       进程树路径匹配
                              [--include-pid PID]...           精确子树(可多次,叠加监控)
                              [--remove-pid PID]...            从监控集合移除
                              [--remove-include SUBSTR]...
                              [--exclude SUBSTR]...
                              [--fresh]                        忽略现有规则,从本次命令行重建
                              [--upstream socks5://host:port | gk | direct]
                              [--ipc PATH | --ipc-tcp 127.0.0.1:PORT]
                  netproxy-host stop                           停止透明代理
                  netproxy-host status                         查看状态

                MERGE 语义:
                  start --include-pid A 之后再 start --include-pid B = 同时监控两个 pid。
                  连接参数(--upstream/--ipc)以最近一次给出的为准。--fresh 恢复整体替换。

                EXAMPLES:
                  netproxy-host start --include curl --upstream socks5://127.0.0.1:1080
                  netproxy-host start --include-pid 1234 --upstream gk --ipc-tcp 127.0.0.1:8444
                  netproxy-host start --include-pid 5678        (叠加第二个 pid,连接参数沿用)
                  netproxy-host start --remove-pid 1234         (移除一个,其余保留)
                  netproxy-host start --include /Applications/Foo.app --exclude Foo.helper
                """)
            default:
                fputs("unknown command: \(cmd)\n", stderr)
                exit(2)
            }
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
        exit(0)
    }
}
