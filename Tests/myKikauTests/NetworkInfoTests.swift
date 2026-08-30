import Foundation
import Testing
@testable import Features

struct NetworkInfoTests {
    @Test("collect returns a self-consistent snapshot without crashing")
    func collectIsConsistent() {
        let info = NetworkInfo.collect()

        // Online implies we found both an address and a router.
        if info.isOnline {
            #expect(info.localIPv4 != nil)
            #expect(info.router != nil)
        }

        // A dotted-quad sanity check on whatever addresses we did get.
        if let ip = info.localIPv4 {
            #expect(ip.split(separator: ".").count == 4)
        }
        if let mask = info.subnetMask {
            #expect(mask.split(separator: ".").count == 4)
        }
        if let mac = info.macAddress {
            #expect(mac.split(separator: ":").count == 6)
        }

        // shortLabel and the plain-text summary never throw / are never empty.
        #expect(!info.shortLabel.isEmpty)
        #expect(!info.plainTextSummary().isEmpty)
    }

    @Test("Wi-Fi signal quality maps RSSI into 0...100")
    func signalQualityBounds() {
        var wifi = NetworkInfo.WiFi(
            ssid: nil, bssid: nil, channelNumber: 0, band: "", width: "",
            rssi: -30, noise: -90, txRateMbps: 0, phyMode: "", security: "", countryCode: nil
        )
        #expect(wifi.signalQuality == 100)
        wifi.rssi = -100
        #expect(wifi.signalQuality == 0)
        wifi.rssi = -75
        #expect((0...100).contains(wifi.signalQuality))
        #expect(wifi.snr == -75 - (-90))
    }
}
