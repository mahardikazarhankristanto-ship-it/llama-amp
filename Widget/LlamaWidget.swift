import SwiftUI
import WidgetKit

/// What the app last wrote to ~/Library/Application Support/LlamaAmp/Widget/state.json.
struct NowPlayingState: Codable {
    var title = "", artist = "", playing = false, position = 0.0, duration = 0.0, updated = 0.0
    var bpm: Int?
    var key: String?
}

struct Entry: TimelineEntry {
    let date: Date
    let state: NowPlayingState?
    let progress: Double
    let step: Int
    let cover: NSImage?
}

private let folder: URL = {
    // The widget is sandboxed: read the real home (not the container) through the read-only exception.
    let home = getpwuid(getuid()).flatMap { String(validatingUTF8: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/LlamaAmp/Widget")
}()

struct Provider: TimelineProvider {
    func load() -> (NowPlayingState?, NSImage?) {
        let s = (try? Data(contentsOf: folder.appendingPathComponent("state.json"))).flatMap { try? JSONDecoder().decode(NowPlayingState.self, from: $0) }
        return (s, NSImage(contentsOf: folder.appendingPathComponent("cover.png")))
    }

    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, state: NowPlayingState(title: "Example Loop", artist: "Llama Amp", playing: true, position: 80, duration: 246), progress: 0.33, step: 0, cover: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        let (s, c) = load()
        completion(entry(s, c, at: .now, step: 0))
    }

    private func entry(_ s: NowPlayingState?, _ c: NSImage?, at d: Date, step: Int) -> Entry {
        guard let s, s.duration > 0 else { return Entry(date: d, state: s, progress: 0, step: step, cover: c) }
        let pos = s.playing ? s.position + d.timeIntervalSince1970 - s.updated : s.position
        return Entry(date: d, state: s, progress: max(0, min(1, pos / s.duration)), step: step, cover: c)
    }

    /// While playing, one entry every 5 seconds until the song ends, so the llama keeps walking on its own.
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let (s, c) = load()
        guard let s, s.playing, s.duration > 0 else { completion(Timeline(entries: [entry(s, c, at: .now, step: 0)], policy: .never)); return }
        let remaining = max(0, s.duration - (s.position + Date().timeIntervalSince1970 - s.updated))
        let n = min(120, Int(remaining / 5) + 1)
        let entries = (0..<n).map { i in entry(s, c, at: Date().addingTimeInterval(Double(i) * 5), step: i) }
        let end = Date().addingTimeInterval(remaining + 2)
        completion(Timeline(entries: entries + [Entry(date: end, state: NowPlayingState(), progress: 0, step: 0, cover: nil)], policy: .never))
    }
}

/// The skin's 13x15 llama; legs alternate between two strides while walking.
private let llamaBody = ["....##.......", "...###.......", "...####......", "...#.##......", "....###......", "....##.......",
                         "....##.......", "....##.......", "....#######..", "....########.", "....########.", "....##....##."]
private let legs = [["....#.#...#.#", "....#.#...#.#", "....#.#...#.#"],
                    ["....#.#...#.#", "...#...#.#..#", "..#.....#...#"],
                    ["....#.#...#.#", "....#.#...#.#", "....##....##."]]

struct LlamaTrack: View {
    let progress: Double
    let frame: Int
    var body: some View {
        Canvas { ctx, size in
            let px = max(1, floor(size.height / 17))
            let llamaW = 13 * px, ground = size.height - px
            let x = (size.width - llamaW - 4 * px) * progress
            let gold = Color(red: 1, green: 0.83, blue: 0.35), dim = Color.white.opacity(0.25)
            ctx.fill(Path(CGRect(x: 0, y: ground, width: size.width, height: px)), with: .color(dim))
            ctx.fill(Path(CGRect(x: 0, y: ground, width: x + 7 * px, height: px)), with: .color(gold))
            ctx.fill(Path(CGRect(x: size.width - px, y: ground - 10 * px, width: px, height: 10 * px)), with: .color(.white))
            for (fy, w) in [1, 3, 3, 1].enumerated() {
                ctx.fill(Path(CGRect(x: size.width - px - CGFloat(w) * px, y: ground - 10 * px + CGFloat(fy) * px, width: CGFloat(w) * px, height: px)), with: .color(.white))
            }
            for (ry, row) in (llamaBody + legs[frame]).enumerated() {
                for (rx, ch) in row.enumerated() where ch == "#" {
                    let c = ry < 2 ? Color(red: 0.94, green: 0.85, blue: 0.63) : Color(red: 0.85, green: 0.69, blue: 0.41)
                    ctx.fill(Path(CGRect(x: x + CGFloat(rx) * px, y: ground - 15 * px + CGFloat(ry) * px, width: px, height: px)), with: .color(c))
                }
            }
        }
    }
}

struct Cover: View {
    let image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).interpolation(.none).resizable() } else {
                LinearGradient(colors: [Color(red: 0.11, green: 0.04, blue: 0.25), Color(red: 1, green: 0.48, blue: 0.24)], startPoint: .top, endPoint: .bottom)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct LlamaWidgetView: View {
    @Environment(\.widgetFamily) var family
    let e: Entry
    private var playing: Bool { e.state?.playing == true && e.state?.title.isEmpty == false }
    private var frame: Int { playing ? 1 + e.step % 2 : 0 }
    private let green = Color(red: 0, green: 0.88, blue: 0)

    var body: some View {
        Group {
            if family == .systemSmall { small } else { medium }
        }
        .containerBackground(for: .widget) { Color(red: 0.08, green: 0.08, blue: 0.12) }
        .widgetURL(URL(string: "llamaamp://open"))
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(e.state?.title.isEmpty == false ? e.state!.title : "Nothing playing").font(.system(size: 13, weight: .bold)).foregroundStyle(.white).lineLimit(2)
            Text(e.state?.artist.isEmpty == false ? e.state!.artist : "Llama Amp").font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Cover(image: e.cover).frame(width: 52, height: 52)
                Spacer()
                Image(systemName: playing ? "play.fill" : "pause.fill").font(.system(size: 10)).foregroundStyle(green)
            }
            titles
            Spacer(minLength: 0)
            LlamaTrack(progress: e.progress, frame: frame).frame(height: 36)
        }
    }

    private var medium: some View {
        HStack(spacing: 12) {
            Cover(image: e.cover).frame(width: 112, height: 112)
            VStack(alignment: .leading, spacing: 6) {
                titles
                if let s = e.state, s.bpm != nil || s.key != nil {
                    Text([s.bpm.map { "\($0) BPM" }, s.key].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(green)
                }
                Spacer(minLength: 0)
                LlamaTrack(progress: e.progress, frame: frame).frame(height: 36)
                HStack(spacing: 18) {
                    Link(destination: URL(string: "llamaamp://prev")!) { Image(systemName: "backward.fill") }
                    Link(destination: URL(string: "llamaamp://playpause")!) { Image(systemName: playing ? "pause.fill" : "play.fill") }
                    Link(destination: URL(string: "llamaamp://next")!) { Image(systemName: "forward.fill") }
                }
                .font(.system(size: 14)).foregroundStyle(.white)
            }
        }
    }
}

@main
struct LlamaWidgets: WidgetBundle {
    var body: some Widget { NowPlayingWidget() }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LlamaAmpNowPlaying", provider: Provider()) { LlamaWidgetView(e: $0) }
            .configurationDisplayName("Llama Amp")
            .description("What's playing, with the llama walking to the end of the song.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
