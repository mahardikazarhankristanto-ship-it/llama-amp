import AppKit
import SwiftUI

// Shared by the app's desktop player and the WidgetKit widget: the walking pixel llama and the cover.

/// The skin's 13x15 llama; legs alternate between two strides while walking.
let pixelLlamaBody = ["....##.......", "...###.......", "...####......", "...#.##......", "....###......", "....##.......",
                              "....##.......", "....##.......", "....#######..", "....########.", "....########.", "....##....##."]
let pixelLlamaLegs = [["....#.#...#.#", "....#.#...#.#", "....#.#...#.#"],
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
            for (ry, row) in (pixelLlamaBody + pixelLlamaLegs[frame]).enumerated() {
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
