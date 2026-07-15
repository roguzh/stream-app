import Foundation

enum LANAddress {
    // iOS's Wi-Fi interface is conventionally named "en0". Mirrors the interface
    // preference logic in server.js's getLocalIp() — prefer the real Wi-Fi
    // interface over anything else, since that's what a LAN receiver can reach.
    static func currentIPv4() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var preferredAddress: String?
        var fallbackAddress: String?

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.ifa_name)
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(
                interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                &hostname, socklen_t(hostname.count),
                nil, socklen_t(0), NI_NUMERICHOST
            )
            let ip = String(cString: hostname)

            if name == "en0" {
                preferredAddress = ip
            } else if !name.hasPrefix("lo") && fallbackAddress == nil {
                fallbackAddress = ip
            }
        }

        return preferredAddress ?? fallbackAddress
    }
}
