import AppKit
import CoreLocation
import SwiftUI
import Core
import Features

/// View of the Mac's current network connection: addressing, router, DNS, and
/// Wi-Fi radio details — plus one-tap tools (flush DNS, renew the DHCP lease,
/// look up the public IP). Reads are all local and unprivileged; the tools that
/// need root run via `PrivilegedShell` (one macOS password prompt), and the
/// public-IP lookup is the only outbound call. Both are always behind an
/// explicit tap.
struct NetworkView: View {
    @StateObject private var model = NetworkInfoModel()
    @State private var copiedField: String?
    /// id of the tool currently running under an admin prompt, if any.
    @State private var runningToolID: String?
    /// Result line to show under the tool that just ran: (toolID, text, success).
    @State private var toolMessage: (id: String, text: String, ok: Bool)?

    private let tint = ContentView.SidebarItem.network.tint

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: ContentView.SidebarItem.network.icon)
                    .foregroundStyle(tint)
                Text("Network").font(.title2).bold()
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.info.plainTextSummary(), forType: .string)
                    flash("all")
                } label: {
                    Label(copiedField == "all" ? "Copied" : "Copy All", systemImage: "doc.on.doc")
                }
                Button {
                    model.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
            }
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    connectionCard
                    if model.info.wifi != nil {
                        wifiCard
                    }
                    publicIPCard
                    toolsCard
                }
                .padding()
            }
        }
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    // MARK: - Connection

    private var connectionCard: some View {
        Card(title: "Connection", systemImage: connectionIcon, tint: tint) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.info.isOnline ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(model.info.connectionName)
                    .font(.caption.weight(.medium))
                Text(model.info.isOnline ? "· Online" : "· Not connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let iface = model.info.primaryInterface {
                    Text("· \(iface)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 4)

            InfoRow("Local IP address", model.info.localIPv4, copiedField: $copiedField, onCopy: flash)
            InfoRow("Subnet mask", model.info.subnetMask, copiedField: $copiedField, onCopy: flash)
            InfoRow("Router", model.info.router, copiedField: $copiedField, onCopy: flash)
            InfoRow("DNS servers", model.info.dnsServers.isEmpty ? nil : model.info.dnsServers.joined(separator: ", "),
                    copiedField: $copiedField, onCopy: flash)
            InfoRow("IPv6", model.info.localIPv6, copiedField: $copiedField, onCopy: flash)
            InfoRow("MAC address", model.info.macAddress, copiedField: $copiedField, onCopy: flash)
        }
    }

    private var connectionIcon: String {
        switch model.info.connectionName {
        case "Wi-Fi": return "wifi"
        case "Ethernet": return "cable.connector"
        default: return "network.slash"
        }
    }

    // MARK: - Wi-Fi

    @ViewBuilder
    private var wifiCard: some View {
        if let wifi = model.info.wifi {
            Card(title: "Wi-Fi", systemImage: "wifi", tint: tint) {
                if model.info.wifiNeedsLocationPermission {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "location.slash")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("macOS hides the network name until myKikau has Location access. Channel, signal and speed still work without it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Grant Location Access") { model.requestLocationAccess() }
                                Button("Open Settings") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.bottom, 4)
                }

                InfoRow("Network (SSID)", wifi.ssid, copiedField: $copiedField, onCopy: flash)
                InfoRow("BSSID", wifi.bssid, copiedField: $copiedField, onCopy: flash)
                InfoRow("Band", wifi.band.isEmpty ? nil : wifi.band, copiedField: $copiedField, onCopy: flash)
                InfoRow("Channel", wifi.channelNumber > 0
                        ? "\(wifi.channelNumber)\(wifi.width.isEmpty ? "" : " · \(wifi.width)")" : nil,
                        copiedField: $copiedField, onCopy: flash)
                InfoRow("Protocol", wifi.phyMode, copiedField: $copiedField, onCopy: flash)
                InfoRow("Security", wifi.security, copiedField: $copiedField, onCopy: flash)
                InfoRow("Transmit rate", wifi.txRateMbps > 0 ? "\(Int(wifi.txRateMbps)) Mbps" : nil,
                        copiedField: $copiedField, onCopy: flash)
                if let country = wifi.countryCode {
                    InfoRow("Country", country, copiedField: $copiedField, onCopy: flash)
                }

                if wifi.rssi != 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Signal").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(wifi.rssi) dBm · SNR \(wifi.snr) dB")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(wifi.signalQuality), total: 100)
                            .tint(signalColor(wifi.signalQuality))
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func signalColor(_ quality: Int) -> Color {
        switch quality {
        case ..<35: return .red
        case 35..<65: return .orange
        default: return .green
        }
    }

    // MARK: - Public IP

    private var publicIPCard: some View {
        Card(title: "Public IP address", systemImage: "globe", tint: tint) {
            if let ip = model.publicIP {
                InfoRow("Public IPv4", ip, copiedField: $copiedField, onCopy: flash)
                Text("Looked up via api.ipify.org")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Your public IP is what sites and services on the internet see. Looking it up sends one request to api.ipify.org.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.publicIPError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            HStack {
                Button {
                    Task { await model.fetchPublicIP() }
                } label: {
                    if model.fetchingPublicIP {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") }
                    } else {
                        Text(model.publicIP == nil ? "Check Public IP" : "Refresh")
                    }
                }
                .disabled(model.fetchingPublicIP)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Tools

    /// A root-requiring maintenance action. Runs via `PrivilegedShell` — one
    /// macOS password prompt, no Terminal. Commands are constants (the interface
    /// name is validated to `^[a-z]{2,}[0-9]+$` before it gets here) and use
    /// absolute paths; no `sudo` prefix since `do shell script … with
    /// administrator privileges` already runs them as root.
    private enum NetTool: Identifiable {
        case flushDNS
        case renewDHCP(interface: String)

        var id: String {
            switch self {
            case .flushDNS: return "flushDNS"
            case .renewDHCP: return "renewDHCP"
            }
        }

        var title: String {
            switch self {
            case .flushDNS: return "Flush DNS cache"
            case .renewDHCP: return "Renew DHCP lease"
            }
        }

        var detail: String {
            switch self {
            case .flushDNS:
                return "Clears cached DNS lookups so stale or wrong addresses are re-resolved."
            case .renewDHCP(let iface):
                return "Asks the router for a fresh IP address on \(iface). The connection drops for a second or two."
            }
        }

        var buttonLabel: String {
            switch self {
            case .flushDNS: return "Flush"
            case .renewDHCP: return "Renew"
            }
        }

        var runningLabel: String {
            switch self {
            case .flushDNS: return "Flushing…"
            case .renewDHCP: return "Renewing…"
            }
        }

        var successMessage: String {
            switch self {
            case .flushDNS: return "DNS cache flushed."
            case .renewDHCP: return "DHCP lease renewed."
            }
        }

        var command: String {
            switch self {
            case .flushDNS:
                return "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"
            case .renewDHCP(let iface):
                return "/usr/sbin/ipconfig set \(iface) DHCP"
            }
        }
    }

    private var toolsCard: some View {
        Card(title: "Tools", systemImage: "wrench.and.screwdriver", tint: tint) {
            toolRow(.flushDNS)
            Divider()
            toolRow(.renewDHCP(interface: safeInterface))
            Divider()
            ToolRow(
                title: "Wireless Diagnostics",
                detail: "Apple's built-in tool for capturing and analysing Wi-Fi problems.",
                buttonLabel: "Open",
                isRunning: false,
                runningLabel: "",
                message: nil
            ) {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Applications/Wireless Diagnostics.app"))
            }
        }
    }

    @ViewBuilder
    private func toolRow(_ tool: NetTool) -> some View {
        ToolRow(
            title: tool.title,
            detail: tool.detail,
            buttonLabel: tool.buttonLabel,
            isRunning: runningToolID == tool.id,
            runningLabel: tool.runningLabel,
            message: toolMessage.flatMap { $0.id == tool.id ? ($0.text, $0.ok) : nil },
            disabled: runningToolID != nil
        ) {
            Task { await run(tool) }
        }
    }

    /// Primary interface name, or "en0", constrained to a plain BSD name so it's
    /// safe to interpolate into the privileged command.
    private var safeInterface: String {
        let candidate = model.info.primaryInterface ?? "en0"
        return candidate.range(of: "^[a-z]{2,}[0-9]+$", options: .regularExpression) != nil ? candidate : "en0"
    }

    private func run(_ tool: NetTool) async {
        runningToolID = tool.id
        toolMessage = nil
        defer { runningToolID = nil }
        do {
            _ = try await PrivilegedShell.run(tool.command)
            toolMessage = (tool.id, tool.successMessage, true)
            model.refresh()
        } catch PrivilegedShell.RunError.cancelled {
            toolMessage = (tool.id, "Cancelled — nothing changed.", false)
        } catch {
            toolMessage = (tool.id, error.localizedDescription, false)
        }
    }

    private func flash(_ field: String) {
        copiedField = field
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if copiedField == field { copiedField = nil }
        }
    }
}

// MARK: - Model

@MainActor
final class NetworkInfoModel: NSObject, ObservableObject {
    @Published var info = NetworkInfo()
    @Published var publicIP: String?
    @Published var publicIPError: String?
    @Published var fetchingPublicIP = false

    private let locationManager = CLLocationManager()

    override init() {
        super.init()
        locationManager.delegate = self
    }

    func refresh() {
        info = NetworkInfo.collect()
    }

    func requestLocationAccess() {
        locationManager.requestWhenInUseAuthorization()
    }

    func fetchPublicIP() async {
        fetchingPublicIP = true
        publicIPError = nil
        defer { fetchingPublicIP = false }
        do {
            publicIP = try await NetworkInfo.fetchPublicIPv4()
        } catch {
            publicIPError = "Couldn't reach api.ipify.org. Check your connection and try again."
        }
    }
}

extension NetworkInfoModel: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = manager.authorizationStatus
            if status == .authorized || status == .authorizedAlways {
                self.refresh()
            }
        }
    }
}

// MARK: - Reusable pieces

private struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct InfoRow: View {
    let label: String
    let value: String?
    @Binding var copiedField: String?
    let onCopy: (String) -> Void

    init(_ label: String, _ value: String?, copiedField: Binding<String?>, onCopy: @escaping (String) -> Void) {
        self.label = label
        self.value = value
        self._copiedField = copiedField
        self.onCopy = onCopy
    }

    var body: some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 130, alignment: .leading)
                Text(value)
                    .font(.callout.monospacedDigit())
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    onCopy(label)
                } label: {
                    Image(systemName: copiedField == label ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(copiedField == label ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Copy \(label)")
            }
            .padding(.vertical, 2)
        }
    }
}

private struct ToolRow: View {
    let title: String
    let detail: String
    let buttonLabel: String
    let isRunning: Bool
    let runningLabel: String
    /// (text, wasSuccessful) result line to show under the row, if any.
    var message: (String, Bool)?
    var disabled = false
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(action: action) {
                    if isRunning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(runningLabel)
                        }
                    } else {
                        Text(buttonLabel)
                    }
                }
                .disabled(disabled || isRunning)
            }
            if let message {
                Label(message.0, systemImage: message.1 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(message.1 ? .green : .orange)
            }
        }
        .padding(.vertical, 4)
    }
}
