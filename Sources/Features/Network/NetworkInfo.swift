import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

/// A point-in-time snapshot of the Mac's active network connection: the primary
/// interface's addressing, the router and DNS resolvers in use, and — when the
/// connection is Wi-Fi — the radio details (band, channel, signal, protocol).
///
/// Everything here is read locally with no elevated privileges: `SCDynamicStore`
/// for the primary service, `getifaddrs` for addresses, and CoreWLAN for the
/// radio. The public IP is deliberately NOT part of this — it needs an outbound
/// request to a third party, so it lives behind `fetchPublicIPv4()` and an
/// explicit user action.
public struct NetworkInfo: Sendable, Hashable {
    public struct WiFi: Sendable, Hashable {
        public var ssid: String?
        public var bssid: String?
        public var channelNumber: Int
        public var band: String        // "2.4 GHz" / "5 GHz" / "6 GHz" / ""
        public var width: String       // "20 MHz" / "40 MHz" / "80 MHz" / "160 MHz" / ""
        public var rssi: Int            // dBm, 0 = unknown
        public var noise: Int           // dBm, 0 = unknown
        public var txRateMbps: Double
        public var phyMode: String      // "Wi-Fi 6 (802.11ax)" etc.
        public var security: String
        public var countryCode: String?

        /// Signal-to-noise ratio in dB, or 0 when either input is unknown.
        public var snr: Int { (rssi != 0 && noise != 0) ? rssi - noise : 0 }

        /// A 0–100 signal-quality estimate mapped from RSSI (−100 dBm → 0,
        /// −50 dBm or better → 100).
        public var signalQuality: Int {
            guard rssi != 0 else { return 0 }
            let clamped = min(max(Double(rssi), -100), -50)
            return Int(((clamped + 100) / 50) * 100)
        }
    }

    public var primaryInterface: String?
    public var connectionName: String
    public var isOnline: Bool
    public var localIPv4: String?
    public var subnetMask: String?
    public var localIPv6: String?
    public var router: String?
    public var dnsServers: [String]
    public var macAddress: String?
    public var wifi: WiFi?
    /// True when a Wi-Fi radio exists but macOS won't hand back the SSID/BSSID
    /// because the app hasn't been granted Location access (the OS gate since
    /// macOS 14). Channel/signal/rate still work without it.
    public var wifiNeedsLocationPermission: Bool

    public init(
        primaryInterface: String? = nil,
        connectionName: String = "Not connected",
        isOnline: Bool = false,
        localIPv4: String? = nil,
        subnetMask: String? = nil,
        localIPv6: String? = nil,
        router: String? = nil,
        dnsServers: [String] = [],
        macAddress: String? = nil,
        wifi: WiFi? = nil,
        wifiNeedsLocationPermission: Bool = false
    ) {
        self.primaryInterface = primaryInterface
        self.connectionName = connectionName
        self.isOnline = isOnline
        self.localIPv4 = localIPv4
        self.subnetMask = subnetMask
        self.localIPv6 = localIPv6
        self.router = router
        self.dnsServers = dnsServers
        self.macAddress = macAddress
        self.wifi = wifi
        self.wifiNeedsLocationPermission = wifiNeedsLocationPermission
    }

    // MARK: - Collection

    public static func collect() -> NetworkInfo {
        let store = SCDynamicStoreCreate(nil, "com.profiveck.myKikau.network" as CFString, nil, nil)
        let global = store.flatMap {
            SCDynamicStoreCopyValue($0, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        }
        let primaryService = global?["PrimaryService"] as? String
        var primaryInterface = global?["PrimaryInterface"] as? String
        let router = global?["Router"] as? String

        // Fall back to the first interface that actually has an IPv4 address.
        if primaryInterface == nil {
            primaryInterface = firstActiveIPv4Interface()
        }

        var ipv4: String?
        var mask: String?
        var ipv6: String?
        var mac: String?
        if let iface = primaryInterface {
            let addrs = addresses(for: iface)
            ipv4 = addrs.ipv4
            mask = addrs.mask
            ipv6 = addrs.ipv6
            mac = addrs.mac
        }

        let dns = resolveDNSServers(store: store, primaryService: primaryService)

        // Wi-Fi radio (if any).
        var wifi: NetworkInfo.WiFi?
        var needsLocation = false
        var isWiFiConnection = false
        if let cwInterface = CWWiFiClient.shared().interface(), cwInterface.powerOn() {
            let name = cwInterface.interfaceName
            isWiFiConnection = (name == primaryInterface) || (cwInterface.ssid() != nil)
            if isWiFiConnection {
                let ssid = cwInterface.ssid()
                let bssid = cwInterface.bssid()
                needsLocation = (ssid == nil && bssid == nil)
                let channel = cwInterface.wlanChannel()
                wifi = WiFi(
                    ssid: ssid,
                    bssid: bssid,
                    channelNumber: channel?.channelNumber ?? 0,
                    band: bandLabel(channel?.channelBand),
                    width: widthLabel(channel?.channelWidth),
                    rssi: cwInterface.rssiValue(),
                    noise: cwInterface.noiseMeasurement(),
                    txRateMbps: cwInterface.transmitRate(),
                    phyMode: phyModeLabel(cwInterface.activePHYMode()),
                    security: securityLabel(cwInterface.security()),
                    countryCode: cwInterface.countryCode()
                )
            }
        }

        let connectionName: String
        if isWiFiConnection {
            connectionName = "Wi-Fi"
        } else if let iface = primaryInterface {
            connectionName = iface.hasPrefix("en") ? "Ethernet" : iface
        } else {
            connectionName = "Not connected"
        }

        return NetworkInfo(
            primaryInterface: primaryInterface,
            connectionName: connectionName,
            isOnline: ipv4 != nil && router != nil,
            localIPv4: ipv4,
            subnetMask: mask,
            localIPv6: ipv6,
            router: router,
            dnsServers: dns,
            macAddress: mac,
            wifi: wifi,
            wifiNeedsLocationPermission: needsLocation
        )
    }

    /// A one-line label like "Wi-Fi · Home" for compact surfaces (the menu bar).
    public var shortLabel: String {
        if let ssid = wifi?.ssid, !ssid.isEmpty {
            return "\(connectionName) · \(ssid)"
        }
        return connectionName
    }

    /// Plain-text dump of every field, for "Copy All Details".
    public func plainTextSummary() -> String {
        var lines = ["Connection: \(connectionName)"]
        if let i = primaryInterface { lines.append("Interface: \(i)") }
        if let ip = localIPv4 { lines.append("Local IP: \(ip)") }
        if let m = subnetMask { lines.append("Subnet mask: \(m)") }
        if let ip6 = localIPv6 { lines.append("IPv6: \(ip6)") }
        if let r = router { lines.append("Router: \(r)") }
        if !dnsServers.isEmpty { lines.append("DNS: \(dnsServers.joined(separator: ", "))") }
        if let mac = macAddress { lines.append("MAC: \(mac)") }
        if let w = wifi {
            if let s = w.ssid { lines.append("Wi-Fi network: \(s)") }
            if let b = w.bssid { lines.append("BSSID: \(b)") }
            lines.append("Band / channel: \(w.band) · ch \(w.channelNumber) · \(w.width)")
            if w.rssi != 0 { lines.append("Signal: \(w.rssi) dBm (noise \(w.noise) dBm, SNR \(w.snr) dB)") }
            if w.txRateMbps > 0 { lines.append("Tx rate: \(Int(w.txRateMbps)) Mbps") }
            lines.append("Protocol: \(w.phyMode)")
            lines.append("Security: \(w.security)")
            if let c = w.countryCode { lines.append("Country: \(c)") }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Public IP (explicit, outbound)

    public enum PublicIPError: Error, LocalizedError {
        case unavailable
        public var errorDescription: String? { "Couldn't reach the public-IP service." }
    }

    /// Fetches the Mac's public IPv4 from `api.ipify.org`. This is an outbound
    /// request to a third party — only call it on an explicit user action, and
    /// tell the user which service is being contacted.
    public static func fetchPublicIPv4() async throws -> String {
        guard let url = URL(string: "https://api.ipify.org") else { throw PublicIPError.unavailable }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= 45 else {
            throw PublicIPError.unavailable
        }
        return text
    }

    // MARK: - getifaddrs

    private static func firstActiveIPv4Interface() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            if name == "lo0" || NetworkMonitor.isNoiseInterface(name) { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_RUNNING == IFF_RUNNING else { continue }
            return name
        }
        return nil
    }

    private static func addresses(for interface: String) -> (ipv4: String?, mask: String?, ipv6: String?, mac: String?) {
        var ipv4: String?
        var mask: String?
        var ipv6: String?
        var mac: String?

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return (nil, nil, nil, nil) }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            guard name == interface, let addr = entry.pointee.ifa_addr else { continue }
            let family = addr.pointee.sa_family

            if family == UInt8(AF_INET), ipv4 == nil {
                ipv4 = numericHost(addr, family: AF_INET)
                if let netmask = entry.pointee.ifa_netmask {
                    mask = numericHost(netmask, family: AF_INET)
                }
            } else if family == UInt8(AF_INET6), ipv6 == nil {
                if let host = numericHost(addr, family: AF_INET6), !host.hasPrefix("fe80") {
                    ipv6 = host.components(separatedBy: "%").first
                }
            } else if family == UInt8(AF_LINK), mac == nil {
                mac = linkAddressMAC(addr)
            }
        }
        return (ipv4, mask, ipv6, mac)
    }

    private static func numericHost(_ sockaddr: UnsafeMutablePointer<sockaddr>, family: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
        guard getnameinfo(sockaddr, len, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        let host = String(cString: buffer)
        return host.isEmpty ? nil : host
    }

    private static func linkAddressMAC(_ sockaddr: UnsafeMutablePointer<sockaddr>) -> String? {
        sockaddr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dlPtr -> String? in
            var dl = dlPtr.pointee
            let nlen = Int(dl.sdl_nlen)
            let alen = Int(dl.sdl_alen)
            guard alen == 6 else { return nil }
            let bytes: [UInt8] = withUnsafeBytes(of: &dl.sdl_data) { raw in
                (0..<6).map { raw[nlen + $0] }
            }
            guard bytes.contains(where: { $0 != 0 }) else { return nil }
            return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        }
    }

    // MARK: - DNS

    private static func resolveDNSServers(store: SCDynamicStore?, primaryService: String?) -> [String] {
        if let store, let primaryService,
           let dns = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(primaryService)/DNS" as CFString) as? [String: Any],
           let servers = dns["ServerAddresses"] as? [String], !servers.isEmpty {
            return servers
        }
        if let store,
           let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
           let servers = dns["ServerAddresses"] as? [String], !servers.isEmpty {
            return servers
        }
        // Last resort: /etc/resolv.conf (usually just points at 127.0.0.1 for
        // mDNSResponder, but better than showing nothing).
        guard let text = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2, parts[0] == "nameserver" else { return nil }
            return String(parts[1])
        }
    }

    // MARK: - CoreWLAN label mapping

    private static func bandLabel(_ band: CWChannelBand?) -> String {
        switch band {
        case .band2GHz: return "2.4 GHz"
        case .band5GHz: return "5 GHz"
        default:
            if let band, band.rawValue == 3 { return "6 GHz" }  // .band6GHz (macOS 12+)
            return ""
        }
    }

    private static func widthLabel(_ width: CWChannelWidth?) -> String {
        switch width {
        case .width20MHz: return "20 MHz"
        case .width40MHz: return "40 MHz"
        case .width80MHz: return "80 MHz"
        case .width160MHz: return "160 MHz"
        default: return ""
        }
    }

    private static func phyModeLabel(_ mode: CWPHYMode) -> String {
        switch mode {
        case .mode11a: return "Wi-Fi 1 (802.11a)"
        case .mode11b: return "Wi-Fi 1 (802.11b)"
        case .mode11g: return "Wi-Fi 3 (802.11g)"
        case .mode11n: return "Wi-Fi 4 (802.11n)"
        case .mode11ac: return "Wi-Fi 5 (802.11ac)"
        case .mode11ax: return "Wi-Fi 6 (802.11ax)"
        default:
            if mode.rawValue == 7 { return "Wi-Fi 7 (802.11be)" }
            return "Unknown"
        }
    }

    private static func securityLabel(_ security: CWSecurity) -> String {
        switch security {
        case .none: return "Open (no encryption)"
        case .WEP, .dynamicWEP: return "WEP"
        case .wpaPersonal, .wpaPersonalMixed: return "WPA Personal"
        case .wpa2Personal: return "WPA2 Personal"
        case .wpa3Personal: return "WPA3 Personal"
        case .wpa3Transition: return "WPA2/WPA3 Personal"
        case .personal: return "Personal"
        case .wpaEnterprise, .wpaEnterpriseMixed: return "WPA Enterprise"
        case .wpa2Enterprise: return "WPA2 Enterprise"
        case .wpa3Enterprise: return "WPA3 Enterprise"
        case .enterprise: return "Enterprise"
        case .OWE, .oweTransition: return "Enhanced Open (OWE)"
        default: return "Secured"
        }
    }
}
