import SwiftUI
import Core
import Features

struct AnalyzeView: View {
    @State private var entries: [DiskScanner.Entry] = []
    @State private var currentDir: URL?
    @State private var scanning = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Disk Analyzer").font(.title2).bold()
                Spacer()
                if let dir = currentDir {
                    Button("Back") {
                        currentDir = dir.deletingLastPathComponent()
                        scanCurrent()
                    }
                }
                Button(scanning ? "Scanning..." : "Scan Home") {
                    currentDir = FileManager.default.homeDirectoryForCurrentUser
                    scanCurrent()
                }
                .disabled(scanning)
            }
            .padding()

            if entries.isEmpty && !scanning {
                ContentUnavailableView(
                    "No Scan Yet",
                    systemImage: "chart.bar.doc.horizontal",
                    description: Text("Click Scan Home to analyze disk usage and find large files.")
                )
            } else {
                List(entries) { entry in
                    AnalyzeRow(entry: entry)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if entry.isDirectory {
                                currentDir = entry.url
                                scanCurrent()
                            }
                        }
                }
            }
        }
    }

    private func scanCurrent() {
        guard let dir = currentDir else { return }
        scanning = true
        Task.detached(priority: .userInitiated) {
            let result = DiskScanner.scan(dir)
            await MainActor.run {
                entries = result
                scanning = false
            }
        }
    }
}

private struct AnalyzeRow: View {
    let entry: DiskScanner.Entry

    var body: some View {
        HStack {
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(entry.name)
                if entry.isDirectory {
                    Text("\(entry.childCount) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(ByteSizeFormatter.format(entry.sizeBytes))
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if entry.isDirectory {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
        }
    }
}