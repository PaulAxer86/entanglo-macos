//
// filename: NetworkView.swift
// path: Entanglo/Entanglo/Views/NetworkView.swift
// purpose: Lists every device seen on the local LAN (ARP + Bonjour + SSDP)
//          with hostname, vendor, friendly name and known services. Each
//          row expands to show port-probe results on demand.
//

import SwiftUI

struct NetworkView: View {
    @EnvironmentObject var state: AppState
    @State private var expanded: Set<String> = []
    @State private var probing: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if state.lanScanner.devices.isEmpty {
                emptyState
            } else {
                deviceList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Network")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Devices on your LAN", systemImage: "network")
                .font(.headline)
            Spacer()
            if state.lanScanner.isScanning {
                ProgressView().controlSize(.small)
            }
            if let last = state.lanScanner.lastScanAt {
                Text("Updated \(last, style: .relative) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                state.lanScanner.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Rescan now")
            .disabled(state.lanScanner.isScanning)
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "network.slash")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No devices found yet")
                .font(.headline)
            Text("Entanglo reads the ARP table — it fills in as your Mac talks to other devices on the LAN. Visit a site or ping the router to seed it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deviceList: some View {
        List {
            ForEach(state.lanScanner.devices) { device in
                LANDeviceRow(
                    device: device,
                    isExpanded: expanded.contains(device.id),
                    isProbing: probing.contains(device.id),
                    onToggle: { toggle(device) },
                    onIdentify: { identify(device) }
                )
            }
        }
        .listStyle(.inset)
    }

    private func toggle(_ device: LANDevice) {
        if expanded.contains(device.id) { expanded.remove(device.id) }
        else { expanded.insert(device.id) }
    }

    private func identify(_ device: LANDevice) {
        guard !probing.contains(device.id) else { return }
        probing.insert(device.id)
        expanded.insert(device.id)
        Task {
            await state.lanScanner.probe(deviceId: device.id)
            probing.remove(device.id)
        }
    }
}

private struct LANDeviceRow: View {
    let device: LANDevice
    let isExpanded: Bool
    let isProbing: Bool
    let onToggle: () -> Void
    let onIdentify: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: glyph)
                        .font(.title3)
                        .frame(width: 28)
                        .foregroundStyle(.tint)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(device.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            if isNew {
                                Text("NEW")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.blue, in: Capsule())
                            }
                        }
                        Text("\(device.ipAddress)  •  \(device.macAddress)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if let sub = device.secondary {
                            Text(sub).font(.caption).foregroundStyle(.secondary)
                        }
                        if !device.services.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(device.services, id: \.self) { svc in
                                    Text(svc)
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(.thinMaterial, in: Capsule())
                                }
                            }
                        }
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedPanel
            }
        }
    }

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(alignment: .top, spacing: 12) {
                Spacer().frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    if let hostname = device.hostname {
                        HStack(spacing: 4) {
                            Text("Hostname:").font(.caption).foregroundStyle(.secondary)
                            Text(hostname).font(.caption.monospaced())
                        }
                    }
                    if device.openPorts.isEmpty && !isProbing {
                        Button {
                            onIdentify()
                        } label: {
                            Label("Identify (scan ports)", systemImage: "magnifyingglass")
                                .font(.caption)
                        }
                        .controlSize(.small)
                    }
                    if isProbing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Scanning ports…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !device.openPorts.isEmpty {
                        Text("Open ports").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(device.openPorts, id: \.self) { port in
                            HStack(alignment: .top, spacing: 8) {
                                Text(String(port))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .frame(width: 40, alignment: .leading)
                                Text(serviceName(for: port))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let banner = device.banners[port] {
                                    Text(banner)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(2)
                                }
                            }
                        }
                        Button {
                            onIdentify()
                        } label: {
                            Label("Re-scan", systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                        .controlSize(.small)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.leading, 6)
        }
    }

    private var isNew: Bool {
        Calendar.current.isDateInToday(device.firstSeen) &&
            device.firstSeen.timeIntervalSinceNow > -300
    }

    private func serviceName(for port: Int) -> String {
        switch port {
        case 22: return "SSH"
        case 80: return "HTTP"
        case 139, 445: return "SMB"
        case 443: return "HTTPS"
        case 515: return "LPD print"
        case 548: return "AFP"
        case 554: return "RTSP"
        case 631: return "IPP print"
        case 2049: return "NFS"
        case 3389: return "RDP"
        case 5000, 5001: return "UPnP / Synology"
        case 5900: return "VNC / Screen Sharing"
        case 7000: return "AirPlay"
        case 8000, 8080: return "HTTP (alt)"
        case 8443: return "HTTPS (alt)"
        case 8200: return "DLNA"
        case 32400: return "Plex"
        case 62078: return "iPhone sync"
        default: return ""
        }
    }

    private var glyph: String {
        guard let vendor = device.vendor?.lowercased() else { return "questionmark.circle" }
        if vendor.contains("apple")        { return "apple.logo" }
        if vendor.contains("samsung")      { return "tv" }
        if vendor.contains("google")       { return "g.circle" }
        if vendor.contains("nest")         { return "thermometer.medium" }
        if vendor.contains("amazon")       { return "shippingbox" }
        if vendor.contains("sony")         { return "tv" }
        if vendor.contains("playstation")  { return "gamecontroller" }
        if vendor.contains("xbox")         { return "gamecontroller" }
        if vendor.contains("nintendo")     { return "gamecontroller" }
        if vendor.contains("raspberry")    { return "cpu" }
        if vendor.contains("espressif")    { return "cpu" }
        if vendor.contains("router") || vendor.contains("fritz")
                                            { return "wifi.router" }
        if vendor.contains("netgear") || vendor.contains("tp-link") || vendor.contains("asus")
                                            { return "wifi.router" }
        if vendor.contains("sonos") || vendor.contains("hue")
                                            { return "house" }
        if vendor.contains("synology") || vendor.contains("qnap")
                                            { return "externaldrive.connected.to.line.below" }
        if vendor.contains("roku")         { return "tv" }
        return "desktopcomputer"
    }
}
