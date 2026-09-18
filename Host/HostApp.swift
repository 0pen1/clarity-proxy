import Foundation
import Darwin
import NetworkExtension
import SystemExtensions
import OSLog
import AppKit
import SwiftUI

// MARK: - 系统扩展安装器

private let hostLog = Logger(subsystem: "local.clarity", category: "host")

final class SysexInstaller: NSObject, OSSystemExtensionRequestDelegate, @unchecked Sendable {
    static let shared = SysexInstaller()
    var continuation: CheckedContinuation<Void, Error>?
    var propsContinuation: CheckedContinuation<[String], Never>?

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

    /// discover 的结构化版：返回逐行文本（空 = 系统未扫描到扩展时也返回单行提示）。
    func discover() async -> [String] {
        if #available(macOS 12.0, *) {
            return await withCheckedContinuation { (c: CheckedContinuation<[String], Never>) in
                self.propsContinuation = c
                let req = OSSystemExtensionRequest.propertiesRequest(
                    forExtensionWithIdentifier: ProxyCtl.extensionBundleID,
                    queue: .main)
                req.delegate = self
                OSSystemExtensionManager.shared.submitRequest(req)
            }
        } else {
            return ["propertiesRequest requires macOS 12+"]
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
        propsContinuation?.resume(returning: [])
        propsContinuation = nil
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        hostLog.info("sysex activate finished: \(result.rawValue)")
        continuation?.resume()
        continuation = nil
        propsContinuation?.resume(returning: [])
        propsContinuation = nil
    }

    func request(_ request: OSSystemExtensionRequest,
                 foundProperties properties: [OSSystemExtensionProperties]) {
        var lines: [String]
        if properties.isEmpty {
            lines = ["NO PROPERTIES FOUND (系统没有扫描到该 identifier 的扩展)"]
        } else {
            lines = properties.map { p in
                let enabled = p.responds(to: Selector(("isEnabled"))) ? (p.value(forKey: "isEnabled") as? Bool ?? false) : false
                let awaiting = p.responds(to: Selector(("isAwaitingUserApproval"))) ? (p.value(forKey: "isAwaitingUserApproval") as? Bool ?? false) : false
                return "found: \(p.bundleIdentifier) v\(p.bundleVersion) enabled=\(enabled) awaiting=\(awaiting) url=\(p.url.path)"
            }
        }
        propsContinuation?.resume(returning: lines)
        propsContinuation = nil
    }
}

// MARK: - XPC 热更通道（§9，Proxifier 架构复刻）

/// 宿主侧：直连 root 扩展进程的 ConfigXPC listener（mach 服务名 = 扩展
/// bundle ID，Info.plist NEMachServiceName 声明同名）。公证版上
/// sendProviderMessage 被 NESM IPC entitlement 检查整体拒绝（坑 20）——
/// 本通道不经过 NESM，公证/开发版行为一致。
/// 协议与 Sysex/ConfigXPC.swift 的 ConfigXPCProtocol 逐字同名。
@objc protocol ConfigXPCProtocol {
    @objc func pushConfig(_ conf: [String: Any], withReply reply: @escaping ([String: Any]) -> Void)
}

enum ConfigXPCClient {
    /// 推送全量配置。2s 超时竞速（NSXPCConnection 无内建超时;reply 走
    /// libdispatch 竞速,超时后连接 invalidate——扩展侧 applyConfig 若迟到
    /// 会照常生效,宿主只当失败落兜底,重复推送幂等无害）。
    /// 返回 ack 字典或 nil（连不上/超时/reply 非字典）。
    static func push(_ conf: [String: Any], timeout: TimeInterval = 2) async -> [String: Any]? {
        await withCheckedContinuation { (cont: CheckedContinuation<[String: Any]?, Never>) in
            let done = WDBox()
            let conn = NSXPCConnection(machServiceName: ProxyCtl.extensionBundleID,
                                       options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: ConfigXPCProtocol.self)
            // 竞速票：先到者 resume,另一边被 done.claim() 挡掉
            let wdQueue = DispatchQueue(label: "local.clarity.configxpc.host")
            wdQueue.asyncAfter(deadline: .now() + timeout) {
                if done.claim() { return }
                hostLog.error("ConfigXPC: push timeout \(timeout)s")
                cont.resume(returning: nil)
                conn.invalidate()
            }
            let proxy = conn.remoteObjectProxyWithErrorHandler { err in
                if done.claim() { return }
                hostLog.error("ConfigXPC: push error \(err, privacy: .public)")
                cont.resume(returning: nil)
                conn.invalidate()
            } as? ConfigXPCProtocol
            guard let proxy else {
                if done.claim() { return }
                cont.resume(returning: nil)
                conn.invalidate()
                return
            }
            proxy.pushConfig(conf) { ack in
                if done.claim() { return }
                cont.resume(returning: ack as? [String: Any])
                conn.invalidate()
            }
            conn.resume()
        }
    }
}

// MARK: - 类型化配置（CLI 与 GUI 共用）

/// 一次配置变更的增量描述，与 CLI 参数语义一一对应：
/// 默认 MERGE 到现有规则（pid/路径集合增删）；--fresh 整体重建；
/// 连接参数（upstream/ipc）给一项就整组替换，未给沿用现有值。
struct ProxyPatch {
    var addInclude: [String] = []
    var removeInclude: [String] = []
    var addPids: [Int] = []
    var removePids: [Int] = []
    var addExclude: [String] = []
    var treeMode: Bool? = nil
    var upstreamMode: String? = nil
    var upstreamHost: String? = nil
    var upstreamPort: Int? = nil
    var ipcPath: String? = nil
    var ipcHost: String? = nil
    var ipcPort: Int? = nil
    var fresh = false
}

/// apply 过程中的关键事件（回调顺序即发生顺序）。
/// CLI 据此打印既有文案，GUI 据此驱动 toast/alert——两层共用同一事件流。
enum ApplyEvent {
    case badConfig(String)                 // 配置非法，中止（CLI exit 2）
    case missingPid(Int)                   // pid 不存在，警告
    case hotReloaded(match: String, pids: [Int], include: [String], tree: Bool)
    case hotReloadFallback                 // sendMessage 未获回执，落回重启隧道路径
    case hotReloadXPC                      // ConfigXPC 直连命中（公证版主通道）
    case staleProvider(pid: Int32, etime: String)  // 扩展进程早于本次 start，NESM 将复用
    case waitTimeout                       // 15s 内未 connected（僵尸 provider 特征）
    case stopTimeout                       // stopVPNTunnel 后 10s 未 disconnected
    case startProxyMissing                 // connected 但 startProxy 未执行（僵尸特征）
    case started(pids: [Int], include: [String], tree: Bool, argInclude: [String])
    case stopped
}

/// status 的结构化视图（GUI 状态头与 CLI status 共用）。
struct ProxyStatus: Equatable {
    var enabled: Bool
    var statusRaw: Int
    var upstreamMode: String
    var upstreamHost: String
    var upstreamPort: Int
    var ipcDesc: String
    var matchDesc: String
    var include: [String]
    var exclude: [String]
    var pids: [Int]
    var treeMode: Bool
}

// MARK: - 进程枚举（ProcessPicker 数据源）

struct ProcessInfoRow: Identifiable {
    var id: Int { pid }
    let pid: Int
    let name: String        // 进程名（basename）
    let path: String        // proc_pidpath 全路径（root 进程拿不到为空）
}

enum ProcessList {
    /// sysctl(KERN_PROC_ALL) 两段式调用 + proc_pidpath。跳过自身与 kernel。
    /// 已知边界:非同 uid 进程 proc_pidpath 拿不到路径(显示进程名+pid,路径列空)。
    static func enumerate() -> [ProcessInfoRow] {
        var size: Int = 0
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        // 第一段:只探大小
        if sysctl(&mib, 3, nil, &size, nil, 0) != 0 || size == 0 { return [] }
        var count = size / MemoryLayout<kinfo_proc>.stride
        var infos = Array(repeating: kinfo_proc(), count: count)
        var realSize = size
        // 第二段:真实读取(进程表可能增长,读失败重试一次)
        if sysctl(&mib, 3, &infos, &realSize, nil, 0) != 0 {
            count = realSize / MemoryLayout<kinfo_proc>.stride
            infos = Array(repeating: kinfo_proc(), count: count)
            if sysctl(&mib, 3, &infos, &realSize, nil, 0) != 0 { return [] }
        }
        let selfPid = ProcessInfo.processInfo.processIdentifier
        var rows: [ProcessInfoRow] = []
        rows.reserveCapacity(realSize / MemoryLayout<kinfo_proc>.stride)
        for i in 0..<(realSize / MemoryLayout<kinfo_proc>.stride) {
            let pid = Int(infos[i].kp_proc.p_pid)
            if pid <= 1 || pid == selfPid { continue }
            var name = withUnsafeBytes(of: infos[i].kp_proc.p_comm) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            var path = ""
            var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if proc_pidpath(Int32(pid), &buf, UInt32(MAXPATHLEN)) > 0 {
                let p = String(cString: buf)
                path = p
                name = (p as NSString).lastPathComponent
            }
            rows.append(ProcessInfoRow(pid: pid, name: name, path: path))
        }
        return rows.sorted { $0.pid < $1.pid }
    }
}

// MARK: - NE 看门狗

/// NE 框架缺陷（真机 2026-09-17 四次复现，三个进程 53350/70634/81464 同模式）：
/// GUI 进程首次 loadAllFromPreferences 成功，空闲 ~10 分钟后再次调用永不返回。
/// 证据：挂死调用在 nehelper 连接建立之前就断流（CLI 对照组完整走
/// nehelper → load command → Clearing/Adding）——NE 框架进程内缓存的 XPC
/// 连接被服务端作废后不重连、completion 永不回调。
///
/// v3 双层修复：
/// 1. 治本——AppState 45s keepalive 常驻轮询：连接不闲置，挂死源头消除；
///    面板打开时状态已就绪（keepalive 间隔内最多 45s 旧数据）。
/// 2. 兜底——看门狗全部跑在 libdispatch 串行队列（与 Swift 协作线程池、
///    AppKit、NE XPC 全隔离），asyncAfter 超时必然触发（v2 的 Task.detached
///    + semaphore 赛跑在真机挂死场景静默失效——sema.wait() 同步阻塞协作
///    线程是并发编程禁止的模式，池退化时超时任务永远没机会跑）。
///    连续 2 次 8s 超时 → execv 原地替换进程映像（同 pid，不碰隧道/扩展，
///    不走 NSApp.terminate——它可能被挂死的 XPC 阻塞）。
enum NEWatchdogError: Error { case timeout(String) }

/// 看门狗一次性标志（引用类型，跨并发闭包捕获合法）。
private final class WDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    /// 已被占用返回 true；首次调用占用并返回 false。
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return true }
        claimed = true
        return false
    }
}


extension NETransparentProxyManager {
    /// 看门狗超时回调跑在专属串行队列（dispatchWd），与协作池隔离。
    private static let wdQueue = DispatchQueue(label: "local.clarity.watchdog")

    /// 带 dispatch 看门狗的 loadAllFromPreferences：先发 NE 调用，8s 内
    /// 无回执则抛 NEWatchdogError。返回值经 completion 桥接（协作池恢复执行）。
    static func loadAllWD(_ timeout: TimeInterval = 8) async throws -> [NETransparentProxyManager] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[NETransparentProxyManager], Error>) in
            let done = WDBox()
            // 超时票：libdispatch 定时器，与协作池/AppKit/XPC 全隔离
            wdQueue.asyncAfter(deadline: .now() + timeout) {
                hostLog.info("WD: 看门狗定时器触发（\(timeout)s）")
                if done.claim() { return }
                hostLog.error("WD: loadAllFromPreferences 超时，抛 NEWatchdogError")
                cont.resume(throwing: NEWatchdogError.timeout("loadAllFromPreferences \(timeout)s 未返回"))
            }
            Task.detached {
                hostLog.info("WD: loadAllFromPreferences 开始")
                do {
                    let r = try await NETransparentProxyManager.loadAllFromPreferences()
                    hostLog.info("WD: loadAllFromPreferences 返回 \(r.count) 条")
                    if done.claim() { return }
                    cont.resume(returning: r)
                } catch {
                    hostLog.info("WD: loadAllFromPreferences 抛错 \(String(describing: error))")
                    if done.claim() { return }
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// saveToPreferences 同型看门狗。
    func saveWD(_ timeout: TimeInterval = 8) async throws {
        let m = self
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let done = WDBox()
            Self.wdQueue.asyncAfter(deadline: .now() + timeout) {
                if done.claim() { return }
                cont.resume(throwing: NEWatchdogError.timeout("saveToPreferences \(timeout)s 未返回"))
            }
            Task.detached {
                do {
                    try await m.saveToPreferences()
                    if done.claim() { return }
                    cont.resume()
                } catch {
                    if done.claim() { return }
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// loadFromPreferences 同型看门狗。
    func loadWD(_ timeout: TimeInterval = 8) async throws {
        let m = self
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let done = WDBox()
            Self.wdQueue.asyncAfter(deadline: .now() + timeout) {
                if done.claim() { return }
                cont.resume(throwing: NEWatchdogError.timeout("loadFromPreferences \(timeout)s 未返回"))
            }
            Task.detached {
                do {
                    try await m.loadFromPreferences()
                    if done.claim() { return }
                    cont.resume()
                } catch {
                    if done.claim() { return }
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - 代理配置启停

enum ProxyCtl {
    /// 扩展 bundle ID = host 自身 bundle ID + ".extension"（由构建注入的
    /// PRODUCT_BUNDLE_IDENTIFIER 决定，fork 用户改 project.yml 即整体换标识）。
    static let extensionBundleID = (Bundle.main.bundleIdentifier ?? "local.clarity") + ".extension"

    /// CLI 入口：解析参数 → ProxyPatch → 核心 apply，事件打印为既有文案
    /// （文案已被 gatekeeper 侧文档/排障协议引用，保持逐字兼容）。
    static func apply(args: [String], enable: Bool) async throws {
        let patch = parseArgs(args)
        try await apply(patch: patch, enable: enable) { event in
            switch event {
            case .badConfig(let msg):
                fputs("\(msg)\n", stderr)
                exit(2)
            case .missingPid(let p):
                fputs("警告: pid \(p) 不存在(已退出?)——pid 匹配将不会命中任何流量\n", stderr)
            case .hotReloaded(let match, let pids, let include, let tree):
                print("✓ hot-reloaded (match: \(match)) — provider 未重启，规则即时生效")
                print("  (pids=\(pids) include=\(include) tree=\(tree))")
            case .hotReloadXPC:
                print("✓ hot-reloaded via XPC (match 见扩展日志) — provider 未重启，规则即时生效")
            case .hotReloadFallback:
                print("⚠️  sendMessage 热更未获回执——回退到重启隧道路径")
            case .staleProvider(let pid, let etime):
                print("⚠️  检测到运行中的扩展进程（pid \(pid)，已存活 \(etime)）——")
                print("   它早于本次 start，NESM 将复用它且不会加载新配置。")
                print("   强烈建议先: sudo kill -9 \(pid) && sleep 2  再 start（本命令未自动执行，需要 sudo）")
            case .waitTimeout:
                print("⚠️  proxy started 但 15s 内未 connected——僵尸 provider 特征：")
                print("   1) 重试: $APP stop && sleep 5 && $APP start ...")
                print("   2) 无效则: sudo pkill -9 -f local.netproxy  再重试")
                print("   3) 仍无效: 重启 Mac（NESM/内核状态机卡死唯一解）")
                print("   诊断: /usr/bin/log show --last 2m --info --debug --predicate 'process == \"nesessionmanager\" AND eventMessage CONTAINS \"NetProxy\"'")
            case .stopTimeout:
                print("⚠️  stop 后 10s 未 disconnected——NESM 状态机卡死，本次 start 放弃：")
                print("   1) 重试一次 $APP 命令")
                print("   2) 无效则: sudo pkill -9 -f local.netproxy  再重试")
                print("   3) 仍无效: 重启 Mac（NESM/内核状态机卡死唯一解）")
            case .startProxyMissing:
                print("⚠️  connected 但 provider 未执行 startProxy（配置未加载）——")
                print("   NESM 复用了旧 provider 进程。处置同上：pkill 后重试，或重启 Mac。")
            case .started(let pids, let include, let tree, let argInclude):
                print("proxy started (match: pids=\(pids) include=\(include) tree=\(tree))")
                // 旧行为保留:第二行打印本次 CLI 参数的 include(非合并列表)——逐字对齐
                print("✓ verified: connected + startProxy loaded (config: pid=\(pids) include=\(argInclude))")
            case .stopped:
                print("proxy stopped (config saved, disabled)")
            }
        }
    }

    /// 解析 CLI 参数为 ProxyPatch。与 apply 的参数语义见各 case 注释。
    static func parseArgs(_ args: [String]) -> ProxyPatch {
        var patch = ProxyPatch()
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--include":
                if let v = it.next() { patch.addInclude.append(v) }
            case "--include-tree":
                // 进程树匹配:祖先链(发起进程→pid 1)任一路径命中即拦——
                // claude 调 bash 跑 curl 的子进程流量全覆盖(树动态生长天然支持,
                // 连接发起时实时反查,非预登记)。孤儿进程(链断)放行。
                if let v = it.next() { patch.addInclude.append(v); patch.treeMode = true }
            case "--include-pid":
                // pid 树匹配:祖先链 pid 精确命中——只拦该进程及其枝干,零误伤。
                // 用法:pgrep claude 拿 pid → --include-pid <pid>;其他 claude
                // 实例/手动启动的同名进程不受影响。可重复,merge 进现有集合。
                if let v = it.next(), let p = Int(v), p > 1 { patch.addPids.append(p) }
            case "--remove-pid":
                // 从现有监控集合移除该 pid(被监控进程退出后清规则)。
                if let v = it.next(), let p = Int(v), p > 1 { patch.removePids.append(p) }
            case "--remove-include":
                // 从现有 include 路径集合移除该子串。
                if let v = it.next() { patch.removeInclude.append(v) }
            case "--exclude":
                if let v = it.next() { patch.addExclude.append(v) }
            case "--fresh":
                // 忽略现有规则,从本次命令行重建(旧行为)。
                patch.fresh = true
            case "--upstream":
                if let v = it.next() {
                    // socks5://host:port 或 direct 或 gk
                    if v.hasPrefix("socks5://") {
                        patch.upstreamMode = "socks5"
                        let rest = v.dropFirst("socks5://".count)
                        let parts = rest.split(separator: ":")
                        if parts.count >= 1 { patch.upstreamHost = String(parts[0]) }
                        if parts.count >= 2 { patch.upstreamPort = Int(parts[1]) ?? 1080 }
                    } else if v == "gk" {
                        patch.upstreamMode = "gk"
                    } else if v == "direct" {
                        patch.upstreamMode = "direct"
                    }
                }
            case "--ipc":
                if let v = it.next() { patch.ipcPath = v }
            case "--ipc-tcp":
                if let v = it.next() {
                    let parts = v.split(separator: ":")
                    if parts.count >= 1 { patch.ipcHost = String(parts[0]) }
                    if parts.count >= 2 { patch.ipcPort = Int(parts[1]) }
                }
            default:
                fputs("unknown arg \(a)\n", stderr)
            }
        }
        return patch
    }

    /// 核心 apply：读取现有配置 → merge → 校验 → 保存 → 启停（含防假成功三件套
    /// 与热更快路径）。事件通过 report 回调按发生顺序上报。
    static func apply(patch: ProxyPatch, enable: Bool,
                      report: @escaping (ApplyEvent) -> Void) async throws {
        // 读取现有配置（merge 基线）。
        let managers = try await NETransparentProxyManager.loadAllWD()
        let manager = managers.first { m in
            (m.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                == ProxyCtl.extensionBundleID
        } ?? NETransparentProxyManager()
        let oldProto = manager.protocolConfiguration as? NETunnelProviderProtocol
        let old = oldProto?.providerConfiguration ?? [:]

        // 合并规则集合：fresh 或首次配置时以本次 patch 为基线；否则在现有集合上增删。
        var mergedInclude: [String]
        var mergedExclude: [String]
        var mergedPids: [Int]
        if patch.fresh || old.isEmpty {
            mergedInclude = patch.addInclude
            mergedExclude = patch.addExclude
            mergedPids = patch.addPids
        } else {
            let oldInclude = (old["includeProcessPaths"] as? [String]) ?? []
            let oldExclude = (old["excludeProcessPaths"] as? [String]) ?? []
            let oldPids = ((old["includePids"] as? [NSNumber]) ?? []).map { $0.intValue }
            mergedInclude = Array(Set(oldInclude).union(patch.addInclude))
            mergedExclude = Array(Set(oldExclude).union(patch.addExclude))
            mergedPids = Array(Set(oldPids).union(patch.addPids))
        }
        for p in patch.removePids { mergedPids.removeAll { $0 == p } }
        for s in patch.removeInclude { mergedInclude.removeAll { $0 == s } }

        // 运行连接参数：给了一项就整体替换这一组；一项没给则沿用现有。
        let oldUpstreamMode = (old["upstreamMode"] as? String) ?? "direct"
        let oldUpstreamHost = (old["upstreamHost"] as? String) ?? "127.0.0.1"
        let oldUpstreamPort = (old["upstreamPort"] as? Int) ?? 1080
        let effUpstreamMode = patch.upstreamMode ?? oldUpstreamMode
        let effUpstreamHost = patch.upstreamHost ?? oldUpstreamHost
        let effUpstreamPort = patch.upstreamPort ?? oldUpstreamPort
        let effIpcPath = patch.ipcPath ?? (old["ipcPath"] as? String)
        let effIpcHost = patch.ipcHost ?? (old["ipcHost"] as? String)
        let effIpcPort = patch.ipcPort ?? (old["ipcPort"] as? Int)
        // treeMode：本次给了 --include-tree 置 true；--fresh 时按本次（无 tree 即 false）；
        // 否则沿用现有 true（一旦开过树匹配,merge 场景保持,避免第二次 start 静默关闭）。
        let oldTreeMode = (old["treeMode"] as? Bool) ?? false
        let effTreeMode = patch.treeMode ?? (patch.fresh ? false : oldTreeMode)

        if effUpstreamMode == "gk" && effIpcPath == nil && effIpcHost == nil {
            report(.badConfig("--upstream gk 需要 --ipc <socket-path> 或 --ipc-tcp 127.0.0.1:<port>"))
            return
        }
        for p in mergedPids {
            var kp = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(p)]
            if sysctl(&mib, 4, &kp, &size, nil, 0) != 0 || size == 0 {
                report(.missingPid(p))
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

        try await manager.saveWD()
        try await manager.loadWD()
        if enable {
            // 后面 verifyStartProxyLogged 只认此刻之后的 starting: 行。
            let startWallClock = Date()
            // ---- 防假成功三件套（真机教训：proxy started/status:3 都会骗人）----
            // 1. start 前清场：扩展进程存活且年龄 > 90s（不可能属于本次 start
            //    生命周期）时，NESM 会复用它——新配置不会加载。提示并给出杀进程命令。
            // ---- 热更新快路径：provider 已 connected 时推送全量新配置，
            // 不重启隧道、不碰 NESM 状态机。通道优先级（§9）：
            // ① ConfigXPC 直连（mach 连 root 扩展进程,不过 NESM——公证版
            //    主通道,坑 20 的 sendMessage 拒绝不可达）
            // ② sendProviderMessage（Development 签名构建有效;公证版被拒）
            // ③ 冷启兜底（stop → start）
            if manager.connection.status == .connected {
                // ① XPC 直连：扩展 listener 在 startProxy 里启动,冷启后首次
                //    apply 时已就绪;连不上（扩展刚死/旧版扩展无此通道）→ nil,落 ②。
                if let ack = await ConfigXPCClient.push(conf),
                   ack["ok"] as? Bool == true {
                    report(.hotReloadXPC)
                    return
                }
                if let session = manager.connection as? NETunnelProviderSession {
                    let msg: [String: Any] = ["type": "config", "config": conf]
                    if let data = try? JSONSerialization.data(withJSONObject: msg, options: []) {
                        // completion 版包装为 async（async 重载与 completion 版签名有歧义）。
                        let ackData: Data? = await withCheckedContinuation { cont in
                            do {
                                try session.sendProviderMessage(data) { resp in
                                    cont.resume(returning: resp)
                                }
                            } catch {
                                cont.resume(returning: nil)
                            }
                        }
                        if let ack = ackData,
                           let ackObj = try? JSONSerialization.jsonObject(with: ack, options: []),
                           let ackDict = ackObj as? [String: Any],
                           ackDict["ok"] as? Bool == true {
                            let matchDesc = "\(ackDict["match"] ?? "?")"
                            report(.hotReloaded(match: matchDesc, pids: mergedPids,
                                                include: mergedInclude, tree: effTreeMode))
                            return
                        }
                    }
                }
                // ② 失败（provider 进程死/旧版本不识别消息/公证版 IPC
                // entitlement 被 NESM 拒——devid entitlements 只有 -systemextension
                // 后缀值，NESM 的 sendMessage IPC 检查要裸 app-proxy-provider
                // → 回执永远丢失，真机 2026-09-18 定案）——落回冷启路径。
                // 关键：会话仍 connected 时 NESM 对 startVPNTunnel 是 no-op
                // （"Skip a start command: session in state connected"），新配置
                // 到不了 provider——必须先停隧道再启。真机事故：GUI 加 pid →
                // 热更被拒 → fallback skip → 状态 forever「连接中…」。
                report(.hotReloadFallback)
                if !(await ProxyCtl.stopTunnelAndWait(manager: manager, report: report)) {
                    return // NESM 状态机卡死，本次 start 放弃（僵尸处置路径已上报）
                }
            }

            await ProxyCtl.checkStaleProvider(report: report)

            try manager.connection.startVPNTunnel()

            // 2. 等 connected（startVPNTunnel 只是请求，隧道真正起来需要时间）。
            let connected = await ProxyCtl.waitConnected(timeout: 15)
            guard connected else {
                report(.waitTimeout)
                return
            }
            // 3. 端到端验证：startProxy 是否真的加载了新配置——看 provider 日志里
            //    本次 start 之后是否出现 "starting:" 行（Logger 需 --info --debug 落盘，
            //    这里用 subprocess 直接查 log store）。以本次 start 的时刻为界：
            //    NESM 复用已连接 provider 时 startVPNTunnel 是 no-op（"Skip a start
            //    command: session in state connected"），老进程的旧 starting: 行
            //    仍在 log store 里——只认 start 时间点之后的新行，否则假成功。
            let startingOK = await ProxyCtl.verifyStartProxyLogged(since: startWallClock)
            if !startingOK {
                report(.startProxyMissing)
                return
            }
            report(.started(pids: mergedPids, include: mergedInclude, tree: effTreeMode,
                            argInclude: patch.addInclude))
        } else {
            report(.stopped)
        }
    }

    /// 停隧道并等 disconnected。热更 fallback 路径专用：会话 connected 时
    /// startVPNTunnel 被 NESM skip（no-op），必须先 stop 把状态机带回 idle/disconnected
    /// 再 start，新配置才会作为新的 start command 下发。10s 未断开 → stopTimeout
    /// （NESM 卡死，同僵尸处置路径）并返回 false，调用方应放弃本次 start。
    /// 状态经 loadAllWD 重查（与 waitConnected 同型）：进程内 connection.status
    /// 不一定实时刷新，重载的 manager 携带 NESM 侧权威状态。
    @discardableResult
    static func stopTunnelAndWait(manager: NETransparentProxyManager,
                                  report: @escaping (ApplyEvent) -> Void) async -> Bool {
        manager.connection.stopVPNTunnel()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let m = (try? await NETransparentProxyManager.loadAllWD())?.first(where: {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                    == ProxyCtl.extensionBundleID
            }) {
                let st = m.connection.status
                if st == .disconnected || st == .invalid { return true }
            } else {
                return true // 配置已不存在——视为已停
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        report(.stopTimeout)
        return false
    }

    /// 扩展进程年龄检查：进程启动时间早于 90 秒前 = 它不属于本次 start，
    /// NESM 将复用它（新配置不会加载）。只警告不自动杀（需要 sudo）。
    static func checkStaleProvider(report: @escaping (ApplyEvent) -> Void) async {
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
            report(.staleProvider(pid: pid, etime: etime))
        }
    }

    /// 轮询 connection status 直到 connected 或超时。
    static func waitConnected(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let managers = (try? await NETransparentProxyManager.loadAllWD()) ?? []
            if let m = managers.first(where: { m2 in
                (m2.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                    == ProxyCtl.extensionBundleID
            }), m.connection.status == .connected {
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    /// 端到端验证：provider 日志在 since 之后是否出现 "starting:"（startProxy 执行）。
    /// 真机教训：status:3 也可能是假成功（老 provider 不重跑 startProxy）。
    /// 复用进程时老 starting: 行仍在 log store——必须按时间戳过滤（--start 时刻
    /// 之后的行才算数），否则热更 fallback 后的复用 no-op 也报成功。
    static func verifyStartProxyLogged(since: Date) async -> Bool {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let sinceStr = fmt.string(from: since)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        proc.arguments = ["show", "--start", sinceStr, "--info", "--debug",
                          "--predicate", "category == \"extension\" AND (subsystem == \"local.clarity\" OR subsystem == \"local.netproxy\")",
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
        let managers = try await NETransparentProxyManager.loadAllWD()
        for m in managers where (m.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == ProxyCtl.extensionBundleID {
            m.isEnabled = false
            try await m.saveWD()
            try await m.removeFromPreferences()
        }
        print("configuration removed")
    }

    /// status 的结构化版：未配置返回 nil。
    static func readStatus() async throws -> ProxyStatus? {
        let managers = try await NETransparentProxyManager.loadAllWD()
        guard let m = managers.first(where: { m2 in
            (m2.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                == ProxyCtl.extensionBundleID
        }) else {
            return nil
        }
        let proto = m.protocolConfiguration as? NETunnelProviderProtocol
        let conf = proto?.providerConfiguration ?? [:]
        let ipcDesc = (conf["ipcPath"] as? String)
            ?? ((conf["ipcHost"] as? String).map { "\($0):\(conf["ipcPort"] ?? 0)" })
            ?? "none"
        let pids = ((conf["includePids"] as? [NSNumber]) ?? []).map { $0.intValue }
        let treeMode = (conf["treeMode"] as? Bool) ?? false
        let matchDesc: String
        if !pids.isEmpty {
            matchDesc = "pid:" + pids.map { String($0) }.joined(separator: ",")
        } else if treeMode { matchDesc = "tree" }
        else { matchDesc = "flat" }
        return ProxyStatus(
            enabled: m.isEnabled,
            statusRaw: m.connection.status.rawValue,
            upstreamMode: (conf["upstreamMode"] as? String) ?? "?",
            upstreamHost: (conf["upstreamHost"] as? String) ?? "?",
            upstreamPort: (conf["upstreamPort"] as? Int) ?? 0,
            ipcDesc: ipcDesc,
            matchDesc: matchDesc,
            include: (conf["includeProcessPaths"] as? [String]) ?? [],
            exclude: (conf["excludeProcessPaths"] as? [String]) ?? [],
            pids: pids,
            treeMode: treeMode)
    }

    static func status() async throws {
        guard let s = try await readStatus() else {
            print("no configuration")
            return
        }
        // include/exclude 保持 plist 数组风格多行 "( )" 打印（NSArray description）——与旧版逐字一致
        let rawInclude = NSArray(array: s.include)
        let rawExclude = NSArray(array: s.exclude)
        print("""
        enabled: \(s.enabled)
        status: \(s.statusRaw)
        upstream: \(s.upstreamMode)://\(s.upstreamHost):\(s.upstreamPort)
        ipc: \(s.ipcDesc)
        match: \(s.matchDesc)
        include: \(rawInclude)
        exclude: \(rawExclude)
        """)
    }
}

// MARK: - GUI（菜单栏应用）

/// GUI 主入口。关键约束（真机 5 次复现的教训）：不能在 `MainActor.run {}` 块内调
/// `app.run()`——那会占死主队列的一个 drain 块，之后投递到主队列的 NE completion
/// 与 MainActor 任务（init 期创建的 keepalive/refreshNow Task）永远不被调度，
/// 表现为 GUI 永远「读取中…」。正确形态是同步进入 app.run()：主线程 runloop
/// 正常服务主队列，NE 回调与 MainActor 任务都能执行。
extension HostApp {
    @MainActor
    static func runGUI() {
        let app = NSApplication.shared
        let delegate = MenuBarAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // LSUIElement 语义（plist 也标了，双保险）
        app.run()
        exit(0)
    }
}

/// 单实例守卫 + 菜单栏生命周期。NSApplicationDelegate 的非文档化生命周期方法
/// 在 Swift 里用 NSObject 扩展补充（applicationDidFinishLaunching 在此处可达）。
final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例：已有 NetProxy GUI 实例在跑 → 激活它的菜单栏（无窗口可聚焦，仅提示）并退出
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        let others = running.filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let first = others.first {
            _ = first.activate(options: [])
            NSApplication.shared.terminate(self)
            return
        }
        controller = MenuBarController()
    }
}

/// 菜单栏图标 + Popover 壳：NSStatusItem + NSPopover + NSHostingView(SwiftUI)。
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    let statusItem: NSStatusItem
    let popover: NSPopover
    let appState: AppState

    override init() {
        // 状态映射到 SF Symbols：连接=实心盾、已停=空盾、未激活=斜杠盾
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "shield", accessibilityDescription: "NetProxy")
        popover = NSPopover()
        appState = AppState()
        super.init()
        appState.onIconChange = { [weak self] symbol in
            self?.statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "NetProxy")
        }
        popover.contentSize = NSSize(width: 380, height: 320)
        popover.behavior = .transient                    // 点外部自动关
        popover.contentViewController = NSHostingController(rootView: RootView(state: appState))
        popover.delegate = self
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc func togglePopover(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        // 右键 = 直接退出（无窗口 app 唯一的显式出口；代理继续跑）
        if event?.type == .rightMouseUp {
            NSApp.terminate(nil)
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            appState.refreshNow()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    func popoverWillShow(_ notification: Notification) {
        appState.startPolling()
    }

    func popoverDidClose(_ notification: Notification) {
        appState.stopPolling()
    }
}

// MARK: - GUI 状态与动作（ObservableObject）

/// GUI 状态头信息 + 动作编排。所有 NE 操作 Task 化，busy 门控防并发。
@MainActor
final class AppState: ObservableObject {
    @Published var statusText = "读取中…"
    @Published var statusColor = Color.gray
    @Published var iconSymbol = "shield"
    @Published var enabled = false
    @Published var connected = false
    @Published var busy = false
    @Published var toast: String? = nil
    @Published var lastActionText = "—"
    @Published var statusDetail: ProxyStatus? = nil
    @Published var pickerRequested = false

    var onIconChange: ((String) -> Void)? = nil

    private var pollTask: Task<Void, Never>? = nil
    private var keepaliveTask: Task<Void, Never>? = nil
    private var wdFailCount = 0

    init() {
        refreshNow()
        startKeepalive()   // 45s 常驻：NE XPC 连接不闲置（挂死根因的治本层）
    }

    /// 监控区"添加监控"按钮 → RootView 监听 pickerRequested 弹 sheet。
    func showPicker() {
        pickerRequested = true
    }

    /// 看门狗自愈（v3）：execv 原地替换进程映像——同 pid、不经 NSApp.terminate
    /// （它可能被挂死的 XPC 阻塞）、不碰隧道/扩展（独立进程）。恢复动作跑在
    /// libdispatch 队列，与挂死的协作池完全隔离，必然可达。先落文件证据。
    private func recoverFromNEHang() {
        let marker = "recovery at \(Date())\n"
        try? marker.write(toFile: "/tmp/netproxy-recovery.log", atomically: true, encoding: .utf8)
        hostLog.error("NE watchdog fired — execv restarting GUI (tunnel untouched)")
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.8) {
            // execv：进程映像替换，菜单栏图标由新实例重建，单实例守卫不触发
            // （exec 不产生第二个进程）。GUI 无参重启 = 菜单栏模式。
            let exe = Bundle.main.bundlePath + "/Contents/MacOS/NetProxy"
            let argv: [UnsafeMutablePointer<CChar>?] = [strdup(exe), nil]
            execv(exe, argv)
            // execv 只在失败时返回——进程内已有挂死状态，直接 _exit 让 launchd/
            // 用户感知。正常路径永不走到这里。
            _exit(1)
        }
    }

    func refreshNow() {
        hostLog.info("refreshNow 开始")
        Task { @MainActor in
            do {
                let s = try await ProxyCtl.readStatus()
                hostLog.info("refreshNow 成功 enabled=\(s?.enabled ?? false)")
                self.applyStatus(s)
            } catch is NEWatchdogError {
                self.recoverFromNEHang()
            } catch {
                hostLog.error("refreshNow 异常 \(String(describing: error))")
                self.applyStatus(nil)
            }
        }
    }

    /// 常驻 keepalive（v3 治本）：45s 一次 status 查询。NE 框架的进程内 XPC
    /// 连接在长时间闲置后被服务端作废且不重连（挂死根因）——定期使用让连接
    /// 永不闲置。轮询开销极低（本地 XPC 往返 <10ms）。面板打开时若状态尚新
    /// （<2s）直接复用，否则立即刷新。
    func startKeepalive() {
        guard keepaliveTask == nil else { return }
        hostLog.info("startKeepalive: 创建 Task 前")
        keepaliveTask = Task { @MainActor in
            var round = 0
            while !Task.isCancelled {
                round += 1
                hostLog.info("keepalive 第 \(round) 轮开始")
                do {
                    let s = try await ProxyCtl.readStatus()
                    hostLog.info("keepalive 第 \(round) 轮成功 enabled=\(s?.enabled ?? false)")
                    self.applyStatus(s)
                    wdFailCount = 0
                } catch is NEWatchdogError {
                    wdFailCount += 1
                    hostLog.error("keepalive 第 \(round) 轮超时（第 \(self.wdFailCount) 次）")
                    if wdFailCount >= 2 { self.recoverFromNEHang(); return }
                } catch {
                    hostLog.error("keepalive 第 \(round) 轮异常 \(String(describing: error))")
                    self.applyStatus(nil)
                }
                try? await Task.sleep(nanoseconds: 45_000_000_000)
            }
        }
    }

    func startPolling() {
        stopPolling()
        pollTask = Task { @MainActor in
            var hangCount = 0
            while !Task.isCancelled {
                do {
                    let s = try await ProxyCtl.readStatus()
                    self.applyStatus(s)
                    hangCount = 0
                } catch is NEWatchdogError {
                    // 面板打开期连续两次超时（~16s）才重启（首次可能只是系统慢）
                    hangCount += 1
                    if hangCount >= 2 {
                        self.recoverFromNEHang()
                        return
                    }
                } catch {
                    self.applyStatus(nil)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func applyStatus(_ s: ProxyStatus?) {
        statusDetail = s
        if let s = s {
            enabled = s.enabled
            connected = (s.statusRaw == 3)
            switch (s.enabled, s.statusRaw) {
            case (true, 3): statusText = "已连接"; statusColor = .green
            case (true, _): statusText = "连接中…"; statusColor = .orange
            case (false, _): statusText = "已停止"; statusColor = .blue
            }
            iconSymbol = (s.enabled && s.statusRaw == 3) ? "shield.fill" : "shield"
        } else {
            enabled = false
            connected = false
            statusText = "未激活或未配置"
            statusColor = .red
            iconSymbol = "shield.slash"
        }
        onIconChange?(iconSymbol)
    }

    // MARK: 动作

    func doStart() {
        guard !busy else { return }
        busy = true
        toast = "启动中…"
        Task { @MainActor in
            defer { busy = false; refreshNow() }
            do {
                try await ProxyCtl.apply(patch: ProxyPatch(), enable: true) { event in
                    Task { @MainActor in self.handleEvent(event) }
                }
            } catch {
                toast = "启动失败: \(error.localizedDescription)"
            }
        }
    }

    func doStop() {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false; refreshNow() }
            do {
                try await ProxyCtl.apply(patch: ProxyPatch(), enable: false) { event in
                    Task { @MainActor in self.handleEvent(event) }
                }
            } catch {
                toast = "停止失败: \(error.localizedDescription)"
            }
        }
    }

    /// 加监控 pid：merge 进现有集合。未启动时自动 start（enable:true 覆盖两种状态）。
    func doAddPids(_ pids: [Int]) {
        guard !busy, !pids.isEmpty else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false; refreshNow() }
            do {
                try await ProxyCtl.apply(patch: ProxyPatch(addPids: pids), enable: true) { event in
                    Task { @MainActor in self.handleEvent(event) }
                }
            } catch {
                toast = "添加监控失败: \(error.localizedDescription)"
            }
        }
    }

    /// 删监控 pid（merge 语义的 --remove-pid）。
    func doRemovePid(_ pid: Int) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false; refreshNow() }
            do {
                try await ProxyCtl.apply(patch: ProxyPatch(removePids: [pid]), enable: true) { event in
                    Task { @MainActor in self.handleEvent(event) }
                }
            } catch {
                toast = "移除监控失败: \(error.localizedDescription)"
            }
        }
    }

    /// 改出口：三项给全才替换（与 CLI "给一项就整组替换"语义一致——GUI 要求全项，
    /// 避免半改状态）。未启动时自动 start。校验在 UpstreamSection 内做，这里兜底。
    func doApplyUpstream(mode: String, host: String, port: Int) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false; refreshNow() }
            do {
                var patch = ProxyPatch()
                patch.upstreamMode = mode
                if mode == "socks5" {
                    patch.upstreamHost = host
                    patch.upstreamPort = port
                }
                try await ProxyCtl.apply(patch: patch, enable: true) { event in
                    Task { @MainActor in self.handleEvent(event) }
                }
            } catch {
                toast = "出口变更失败: \(error.localizedDescription)"
            }
        }
    }

    // MARK: ⚙ 菜单动作

    func doActivate() {
        guard !busy else { return }
        busy = true
        toast = "激活中——如弹系统设置请在隐私与安全性里批准"
        Task { @MainActor in
            defer { busy = false; refreshNow() }
            do {
                try await SysexInstaller.shared.activate()
                toast = "系统扩展 active"
            } catch {
                toast = "激活失败: \(error.localizedDescription)"
            }
        }
    }

    func doDeactivate() {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false; refreshNow() }
            do {
                try await SysexInstaller.shared.deactivate()
                toast = "系统扩展已停用"
            } catch {
                toast = "停用失败: \(error.localizedDescription)"
            }
        }
    }

    func doUninstall() {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false; refreshNow() }
            do {
                try await ProxyCtl.uninstallConfig()
                toast = "配置已卸载"
            } catch {
                toast = "卸载失败: \(error.localizedDescription)"
            }
        }
    }

    func handleEvent(_ event: ApplyEvent) {
        switch event {
        case .hotReloaded(let match, _, _, _):
            toast = "✓ 已即时生效（热更）：\(match)"
        case .hotReloadXPC:
            toast = "✓ 已即时生效（XPC 热更）"
        case .hotReloadFallback:
            toast = "⚠️ 热更未获回执——已回退重启隧道"
        case .staleProvider(let pid, let etime):
            toast = "⚠️ 检测到旧扩展进程 pid \(pid)（存活 \(etime)），建议 sudo kill -9 \(pid)"
        case .waitTimeout, .startProxyMissing, .stopTimeout:
            toast = "⚠️ 僵尸 provider 特征——停止后重试，或 sudo pkill -9 -f local.netproxy"
        case .started(let pids, _, _, _):
            toast = "✓ 启动成功（监控 pid: \(pids)）"
        case .stopped:
            toast = "已停止"
        case .missingPid(let p):
            toast = "⚠️ pid \(p) 不存在——规则将不会命中任何流量"
        case .badConfig(let msg):
            toast = "✗ \(msg)"
        }
    }
}

// MARK: - GUI 视图

/// Popover 根视图：状态头 + 主按钮 + 摘要 + 监控列表（Step 3）。
struct RootView: View {
    @ObservedObject var state: AppState
    @State private var showUninstallConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(state.statusColor)
                    .frame(width: 10, height: 10)
                Text(state.statusText).font(.headline)
                Spacer()
                // ⚙ 菜单：激活/停用扩展、卸载配置（确认）、复制诊断命令
                Menu {
                    Button("激活系统扩展…") { state.doActivate() }
                    Button("停用系统扩展") { state.doDeactivate() }
                    Divider()
                    Button("复制诊断命令", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            "/Applications/NetProxy.app/Contents/MacOS/NetProxy status\n/usr/bin/log show --last 10m --info --debug --predicate 'subsystem == \"local.clarity\" OR subsystem == \"local.netproxy\"'",
                            forType: .string)
                    }
                    Divider()
                    Button("卸载配置…", role: .destructive) { showUninstallConfirm = true }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Text("NetProxy v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                    .font(.caption).foregroundColor(.secondary)
            }
            if let d = state.statusDetail {
                VStack(alignment: .leading, spacing: 4) {
                    Text("IPC: \(d.ipcDesc)")
                    Text("匹配: \(d.matchDesc)")
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
            } else {
                Text("扩展未激活——⚙ 菜单 →「激活系统扩展」，批准后回来自动刷新")
                    .font(.caption).foregroundColor(.secondary)
            }
            Divider()
            UpstreamSection(state: state)
            Divider()
            MonitorSection(state: state)
            Divider()
            HStack {
                Button(action: { state.doStart() }) {
                    Label("启动代理", systemImage: "play.fill")
                }
                .disabled(state.enabled && state.connected || state.busy)
                .help("启动透明代理（规则沿用现有配置）")
                Button(action: { state.doStop() }) {
                    Label("停止代理", systemImage: "stop.fill")
                }
                .disabled(!(state.statusDetail?.enabled ?? false) || state.busy)
                .help("停止透明代理（配置保留）")
            }
            // 空规则警示条：enabled 且无任何规则 = 拦所有非系统进程流量，不静默
            if state.enabled, let d = state.statusDetail,
               d.pids.isEmpty, d.include.isEmpty {
                Label("未配置任何监控规则——当前将拦截所有非系统进程流量", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            if state.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(state.toast ?? "处理中…").font(.caption)
                }
            }
            if !state.busy, let t = state.toast {
                Text(t).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .frame(width: 380, height: 560)
        .sheet(isPresented: $state.pickerRequested) {
            ProcessPicker(state: state, onClose: { state.pickerRequested = false })
        }
        .confirmationDialog("卸载代理配置？", isPresented: $showUninstallConfirm, titleVisibility: .visible) {
            Button("卸载配置", role: .destructive) { state.doUninstall() }
        } message: {
            Text("将删除 NetProxy 的隧道配置（系统扩展仍保留）。遇状态机异常时使用。")
        }
    }
}

// MARK: - 出口表单

/// 出口三态：direct / socks5 / gk。socks5 显示 host:port 输入（值有变化才可应用）。
/// gk 需要已配置的 ipc（沿用现有——GUI 不提供 ipc 编辑，避免误配）。
struct UpstreamSection: View {
    @ObservedObject var state: AppState
    @State private var mode = ""
    @State private var host = ""
    @State private var portText = ""

    /// 当前生效值（从 statusDetail 同步——首次加载与外部变更后）
    private func syncFromStatus() {
        guard let d = state.statusDetail, mode.isEmpty else { return }
        mode = d.upstreamMode
        if d.upstreamMode == "socks5" {
            host = d.upstreamHost
            portText = String(d.upstreamPort)
        }
    }

    private var dirty: Bool {
        guard let d = state.statusDetail else { return false }
        if mode != d.upstreamMode { return true }
        if mode == "socks5" {
            return host != d.upstreamHost || Int(portText) != d.upstreamPort
        }
        return false
    }

    private var invalid: String? {
        if mode == "socks5" {
            if host.isEmpty { return "SOCKS5 需要主机地址" }
            if let p = Int(portText), p > 0, p < 65536 { return nil }
            return "端口需为 1-65535"
        }
        if mode == "gk", state.statusDetail?.ipcDesc == "none" {
            return "网关模式需要 IPC——请先用 CLI 配置一次 --ipc-tcp"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("出口").font(.subheadline).fontWeight(.semibold)
                Spacer()
                Picker("", selection: $mode) {
                    Text("直连").tag("direct")
                    Text("SOCKS5").tag("socks5")
                    Text("网关").tag("gk")
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .disabled(state.busy)
            }
            if mode == "socks5" {
                HStack(spacing: 6) {
                    TextField("主机", text: $host)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    TextField("端口", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            HStack {
                if let err = invalid {
                    Text(err).font(.caption2).foregroundColor(.orange)
                }
                Spacer()
                Button("应用") {
                    state.doApplyUpstream(mode: mode, host: host, port: Int(portText) ?? 0)
                }
                .disabled(!dirty || invalid != nil || state.busy)
                .help("变更出口并启动/保持代理运行（未连接时自动 start）")
            }
        }
        .onAppear { syncFromStatus() }
        .onChange(of: state.statusDetail) { _ in syncFromStatus() }
    }
}

// MARK: - 监控区

/// 监控列表：pid 行（进程名 + 删除按钮）+ [+ 添加监控] 按钮。
struct MonitorSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("监控").font(.subheadline).fontWeight(.semibold)
                Spacer()
                Button(action: { state.showPicker() }) {
                    Label("添加监控…", systemImage: "plus")
                }
                .buttonStyle(.link)
                .disabled(state.busy)
                .keyboardShortcut("n", modifiers: .command)
                .help("从运行中的进程选择要监控的 pid（进程树语义，含未来子进程）⌘N")
            }
            let pids = state.statusDetail?.pids ?? []
            if pids.isEmpty {
                Text("未配置监控规则").font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(pids, id: \.self) { pid in
                    HStack {
                        Image(systemName: "scope")
                            .foregroundColor(.accentColor)
                            .font(.caption)
                        Text("pid \(pid)")
                            .font(.system(size: 11, design: .monospaced))
                        Spacer()
                        Button(action: { state.doRemovePid(pid) }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(state.busy)
                        .help("停止监控该 pid（热更秒生效）")
                    }
                }
            }
        }
    }
}

// MARK: - 进程选择器

/// 从运行中的进程选择要监控的 pid：搜索（名称/pid）+ 点行即添加。
/// root 进程 proc_pidpath 拿不到路径——显示进程名+pid，路径列空。
struct ProcessPicker: View {
    @ObservedObject var state: AppState
    var onClose: () -> Void = {}
    @State private var searchText = ""
    @State private var processes: [ProcessInfoRow] = []
    @State private var loaded = false

    var filtered: [ProcessInfoRow] {
        let q = searchText.lowercased()
        guard !q.isEmpty else { return processes }
        return processes.filter {
            $0.name.lowercased().contains(q) || String($0.pid).contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("选择进程").font(.headline)
                Spacer()
                Button("完成") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
            TextField("搜索名称或 pid…", text: $searchText)
                .textFieldStyle(.roundedBorder)
            if loaded {
                List(filtered) { p in
                    Button(action: {
                        state.doAddPids([p.pid])
                        onClose()
                    }) {
                        HStack {
                            Text(p.name).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text(p.path.isEmpty ? "" : p.path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Text(String(p.pid))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("枚举进程…").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }
            Text("监控以进程树生效：连接发起时实时回溯祖先链，子进程动态覆盖。root 进程不显示路径，可直接输 pid 搜索。")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(width: 380, height: 420)
        .task {
            // 枚举是同步 syscall 循环（几百进程 × proc_pidpath），在 MainActor
            // 上跑会冻住整个 UI（含 ProgressView 和点击响应）。甩到后台线程。
            let rows = await Task.detached(priority: .userInitiated) {
                ProcessList.enumerate()
            }.value
            processes = rows
            loaded = true
        }
    }
}

@main
struct HostApp {
    static func main() {
        let allArgs = Array(CommandLine.arguments.dropFirst())
            .filter { $0 != "YES" && $0 != "NO" && !$0.hasPrefix("-NS") && $0 != "-session" }
        // 忽略 Xcode 注入的调试参数(-NSDocumentRevisionsDebugMode YES 等),保留 --include 等 CLI 选项
        // GUI 模式：无参数启动（Finder 双击 / open）→ 菜单栏应用；有参数 → CLI
        if allArgs.isEmpty {
            MainActor.assumeIsolated {
                runGUI()
            }
            return
        }
        var cmd = allArgs.first ?? "help"
        // apply 的参数 = 去掉命令词后的剩余项
        let args = Array(allArgs.dropFirst())
        // Xcode Run 调试时自动部署。系统扩展要求 app 位于 /Applications:
        // 若从 DerivedData 运行,先自我部署到 /Applications,再 open 拉起 GUI 副本
        // (Xcode 调试主形态=GUI;扩展激活走面板 ⚙ 菜单)
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
            // open 拉起部署后的 GUI 副本（无参启动 → 菜单栏模式）
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = [dst]
            try? proc.run()
            exit(0)
        }
        do {
            // 同步 main 桥接 async CLI：Task 跑 async 主体，semaphore 等待。
            // 关键：CLI 无 runloop，NE completion 投递主队列会饿死——主线程
            // 在 semaphore 上阻塞时必须同步排水主队列/主 runloop。
            let done = DispatchSemaphore(value: 0)
            let box = CLIResultBox()
            let cmdCopy = cmd
            let argsCopy = args
            Task.detached {
                do {
                    try await runCLI(cmd: cmdCopy, args: argsCopy)
                    box.code = 0
                } catch {
                    fputs("error: \(error)\n", stderr)
                    box.code = 1
                }
                done.signal()
            }
            while done.wait(timeout: .now() + 0.05) == .timedOut {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            exit(Int32(box.code))
        }
    }

    /// CLI 退出码载体（引用类型，跨并发闭包捕获合法）。
    private final class CLIResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _code = 0
        var code: Int {
            get { lock.lock(); defer { lock.unlock() }; return _code }
            set { lock.lock(); defer { lock.unlock() }; _code = newValue }
        }
    }

    /// CLI 分支的 async 主体（main 同步化后由 Task 承载）。
    static func runCLI(cmd: String, args: [String]) async throws {
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
                for line in try await SysexInstaller.shared.discover() {
                    print(line)
                }
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
    }
}
