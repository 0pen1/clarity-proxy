// MARK: - 共享类型与纯逻辑（Host / Sysex 两 target 共用，只依赖 Foundation）
//
// 抽取准则（testability refactor, 2026-09-21）：
//  - 不 import NetworkExtension / Network——保持可在 macOS test bundle 编译；
//  - 所有函数为纯函数（输入 → 输出，无 IO/全局态）——单测直接喂值。
//
// ProcInfo 原在 Sysex/Provider.swift，FilterRule.shouldIntercept 的判定语义
// 是本项目事故率最高的纯逻辑（tree/pid/truncated 降级/回环防护），
// 全部 case 见 Tests/FilterRuleTests.swift。

import Foundation

// MARK: - 进程信息

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

// MARK: - providerConfiguration 配置模式（单一来源）

/// providerConfiguration 字典 ↔ 类型化配置的唯一转换层。
/// 历史事故皆源于此字典跨 Host/plist/XPC JSON 裸传、两端各自解释：
///  - 3.6.1：includePids 缺键被扩展当「沿用旧值」，清扫后 ack 仍报旧 pid；
///  - treeMode 曾以 Int/Bool 两种形态出现（plist 与 JSON 序列化差异）。
/// 键名/类型/缺省语义以本类型为准；Host 与扩展均经此解析（applyConfig 在
/// Provider 里改为委托本函数）。**语义定案**：
///  - includePids：全量替换，缺键 = 沿用旧值（防御旧版 Host 推半量字典），
///    空数组 = 显式清空——这是 3.6.1 事故的定案语义，测试锁死。
///  - 其余键：有则覆盖，缺键沿用旧值（与 applyConfig 历史行为一致）。
struct ProxyConfig {
    var includePaths: [String] = []
    var excludePaths: [String] = []
    var treeMode: Bool = false
    var includePids: [UInt32] = []
    var upstreamMode: String = "direct"
    var upstreamHost: String = "127.0.0.1"
    var upstreamPort: UInt16 = 1080
    var ipcPath: String?
    var ipcHost: String?
    var ipcPort: UInt16?

    /// 从 providerConfiguration / XPC 推送字典解析。nil 键 = 调用方沿用旧值。
    /// 两态兼容（Bool | Int）处理 treeMode（plist/JSON 序列化差异，真机实证）。
    /// includePids 两态兼容（[Int] | [NSNumber]）同因。
    static func parse(_ conf: [String: Any]) -> ProxyConfig {
        var c = ProxyConfig()
        if let v = conf["includeProcessPaths"] as? [String] { c.includePaths = v }
        if let v = conf["excludeProcessPaths"] as? [String] { c.excludePaths = v }
        if let v = conf["upstreamMode"] as? String { c.upstreamMode = v }
        if let v = conf["upstreamHost"] as? String { c.upstreamHost = v }
        if let p = conf["upstreamPort"] as? Int { c.upstreamPort = UInt16(clamping: max(0, p)) }
        if let s = conf["ipcPath"] as? String, !s.isEmpty { c.ipcPath = s }
        if let h = conf["ipcHost"] as? String, !h.isEmpty { c.ipcHost = h }
        if let p = conf["ipcPort"] as? Int, p > 0 { c.ipcPort = UInt16(clamping: p) }
        if let t = conf["treeMode"] as? Bool { c.treeMode = t }
        else if let t = conf["treeMode"] as? Int { c.treeMode = (t != 0) }
        if let pids = conf["includePids"] as? [Int] {
            c.includePids = pids.map { UInt32(clamping: max(0, $0)) }
        } else if let pids = conf["includePids"] as? [NSNumber] {
            c.includePids = pids.map { $0.uint32Value }
        }
        return c
    }

    /// 输出 providerConfiguration 形态字典（Host 保存/推送、测试 round-trip 共用）。
    /// includePids 无条件写入（空数组也写）——缺键会被解析方当「沿用旧值」，
    /// 清扫清空的场景活 provider 内存里就会留着死 pid（3.6.1 事故定案）。
    func toDictionary() -> [String: Any] {
        var conf: [String: Any] = [
            "includeProcessPaths": includePaths,
            "excludeProcessPaths": excludePaths,
            "upstreamMode": upstreamMode,
            "upstreamHost": upstreamHost,
            "upstreamPort": Int(upstreamPort),
        ]
        conf["treeMode"] = treeMode
        conf["includePids"] = includePids.map { Int($0) }
        if let p = ipcPath { conf["ipcPath"] = p }
        if let h = ipcHost { conf["ipcHost"] = h }
        if let p = ipcPort { conf["ipcPort"] = Int(p) }
        return conf
    }
}

// MARK: - 配置 merge（Host apply 的纯逻辑核）

/// 一次配置变更的增量（与 CLI 参数语义一一对应），从 HostApp.swift 抽出以便单测。
/// 默认 MERGE 到现有规则（pid/路径集合增删）；fresh 整体重建；
/// 连接参数（upstream/ipc）给一项就整组替换，未给沿用现有值。
struct ProxyPatch {
    var addInclude: [String] = []
    var removeInclude: [String] = []
    var addPids: [Int] = []
    var removePids: [Int] = []
    var addExclude: [String] = []
    var removeExclude: [String] = []
    var treeMode: Bool? = nil
    var upstreamMode: String? = nil
    var upstreamHost: String? = nil
    var upstreamPort: Int? = nil
    var ipcPath: String? = nil
    var ipcHost: String? = nil
    var ipcPort: Int? = nil
    var fresh = false
}

/// merge 结果（applyConfig 字典 + treeMode 单独取，与现有 conf 键形态对齐）。
struct MergedConfig {
    var include: [String]
    var exclude: [String]
    var pids: [Int]
    var treeMode: Bool
    var upstreamMode: String
    var upstreamHost: String
    var upstreamPort: Int
    var ipcPath: String?
    var ipcHost: String?
    var ipcPort: Int?

    /// 输出 providerConfiguration 形态（Host saveToPreferences / 热更推送共用）。
    func toDictionary() -> [String: Any] {
        var conf: [String: Any] = [
            "includeProcessPaths": include,
            "excludeProcessPaths": exclude,
            "upstreamMode": upstreamMode,
            "upstreamHost": upstreamHost,
            "upstreamPort": upstreamPort,
        ]
        conf["treeMode"] = treeMode
        // includePids 无条件写入（空数组也写）——语义定案见 ProxyConfig。
        conf["includePids"] = pids
        if let p = ipcPath { conf["ipcPath"] = p }
        if let h = ipcHost { conf["ipcHost"] = h }
        if let p = ipcPort { conf["ipcPort"] = p }
        return conf
    }
}

enum ConfigMerge {
    /// 现有配置（old，providerConfiguration 形态）+ patch → 新配置。
    /// 纯函数：不判 pid 存活（死 pid 清扫由 Host apply 在调用前完成——
    /// isAlive 是 syscall，不进纯逻辑），不产生事件。
    /// 上游连接参数：patch 给一项就整组替换这一组；一项没给沿用现有。
    /// treeMode：patch 显式给了用 patch 的；fresh 且未给 = false；
    /// 否则沿用现有 true（一旦开过树匹配,merge 场景保持,避免静默关闭）。
    static func apply(old: [String: Any], patch: ProxyPatch) -> MergedConfig {
        let oldInclude = (old["includeProcessPaths"] as? [String]) ?? []
        let oldExclude = (old["excludeProcessPaths"] as? [String]) ?? []
        let oldPids = ((old["includePids"] as? [NSNumber]) ?? []).map { $0.intValue }
        let oldUpstreamMode = (old["upstreamMode"] as? String) ?? "direct"
        let oldUpstreamHost = (old["upstreamHost"] as? String) ?? "127.0.0.1"
        let oldUpstreamPort = (old["upstreamPort"] as? Int) ?? 1080

        var include: [String]
        var exclude: [String]
        var pids: [Int]
        if patch.fresh || old.isEmpty {
            include = patch.addInclude
            exclude = patch.addExclude
            pids = patch.addPids
        } else {
            include = Array(Set(oldInclude).union(patch.addInclude))
            exclude = Array(Set(oldExclude).union(patch.addExclude))
            pids = Array(Set(oldPids).union(patch.addPids))
        }
        for p in patch.removePids { pids.removeAll { $0 == p } }
        for s in patch.removeInclude { include.removeAll { $0 == s } }
        for s in patch.removeExclude { exclude.removeAll { $0 == s } }

        let oldTreeMode = (old["treeMode"] as? Bool) ?? false
        let treeMode = patch.treeMode ?? (patch.fresh ? false : oldTreeMode)

        return MergedConfig(
            include: include.sorted(),
            exclude: exclude.sorted(),
            pids: pids.sorted(),
            treeMode: treeMode,
            upstreamMode: patch.upstreamMode ?? oldUpstreamMode,
            upstreamHost: patch.upstreamHost ?? oldUpstreamHost,
            upstreamPort: patch.upstreamPort ?? oldUpstreamPort,
            ipcPath: patch.ipcPath ?? (old["ipcPath"] as? String),
            ipcHost: patch.ipcHost ?? (old["ipcHost"] as? String),
            ipcPort: patch.ipcPort ?? (old["ipcPort"] as? Int))
    }
}
