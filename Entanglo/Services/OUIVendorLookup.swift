//
// filename: OUIVendorLookup.swift
// path: Entanglo/Entanglo/Services/OUIVendorLookup.swift
// purpose: Maps the first 24 bits of a MAC address (the OUI) to a vendor
//          name. Curated set of the most common consumer prefixes so we
//          don't ship a 4MB IEEE registry. Falls back to nil for unknown
//          prefixes — the UI just hides the vendor row in that case.
//

import Foundation

public final class OUIVendorLookup {
    private let table: [String: String]

    public init(table: [String: String]? = nil) {
        self.table = table ?? Self.defaultTable
    }

    public func vendor(for mac: String) -> String? {
        let normalized = mac.lowercased().replacingOccurrences(of: "-", with: ":")
        let parts = normalized.split(separator: ":")
        guard parts.count >= 3 else { return nil }
        let prefix = parts[0..<3].joined(separator: ":")
        return table[prefix]
    }

    // Curated list of common consumer/IoT OUIs. Add as needed; the IEEE
    // registry has ~40k entries but the home-LAN long tail is small.
    private static let defaultTable: [String: String] = [
        // Apple
        "a4:83:e7": "Apple", "ac:bc:32": "Apple", "f0:18:98": "Apple",
        "3c:22:fb": "Apple", "f4:5c:89": "Apple", "00:1d:4f": "Apple",
        "98:01:a7": "Apple", "5c:f9:38": "Apple", "8c:85:90": "Apple",
        "dc:a9:04": "Apple", "f4:f1:5a": "Apple", "a8:60:b6": "Apple",
        "ac:de:48": "Apple", "00:25:00": "Apple", "00:26:bb": "Apple",
        "70:cd:60": "Apple", "8c:7c:92": "Apple", "b8:09:8a": "Apple",
        // Samsung
        "00:12:fb": "Samsung", "00:15:b9": "Samsung", "00:17:c9": "Samsung",
        "5c:0a:5b": "Samsung", "78:1f:db": "Samsung", "c8:19:f7": "Samsung",
        "08:08:c2": "Samsung", "34:23:ba": "Samsung",
        // Google / Nest
        "f4:f5:d8": "Google", "f4:f5:e8": "Google", "1c:f2:9a": "Google",
        "30:fd:38": "Google Nest", "64:16:66": "Google Nest",
        "a4:77:33": "Google", "6c:ad:f8": "Google Chromecast",
        // Amazon
        "0c:47:c9": "Amazon", "44:65:0d": "Amazon", "f0:27:2d": "Amazon",
        "68:54:fd": "Amazon", "fc:65:de": "Amazon", "a0:02:dc": "Amazon",
        // Sony
        "00:0e:07": "Sony", "00:13:a9": "Sony", "00:24:be": "Sony",
        // LG
        "00:1c:62": "LG", "00:1e:75": "LG", "00:1f:6b": "LG",
        // Microsoft / Xbox
        "00:50:f2": "Microsoft", "00:15:5d": "Microsoft", "7c:1e:52": "Microsoft",
        "00:12:5a": "Microsoft", "00:22:48": "Microsoft Xbox",
        // Sony PlayStation
        "00:04:1f": "Sony PlayStation", "00:13:15": "Sony PlayStation",
        "70:9e:29": "Sony PlayStation",
        // Nintendo
        "00:09:bf": "Nintendo", "00:16:56": "Nintendo", "00:17:ab": "Nintendo",
        "00:1a:e9": "Nintendo", "00:1b:7a": "Nintendo", "00:1f:32": "Nintendo",
        "00:21:bd": "Nintendo", "98:b6:e9": "Nintendo Switch",
        // Raspberry Pi
        "b8:27:eb": "Raspberry Pi", "dc:a6:32": "Raspberry Pi",
        "e4:5f:01": "Raspberry Pi", "28:cd:c1": "Raspberry Pi",
        // Espressif (lots of IoT)
        "24:0a:c4": "Espressif", "5c:cf:7f": "Espressif", "ec:fa:bc": "Espressif",
        "ac:67:b2": "Espressif",
        // Common router brands
        "00:1f:33": "Netgear", "00:22:3f": "Netgear", "c0:3f:0e": "Netgear",
        "00:0c:43": "TP-Link", "14:cc:20": "TP-Link", "50:c7:bf": "TP-Link",
        "00:1d:7e": "Cisco-Linksys", "98:fc:11": "Cisco-Linksys",
        "00:1d:0f": "TP-Link",
        "5c:49:79": "AVM Fritz!Box", "5c:f4:ab": "AVM Fritz!Box",
        "c0:25:06": "AVM Fritz!Box", "9c:c7:a6": "AVM Fritz!Box",
        // ASUS / common routers
        "00:1b:fc": "ASUS", "00:24:8c": "ASUS", "30:5a:3a": "ASUS",
        // Dell / HP / Lenovo
        "00:24:e8": "Dell", "00:14:22": "Dell", "f8:db:88": "Dell",
        "00:25:b3": "HP", "00:0e:7f": "HP", "b4:b6:86": "HP",
        "00:21:86": "Lenovo", "00:24:7e": "Lenovo",
        // Sonos
        "00:0e:58": "Sonos", "94:9f:3e": "Sonos", "5c:aa:fd": "Sonos",
        // Philips Hue
        "00:17:88": "Philips Hue", "ec:b5:fa": "Philips Hue",
        // Tesla
        "98:ed:5c": "Tesla", "4c:fc:aa": "Tesla", "54:e0:61": "Tesla",
        // Eero
        "f0:ee:10": "Eero", "ac:9c:5e": "Eero",
        // Intel (lots of laptops)
        "00:1b:21": "Intel", "00:1f:3c": "Intel", "00:21:6a": "Intel",
        "00:22:fb": "Intel", "08:11:96": "Intel", "8c:55:4a": "Intel",
        // Broadcom (routers, many embedded)
        "00:10:18": "Broadcom",
        // Synology
        "00:11:32": "Synology",
        // QNAP
        "00:08:9b": "QNAP", "24:5e:be": "QNAP",
        // Roku
        "ac:3a:7a": "Roku", "b0:a7:37": "Roku", "c8:3a:6b": "Roku",
        // Xiaomi
        "28:6c:07": "Xiaomi", "64:b4:73": "Xiaomi", "8c:53:c3": "Xiaomi",
        // Huawei
        "00:1e:10": "Huawei", "00:25:9e": "Huawei", "ac:4e:91": "Huawei"
    ]
}
