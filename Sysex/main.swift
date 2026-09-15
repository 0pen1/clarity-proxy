import Foundation
import NetworkExtension
import OSLog

autoreleasepool {
    let log = Logger(subsystem: "local.clarity", category: "extension-main")
    log.info("clarity-proxy system extension starting")
    NEProvider.startSystemExtensionMode()
}
dispatchMain()
