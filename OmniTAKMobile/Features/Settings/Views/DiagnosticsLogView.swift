//
//  DiagnosticsLogView.swift
//  OmniTAKMobile
//
//  Settings > Diagnostics Log. The app's own log lines since launch, with
//  search, a toggle for the system networking lines (where TLS alerts are
//  named), copy, and share as a .txt (#169).
//

import SwiftUI
import UIKit

struct DiagnosticsLogView: View {
    @State private var lines: [DiagnosticsLogLine] = []
    @State private var includeSystemNetworking = true
    @State private var search = ""
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var copied = false

    private let accent = Color(hex: "#00BCD4")

    private var visible: [DiagnosticsLogLine] {
        guard !search.isEmpty else { return lines }
        let needle = search.lowercased()
        return lines.filter {
            $0.message.lowercased().contains(needle) || $0.category.lowercased().contains(needle)
        }
    }

    var body: some View {
        List {
            Section {
                Toggle("Include system networking lines", isOn: $includeSystemNetworking)
                    .onChange(of: includeSystemNetworking) { _ in reload() }
                HStack(spacing: 16) {
                    Button {
                        UIPasteboard.general.string = exportText()
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    Button {
                        shareURL = try? DiagnosticsLog.exportFile(exportText())
                        showShare = shareURL != nil
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Spacer()
                    Button {
                        reload()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(accent)
                .buttonStyle(.plain)
            } footer: {
                Text("Lines written since the app was opened. Reproduce the problem first (for example pull to refresh in Mission Sync), then share this log.")
            }

            Section {
                if isLoading {
                    HStack { ProgressView(); Text("Reading log…").foregroundColor(.secondary) }
                } else if let loadError {
                    Text(loadError).foregroundColor(.orange)
                } else if visible.isEmpty {
                    Text(search.isEmpty ? "No log lines yet." : "No lines match \"\(search)\".")
                        .foregroundColor(.secondary)
                } else {
                    // Newest first: the line that explains the last failure is at the top.
                    ForEach(Array(visible.reversed().enumerated()), id: \.offset) { _, line in
                        Text(DiagnosticsLog.render(line: line))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(color(for: line.level))
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("\(visible.count) of \(lines.count) lines, newest first")
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "Filter")
        .navigationTitle("Diagnostics Log")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if lines.isEmpty { reload() } }
        .sheet(isPresented: $showShare) {
            if let url = shareURL {
                DiagnosticsShareSheet(activityItems: [url])
            }
        }
    }

    private func exportText() -> String {
        DiagnosticsLog.render(header: DiagnosticsLog.header(), lines: visible)
    }

    private func reload() {
        isLoading = true
        loadError = nil
        copied = false
        let includeSystem = includeSystemNetworking
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<[DiagnosticsLogLine], Error> = Result { try DiagnosticsLog.read(includeSystemNetworking: includeSystem) }
            DispatchQueue.main.async {
                switch result {
                case .success(let read): lines = read
                case .failure(let error): loadError = "Could not read the log: \(error.localizedDescription)"
                }
                isLoading = false
            }
        }
    }

    private func color(for level: String) -> Color {
        switch level {
        case "error", "fault": return Color(hex: "#FF6B6B")
        case "debug": return .secondary
        default: return .primary
        }
    }
}

struct DiagnosticsShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
