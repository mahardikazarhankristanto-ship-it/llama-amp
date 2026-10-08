import AppKit

/// A 5-pixel-tall bitmap font in the spirit of the classic skin's text.bmp.
enum PixelFont {
    static let height: CGFloat = 5
    static let glyphs: [Character: [String]] = [
        "A": [".##.", "#..#", "####", "#..#", "#..#"], "B": ["###.", "#..#", "###.", "#..#", "###."],
        "C": [".###", "#...", "#...", "#...", ".###"], "D": ["###.", "#..#", "#..#", "#..#", "###."],
        "E": ["####", "#...", "###.", "#...", "####"], "F": ["####", "#...", "###.", "#...", "#..."],
        "G": [".###", "#...", "#.##", "#..#", ".###"], "H": ["#..#", "#..#", "####", "#..#", "#..#"],
        "I": ["###", ".#.", ".#.", ".#.", "###"], "J": ["...#", "...#", "...#", "#..#", ".##."],
        "K": ["#..#", "#.#.", "##..", "#.#.", "#..#"], "L": ["#...", "#...", "#...", "#...", "####"],
        "M": ["#...#", "##.##", "#.#.#", "#...#", "#...#"], "N": ["#..#", "##.#", "#.##", "#..#", "#..#"],
        "O": [".##.", "#..#", "#..#", "#..#", ".##."], "P": ["###.", "#..#", "###.", "#...", "#..."],
        "Q": [".##.", "#..#", "#..#", "#.#.", ".#.#"], "R": ["###.", "#..#", "###.", "#.#.", "#..#"],
        "S": [".###", "#...", ".##.", "...#", "###."], "T": ["###", ".#.", ".#.", ".#.", ".#."],
        "U": ["#..#", "#..#", "#..#", "#..#", ".##."], "V": ["#...#", "#...#", ".#.#.", ".#.#.", "..#.."],
        "W": ["#...#", "#...#", "#.#.#", "##.##", "#...#"], "X": ["#..#", "#..#", ".##.", "#..#", "#..#"],
        "Y": ["#.#", "#.#", ".#.", ".#.", ".#."], "Z": ["####", "...#", ".##.", "#...", "####"],
        "0": ["###", "#.#", "#.#", "#.#", "###"], "1": [".#.", "##.", ".#.", ".#.", "###"],
        "2": ["###", "..#", "###", "#..", "###"], "3": ["###", "..#", ".##", "..#", "###"],
        "4": ["#.#", "#.#", "###", "..#", "..#"], "5": ["###", "#..", "###", "..#", "###"],
        "6": ["###", "#..", "###", "#.#", "###"], "7": ["###", "..#", ".#.", ".#.", ".#."],
        "8": ["###", "#.#", "###", "#.#", "###"], "9": ["###", "#.#", "###", "..#", "###"],
        " ": ["...", "...", "...", "...", "..."], ".": [".", ".", ".", ".", "#"],
        ",": ["..", "..", "..", ".#", "#."], ":": [".", "#", ".", "#", "."], ";": ["..", ".#", "..", ".#", "#."],
        "-": ["...", "...", "###", "...", "..."], "+": ["...", ".#.", "###", ".#.", "..."],
        "(": [".#", "#.", "#.", "#.", ".#"], ")": ["#.", ".#", ".#", ".#", "#."],
        "[": ["##", "#.", "#.", "#.", "##"], "]": ["##", ".#", ".#", ".#", "##"],
        "/": ["..#", "..#", ".#.", "#..", "#.."], "!": ["#", "#", "#", ".", "#"],
        "?": ["###", "..#", ".##", "...", ".#."], "'": ["#", "#", ".", ".", "."],
        "\"": ["#.#", "#.#", "...", "...", "..."], "*": ["#.#", ".#.", "#.#", "...", "..."],
        "#": [".#.#.", "#####", ".#.#.", "#####", ".#.#."], "%": ["#.#", "..#", ".#.", "#..", "#.#"],
        "&": [".#..", "#.#.", ".#..", "#.#.", ".#.#"], "_": ["...", "...", "...", "...", "###"],
        "=": ["...", "###", "...", "###", "..."], "<": ["..#", ".#.", "#..", ".#.", "..#"],
        ">": ["#..", ".#.", "..#", ".#.", "#.."], "@": [".##.", "#.##", "#.##", "#...", ".##."],
        "$": [".###", "##..", ".##.", "..##", "###."],
    ]

    static func normalize(_ s: String) -> String {
        s.folding(options: .diacriticInsensitive, locale: nil).uppercased()
            .replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2013}", with: "-").replacingOccurrences(of: "\u{2014}", with: "-")
    }

    static func supports(_ s: String) -> Bool { normalize(s).allSatisfy { glyphs[$0] != nil } }

    private static let fallbackFont = NSFont.systemFont(ofSize: 7.5, weight: .medium)

    static func width(_ s: String) -> CGFloat {
        let n = normalize(s)
        if !n.allSatisfy({ glyphs[$0] != nil }) {
            return ceil((s as NSString).size(withAttributes: [.font: fallbackFont]).width)
        }
        let total = n.reduce(0) { $0 + (glyphs[$1]?.first?.count ?? 3) + 1 }
        return CGFloat(max(0, total - 1))
    }

    /// Draws at (x, y) = top-left in a flipped context. Text the font can't show falls back to the system font.
    static func draw(_ s: String, x: CGFloat, y: CGFloat, color: CGColor, in g: CGContext) {
        let n = normalize(s)
        if !n.allSatisfy({ glyphs[$0] != nil }) {
            g.saveGState()
            g.setShouldAntialias(true)
            (s as NSString).draw(at: NSPoint(x: x, y: y - 3.5),
                                 withAttributes: [.font: fallbackFont, .foregroundColor: NSColor(cgColor: color) ?? .green])
            g.restoreGState()
            return
        }
        var rects: [CGRect] = []
        var cx = x
        for ch in n {
            guard let gl = glyphs[ch] else { continue }
            for (ry, row) in gl.enumerated() {
                for (rx, c) in row.enumerated() where c == "#" {
                    rects.append(CGRect(x: cx + CGFloat(rx), y: y + CGFloat(ry), width: 1, height: 1))
                }
            }
            cx += CGFloat((gl.first?.count ?? 3) + 1)
        }
        g.setFillColor(color)
        g.fill(rects)
    }
}

/// 9x13 seven-segment LCD digits for the time display.
enum SevenSeg {
    // a, b, c, d, e, f, g
    static let segs: [CGRect] = [
        CGRect(x: 2, y: 0, width: 5, height: 2), CGRect(x: 7, y: 2, width: 2, height: 4),
        CGRect(x: 7, y: 7, width: 2, height: 4), CGRect(x: 2, y: 11, width: 5, height: 2),
        CGRect(x: 0, y: 7, width: 2, height: 4), CGRect(x: 0, y: 2, width: 2, height: 4),
        CGRect(x: 2, y: 5, width: 5, height: 2),
    ]
    static let map: [[Int]] = [[0, 1, 2, 3, 4, 5], [1, 2], [0, 1, 6, 4, 3], [0, 1, 6, 2, 3], [5, 6, 1, 2],
                               [0, 5, 6, 2, 3], [0, 5, 6, 4, 3, 2], [0, 1, 2], [0, 1, 2, 3, 4, 5, 6], [0, 1, 2, 3, 5, 6]]

    static func draw(_ d: Int?, x: CGFloat, y: CGFloat, on: CGColor, off: CGColor, in g: CGContext) {
        g.setFillColor(off)
        g.fill(segs.map { $0.offsetBy(dx: x, dy: y) })
        guard let d, (0...9).contains(d) else { return }
        g.setFillColor(on)
        g.fill(map[d].map { segs[$0].offsetBy(dx: x, dy: y) })
    }
}
