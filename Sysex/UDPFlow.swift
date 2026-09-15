// 单独文件:不能 import Network —— Network.NWEndpoint(枚举)与
// NetworkExtension.NWEndpoint(类)同名,同名时此文件的 override 参数类型
// 解析歧义。BaseProvider 的 UDP override 只在此文件出现。
import Foundation
import NetworkExtension

class BaseProvider: NETransparentProxyProvider {
    override func handleNewUDPFlow(_ flow: NEAppProxyUDPFlow, initialRemoteEndpoint remoteEndpoint: NWEndpoint) -> Bool {
        // UDP 不在最小实现范围内:交给系统直连
        return false
    }
}
