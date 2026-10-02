import AppKit
import KumquatCore
import SwiftUI

struct ImageMetadataView: View {
    let url: URL
    let close: () -> Void
    @State private var summary: ImageMetadata.Summary?
    @State private var errorMessage: String?
    @State private var thumbnail: CGImage?

    static func open(_ url: URL) {
        ToolWindowManager.shared.open(title: L("Metadata"), size: NSSize(width: 440, height: 600)) { close in
            ImageMetadataView(url: url, close: close)
        }
    }

    var body: some View {
        ToolChrome(title: L("Metadata"), close: close) {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable().scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(url.lastPathComponent)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(2)
                        if let summary {
                            Label(summary.hasLocation ? L("Contains location") : L("No location data"),
                                  systemImage: summary.hasLocation ? "location.fill" : "location.slash")
                                .font(.system(size: 11))
                                .foregroundStyle(summary.hasLocation ? Theme.tangerineDeep : Theme.inkSecondary)
                        }
                    }
                    Spacer()
                }
                ScrollView {
                    if let summary {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(sections(summary), id: \.self) { section in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(L(section).uppercased())
                                        .font(.system(size: 9.5, weight: .bold))
                                        .tracking(0.6)
                                        .foregroundStyle(Theme.inkSecondary)
                                    ForEach(summary.entries.filter { $0.section == section }) { entry in
                                        HStack(alignment: .top) {
                                            Text(L(entry.label)).foregroundStyle(Theme.inkSecondary)
                                                .frame(width: 100, alignment: .leading)
                                            Text(entry.value).foregroundStyle(Theme.ink).textSelection(.enabled)
                                            Spacer(minLength: 0)
                                        }
                                        .font(.system(size: 11.5))
                                    }
                                }
                            }
                            if let lat = summary.latitude, let lon = summary.longitude {
                                Button(L("Show in Maps")) {
                                    if let maps = URL(string: "maps://?ll=\(lat),\(lon)&q=\(lat),\(lon)") {
                                        NSWorkspace.shared.open(maps)
                                    }
                                }
                                .buttonStyle(SecondaryButtonStyle())
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        LoadingView(error: errorMessage).frame(height: 200)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.3)))
            }
        } footer: {
            Button(L("Remove Location")) { strip(.location) }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!(summary?.hasLocation ?? false))
            Spacer()
            Button(L("Remove All Metadata")) { strip(.everything) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(summary == nil)
        }
        .task {
            do {
                summary = try ImageMetadata.summary(of: url)
                thumbnail = try? ImageIOHelpers.loadImage(url, maxPixelSize: 160)
            } catch {
                errorMessage = ConversionEngine.message(for: error)
            }
        }
    }

    private func sections(_ summary: ImageMetadata.Summary) -> [String] {
        var seen: [String] = []
        for e in summary.entries where !seen.contains(e.section) { seen.append(e.section) }
        return seen
    }

    private func strip(_ mode: ImageMetadata.StripMode) {
        let url = url
        close()
        ToolWindowManager.shared.save(title: L("Removing metadata"), doneTitle: L("Clean copy saved")) {
            try ImageMetadata.strip(url, mode: mode)
        }
    }
}

struct PDFMetadataView: View {
    let url: URL
    let close: () -> Void
    @State private var metadata = PDFTools.Metadata()
    @State private var loaded = false
    @State private var errorMessage: String?

    static func open(_ url: URL) {
        ToolWindowManager.shared.open(title: L("PDF Info"), size: NSSize(width: 440, height: 520)) { close in
            PDFMetadataView(url: url, close: close)
        }
    }

    var body: some View {
        ToolChrome(title: L("PDF Info"), close: close) {
            if loaded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    field(L("Title"), $metadata.title)
                    field(L("Author"), $metadata.author)
                    field(L("Subject"), $metadata.subject)
                    field(L("Keywords"), $metadata.keywords)
                    Rectangle().fill(Theme.separator).frame(height: 1).padding(.vertical, 4)
                    info(L("Pages"), "\(metadata.pageCount)")
                    info(L("PDF version"), metadata.version)
                    info(L("Created by"), metadata.creator)
                    info(L("Producer"), metadata.producer)
                    info(L("Created"), metadata.created.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                    info(L("Modified"), metadata.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                    Spacer()
                }
            } else {
                LoadingView(error: errorMessage)
            }
        } footer: {
            Button(L("Remove All")) { save(PDFTools.Metadata(), tag: "No Metadata") }
                .buttonStyle(SecondaryButtonStyle())
            Spacer()
            Button(L("Save Copy")) { save(metadata, tag: "Edited") }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!loaded)
        }
        .task {
            do {
                metadata = try PDFTools.readMetadata(url)
                loaded = true
            } catch {
                errorMessage = ConversionEngine.message(for: error)
            }
        }
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        HStack {
            FieldLabel(text: label)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.fieldFill))
        }
    }

    private func info(_ label: String, _ value: String) -> some View {
        HStack {
            FieldLabel(text: label)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func save(_ metadata: PDFTools.Metadata, tag: String) {
        let url = url
        close()
        ToolWindowManager.shared.save(title: L("Saving PDF info"), doneTitle: L("Saved")) {
            try PDFTools.writeMetadata(url, metadata: metadata, tag: tag)
        }
    }
}
