// widgetshot <out.png>: draws the desktop widget (small and medium) with sample content, for the README.
// Build: swiftc -D WIDGET_PREVIEW Tools/WidgetShot/main.swift Widget/LlamaWidget.swift Sources/PixelBuffer.swift Sources/Covers.swift -o build/widgetshot
import AppKit
import SwiftUI
import WidgetKit

@MainActor
func render() {
    let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/widget.png"
    let cover = Covers.demo().cgImage().map { NSImage(cgImage: $0, size: NSSize(width: 64, height: 64)) }
    var state = NowPlayingState(title: "Example Loop", artist: "Llama Amp", playing: true, position: 12, duration: 29, updated: 0)
    state.bpm = 138; state.key = "8B"
    let entry = Entry(date: .now, state: state, progress: 0.42, step: 1, cover: cover)

    // macOS widget sizes and look: 170 × 170 and 364 × 170 points, rounded, with the system's 16-point margins
    func widget(_ f: WidgetFamily, width: CGFloat) -> some View {
        LlamaWidgetView(e: entry, preview: f)
            .padding(16)
            .frame(width: width, height: 170)
            .background(Color(red: 0.08, green: 0.08, blue: 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
    }
    let scene = HStack(spacing: 22) {
        widget(.systemSmall, width: 170)
        widget(.systemMedium, width: 364)
    }
    .padding(34)
    .background(LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.30), Color(red: 0.55, green: 0.24, blue: 0.30)],
                               startPoint: .topLeading, endPoint: .bottomTrailing))
    .environment(\.colorScheme, .dark)

    let r = ImageRenderer(content: scene)
    r.scale = 2
    guard let img = r.cgImage,
          let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { print("render failed"); exit(1) }
    try? png.write(to: URL(fileURLWithPath: out))
    print("\(out): \(img.width)×\(img.height)")
}

MainActor.assumeIsolated { render() }
