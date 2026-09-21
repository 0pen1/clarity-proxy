import XCTest
// Shared/ProxyCore.swift 直接编进本 test bundle（project.yml 双源），无独立 module
// 可 import——同 module 内类型直接可见。

/// FilterRule.shouldIntercept 全语义锁定。
/// 规则语义与 Sysex/Provider.swift 历史行为逐条对应（含真机事故的定案语义）。
final class FilterRuleTests: XCTestCase {
    private func info(
        pid: UInt32 = 4242,
        path: String? = "/usr/local/bin/curl",
        ancestors: [String] = [],
        ancestorPids: [UInt32] = [],
        truncated: Bool = false
    ) -> ProcInfo {
        ProcInfo(pid: pid, path: path, ancestors: ancestors,
                 ancestorPids: ancestorPids, truncated: truncated)
    }

    // MARK: 基础 include/exclude

    func testEmptyRuleInterceptsEverything() {
        var r = FilterRule()
        XCTAssertTrue(r.shouldIntercept(info()))
        XCTAssertTrue(r.shouldIntercept(info(path: "/Applications/Foo.app/Contents/MacOS/Foo")))
    }

    func testNoPathInfoNeverIntercepted() {
        // audit token 缺失/proc_pidpath 失败：无从归因，放行（防误伤兜底）
        XCTAssertFalse(FilterRule().shouldIntercept(info(path: nil)))
    }

    func testIncludeSubstringMatch() {
        var r = FilterRule()
        r.includePaths = ["curl"]
        XCTAssertTrue(r.shouldIntercept(info(path: "/usr/local/bin/curl")))
        XCTAssertFalse(r.shouldIntercept(info(path: "/usr/bin/wget")))
    }

    func testExcludeWinsOverInclude() {
        var r = FilterRule()
        r.includePaths = ["/Applications/Foo.app"]
        r.excludePaths = ["Foo.helper"]
        XCTAssertTrue(r.shouldIntercept(info(path: "/Applications/Foo.app/Contents/MacOS/Foo")))
        XCTAssertFalse(r.shouldIntercept(info(path: "/Applications/Foo.app/Contents/MacOS/Foo.helper")))
    }

    // MARK: 系统路径白名单（仅 includePaths 为空时生效）

    func testSystemPathsBypassedWhenNoInclude() {
        var r = FilterRule()
        XCTAssertTrue(r.shouldIntercept(info(path: "/usr/local/bin/curl")))  // 非系统路径
        XCTAssertFalse(r.shouldIntercept(info(path: "/usr/libexec/foo")))
        XCTAssertFalse(r.shouldIntercept(info(path: "/usr/sbin/routed")))
        XCTAssertFalse(r.shouldIntercept(info(path: "/sbin/launchd")))
        XCTAssertFalse(r.shouldIntercept(info(path: "/System/Library/foo")))
    }

    func testSystemPathsInterceptedWhenIncludeMatches() {
        // includePaths 非空时 alwaysExclude 不生效——用户显式点名优先
        var r = FilterRule()
        r.includePaths = ["routed"]
        XCTAssertTrue(r.shouldIntercept(info(path: "/usr/sbin/routed")))
    }

    // MARK: 回环防护（gatekeeper/扩展自身/NetProxy 宿主，任何模式无条件放行）

    func testInfraProcessesAlwaysBypassed() {
        var r = FilterRule()
        r.includePaths = ["gatekeeper"]  // 即使显式 include 也必须放行
        XCTAssertFalse(r.shouldIntercept(info(path: "/usr/local/bin/gatekeeper")))
        XCTAssertFalse(r.shouldIntercept(info(path: "/Library/SystemExtensions/local.clarity.foo")))
        XCTAssertFalse(r.shouldIntercept(info(path: "/Applications/NetProxy.app/Contents/MacOS/NetProxy")))
    }

    func testInfraExcludedFromAncestryChainInTreeMode() {
        // 树匹配会把 gatekeeper 也圈进 claude 祖先链（从 claude 的 shell 启动）
        // → gatekeeper 出网回环被自己截获 → 死循环（GUIDE 坑 15 的数据面变体）
        var r = FilterRule()
        r.treeMode = true
        r.includePaths = ["claude"]
        XCTAssertTrue(r.shouldIntercept(info(
            path: "/bin/curl",
            ancestors: ["/bin/curl", "/bin/zsh", "/usr/local/bin/claude"])))
        XCTAssertFalse(r.shouldIntercept(info(
            path: "/usr/local/bin/gatekeeper",
            ancestors: ["/usr/local/bin/gatekeeper", "/bin/zsh", "/usr/local/bin/claude"])))
    }

    // MARK: tree 模式

    func testTreeModeMatchesAncestorChain() {
        var r = FilterRule()
        r.treeMode = true
        r.includePaths = ["claude"]
        // 子进程（curl 由 zsh 由 claude 启动）——链上命中即拦
        XCTAssertTrue(r.shouldIntercept(info(
            path: "/bin/curl",
            ancestors: ["/bin/curl", "/bin/zsh", "/usr/local/bin/claude"])))
        // 发起进程自身命中
        XCTAssertTrue(r.shouldIntercept(info(
            path: "/usr/local/bin/claude",
            ancestors: ["/usr/local/bin/claude"])))
        // 链完整但无命中 → 放行
        XCTAssertFalse(r.shouldIntercept(info(
            path: "/usr/bin/wget",
            ancestors: ["/usr/bin/wget", "/bin/zsh"])))
    }

    func testFlatModeIgnoresAncestry() {
        var r = FilterRule()
        r.includePaths = ["claude"]
        // 非 tree：只看发起进程自身路径——祖先链里有 claude 也不拦
        XCTAssertFalse(r.shouldIntercept(info(
            path: "/bin/curl",
            ancestors: ["/bin/curl", "/bin/zsh", "/usr/local/bin/claude"])))
        XCTAssertTrue(r.shouldIntercept(info(path: "/usr/local/bin/claude")))
    }

    func testTreeModeTruncatedChainDegradesToAllow() {
        // 链不完整（孤儿进程）且未命中 → 放行，不误伤（语义定案）
        var r = FilterRule()
        r.treeMode = true
        r.includePaths = ["claude"]
        XCTAssertFalse(r.shouldIntercept(info(
            path: "/bin/curl",
            ancestors: ["/bin/curl", "/bin/zsh"],
            truncated: true)))
    }

    // MARK: pid 树匹配（非空时优先于 includePaths）

    func testPidMatchHitsAncestorChain() {
        var r = FilterRule()
        r.includePids = [100]
        // 发起进程自身 pid 命中
        XCTAssertTrue(r.shouldIntercept(info(pid: 100, ancestorPids: [100, 1])))
        // 枝干命中：curl(200) ← zsh(150) ← claude(100)
        XCTAssertTrue(r.shouldIntercept(info(pid: 200, ancestorPids: [200, 150, 100, 1])))
    }

    func testPidMatchMissesUnrelatedInstance() {
        var r = FilterRule()
        r.includePids = [100]
        // 另一个 claude 实例（pid 300）——路径同名也不拦（pid 唯一性语义）
        XCTAssertFalse(r.shouldIntercept(info(
            pid: 300, path: "/usr/local/bin/claude",
            ancestorPids: [300, 1])))
    }

    func testPidMatchOverridesIncludePaths() {
        // 两种树匹配互斥：includePids 非空时忽略 includePaths
        var r = FilterRule()
        r.includePaths = ["curl"]
        r.includePids = [100]
        // pid 未命中（即使路径含 curl）→ 不拦
        XCTAssertFalse(r.shouldIntercept(info(pid: 200, path: "/usr/bin/curl", ancestorPids: [200, 1])))
        // pid 命中（即使路径不含 curl）→ 拦
        XCTAssertTrue(r.shouldIntercept(info(pid: 100, path: "/usr/bin/wget", ancestorPids: [100, 1])))
    }

    func testPidMatchBeatsTruncation() {
        // pid 匹配不看路径/链完整性：链断了但 ancestorPids 里有目标 pid 仍拦
        var r = FilterRule()
        r.includePids = [100]
        XCTAssertTrue(r.shouldIntercept(info(
            pid: 200, path: "/bin/curl",
            ancestors: ["/bin/curl"], ancestorPids: [200, 100], truncated: true)))
    }
}

/// ProxyConfig：providerConfiguration 字典解析（两态兼容 + 3.6.1 定案语义）。
final class ProxyConfigTests: XCTestCase {
    func testFullRoundTrip() {
        var c = ProxyConfig()
        c.includePaths = ["claude", "curl"]
        c.excludePaths = ["Foo.helper"]
        c.treeMode = true
        c.includePids = [123, 456]
        c.upstreamMode = "socks5"
        c.upstreamHost = "127.0.0.1"
        c.upstreamPort = 7897
        c.ipcHost = "127.0.0.1"
        c.ipcPort = 8444
        let rt = ProxyConfig.parse(c.toDictionary())
        XCTAssertEqual(rt.includePaths, c.includePaths)
        XCTAssertEqual(rt.excludePaths, c.excludePaths)
        XCTAssertEqual(rt.treeMode, c.treeMode)
        XCTAssertEqual(rt.includePids, c.includePids)
        XCTAssertEqual(rt.upstreamMode, c.upstreamMode)
        XCTAssertEqual(rt.upstreamPort, c.upstreamPort)
        XCTAssertEqual(rt.ipcHost, c.ipcHost)
        XCTAssertEqual(rt.ipcPort, c.ipcPort)
        XCTAssertNil(rt.ipcPath)
    }

    func testEmptyDictionaryYieldsDefaults() {
        let c = ProxyConfig.parse([:])
        XCTAssertEqual(c.upstreamMode, "direct")
        XCTAssertEqual(c.upstreamHost, "127.0.0.1")
        XCTAssertEqual(c.upstreamPort, 1080)
        XCTAssertFalse(c.treeMode)
        XCTAssertTrue(c.includePids.isEmpty)
    }

    /// 3.6.1 定案语义：includePids 空数组 = 显式清空（不是缺键）。
    /// 真机事故：Host 清扫死 pid 后推 includePids=[]，扩展侧若当「沿用旧值」
    /// 则活 provider 继续按死 pid 匹配。
    func testEmptyPidsArrayIsExplicitClear() {
        var old = ProxyConfig()
        old.includePids = [99]
        var conf = old.toDictionary()
        conf["includePids"] = [Int]()   // Host 清扫后推送的形态
        XCTAssertEqual(ProxyConfig.parse(conf).includePids, [])
    }

    func testMissingPidsKeyPreservesSemantic() {
        // 缺键 = 沿用旧值（解析层面表现为取默认空——「沿用」由 Provider.applyConfig
        // 的键存在性判断实现，这里锁的是 parse 对缺键不误写）
        let c = ProxyConfig.parse(["upstreamMode": "gk"])
        XCTAssertTrue(c.includePids.isEmpty)
        XCTAssertEqual(c.upstreamMode, "gk")
    }

    func testTreeModeIntAndBoolForms() {
        // plist 序列化出 Bool，某些路径出 Int——两态都必须工作（真机实证）
        XCTAssertEqual(ProxyConfig.parse(["treeMode": true]).treeMode, true)
        XCTAssertEqual(ProxyConfig.parse(["treeMode": 1]).treeMode, true)
        XCTAssertEqual(ProxyConfig.parse(["treeMode": 0]).treeMode, false)
    }

    func testIncludePidsNSNumberForm() {
        // XPC/JSONSerialization 路径产出 [NSNumber]（Bool 桥接陷阱之外的标准形态）
        let pids: [NSNumber] = [NSNumber(value: 7), NSNumber(value: 9)]
        let c = ProxyConfig.parse(["includePids": pids])
        XCTAssertEqual(c.includePids, [7, 9])
    }

    func testEmptyIpcStringsAreNil() {
        // 空串不覆盖（applyConfig 历史语义：!s.isEmpty 才取）
        let c = ProxyConfig.parse(["ipcPath": "", "ipcHost": "", "ipcPort": 0])
        XCTAssertNil(c.ipcPath)
        XCTAssertNil(c.ipcHost)
        XCTAssertNil(c.ipcPort)
    }
}

/// ConfigMerge.apply：Host apply() 的 merge 纯逻辑核（含本次死 pid 清扫语义链）。
final class ConfigMergeTests: XCTestCase {
    private func oldConf(include: [String] = [], exclude: [String] = [],
                         pids: [Int] = [], tree: Bool = false,
                         mode: String = "direct") -> [String: Any] {
        var c = ProxyConfig()
        c.includePaths = include
        c.excludePaths = exclude
        c.treeMode = tree
        c.includePids = pids.map { UInt32($0) }
        c.upstreamMode = mode
        return c.toDictionary()
    }

    func testMergeAddsOnTopOfExisting() {
        let m = ConfigMerge.apply(
            old: oldConf(include: ["curl"], pids: [1, 2]),
            patch: ProxyPatch(addInclude: ["wget"], addPids: [3]))
        XCTAssertEqual(Set(m.include), ["curl", "wget"])
        XCTAssertEqual(Set(m.pids), [1, 2, 3])
    }

    func testRemovePidsAndIncludes() {
        let m = ConfigMerge.apply(
            old: oldConf(include: ["curl", "wget"], pids: [1, 2, 3]),
            patch: ProxyPatch(removeInclude: ["wget"], removePids: [2]))
        XCTAssertEqual(m.include, ["curl"])
        XCTAssertEqual(m.pids, [1, 3])
    }

    func testRemoveExclude() {
        // 3.7 前的洞：mergedExclude 只增不减。锁定 removeExclude 语义。
        let m = ConfigMerge.apply(
            old: oldConf(exclude: ["Foo.helper", "bar"]),
            patch: ProxyPatch(removeExclude: ["Foo.helper"]))
        XCTAssertEqual(m.exclude, ["bar"])
    }

    func testFreshRebuildsFromPatch() {
        let m = ConfigMerge.apply(
            old: oldConf(include: ["curl"], pids: [1]),
            patch: ProxyPatch(addInclude: ["wget"], addPids: [2], fresh: true))
        XCTAssertEqual(m.include, ["wget"])
        XCTAssertEqual(m.pids, [2])
    }

    func testEmptyOldConfigUsesPatchAsBaseline() {
        // 首次配置（old.isEmpty）= fresh 语义，即使 patch.fresh == false
        let m = ConfigMerge.apply(
            old: [:],
            patch: ProxyPatch(addInclude: ["curl"], addPids: [1]))
        XCTAssertEqual(m.include, ["curl"])
        XCTAssertEqual(m.pids, [1])
    }

    func testUpstreamReplaceWholeGroupWhenGiven() {
        let m = ConfigMerge.apply(
            old: oldConf(mode: "socks5"),
            patch: ProxyPatch(upstreamMode: "direct"))
        XCTAssertEqual(m.upstreamMode, "direct")
        // 整组替换语义：mode 给了 → host/port 沿用 old 的值（未给则沿用）
        XCTAssertEqual(m.upstreamHost, "127.0.0.1")
    }

    func testUpstreamKeptWhenPatchEmpty() {
        var oc = oldConf()
        oc["upstreamMode"] = "socks5"
        oc["upstreamHost"] = "10.0.0.1"
        oc["upstreamPort"] = 1080
        let m = ConfigMerge.apply(old: oc, patch: ProxyPatch())
        XCTAssertEqual(m.upstreamMode, "socks5")
        XCTAssertEqual(m.upstreamHost, "10.0.0.1")
        XCTAssertEqual(m.upstreamPort, 1080)
    }

    func testTreeModeStickyInMerge() {
        // 一旦开过树匹配，merge 场景保持（避免第二次 start 静默关闭）
        let m = ConfigMerge.apply(
            old: oldConf(tree: true),
            patch: ProxyPatch(addPids: [1]))
        XCTAssertTrue(m.treeMode)
    }

    func testFreshWithoutTreeFlagResetsTreeMode() {
        let m = ConfigMerge.apply(
            old: oldConf(tree: true),
            patch: ProxyPatch(addInclude: ["curl"], fresh: true))
        XCTAssertFalse(m.treeMode)
    }

    func testExplicitTreeFlagWins() {
        let m = ConfigMerge.apply(
            old: oldConf(),
            patch: ProxyPatch(addInclude: ["claude"], treeMode: true))
        XCTAssertTrue(m.treeMode)
    }

    /// 3.6.1 事故链终环：清扫后的空 pid 集必须落进字典（空数组也写）。
    func testSweptEmptyPidsStillWrittenToDictionary() {
        let m = ConfigMerge.apply(
            old: oldConf(pids: [42]),
            patch: ProxyPatch(removePids: [42]))
        XCTAssertTrue(m.pids.isEmpty)
        let dict = m.toDictionary()
        // 键必须存在且为空数组（缺键会被扩展 applyConfig 当「沿用旧值」）
        let pids = dict["includePids"] as? [Int]
        XCTAssertNotNil(pids)
        XCTAssertEqual(pids, [])
    }

    func testIpcFallbackToOld() {
        var oc = oldConf()
        oc["ipcHost"] = "127.0.0.1"
        oc["ipcPort"] = 8444
        let m = ConfigMerge.apply(old: oc, patch: ProxyPatch())
        XCTAssertEqual(m.ipcHost, "127.0.0.1")
        XCTAssertEqual(m.ipcPort, 8444)
        XCTAssertNil(m.ipcPath)
    }
}
