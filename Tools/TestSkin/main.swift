import AppKit
import UniformTypeIdentifiers

// Builds a synthetic classic skin where every sprite is a unique solid colour, plus a manifest of where
// each colour must appear once rendered. Usage: maketestskin <outdir>
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dir = out.appendingPathComponent("skin")
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

var nextColor = 0
func uniqueColor() -> UInt32 {
    nextColor += 1
    let h = Double(nextColor * 47 % 360), l = 0.35 + Double(nextColor % 5) * 0.08
    return hsl(h, 0.85, l)
}
func hex(_ c: UInt32) -> String { String(format: "%02x%02x%02x", c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF) }

struct Check: Encodable { let panel: String; let x: Double; let y: Double; let any: [String]; let name: String }
var checks: [Check] = []
func check(_ panel: String, _ x: Double, _ y: Double, _ colors: [UInt32], _ name: String) {
    checks.append(Check(panel: panel, x: x, y: y, any: colors.map(hex), name: name))
}

var sheets: [String: PixelBuffer] = [:]
func sheet(_ name: String, _ w: Int, _ h: Int) -> PixelBuffer {
    let b = PixelBuffer(w, h, fill: rgb(20, 20, 20)); sheets[name] = b; return b
}
@discardableResult func spr(_ b: PixelBuffer, _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> UInt32 {
    let c = uniqueColor(); b.rect(x, y, w, h, c); return c
}

// MAIN
let main = sheet("main", 275, 116); main.fill(rgb(40, 40, 90))
check("main", 5, 70, [rgb(40, 40, 90)], "main.bmp background")
// TITLEBAR
let tb = sheet("titlebar", 344, 87)
let titleSel = spr(tb, 27, 0, 275, 14); spr(tb, 27, 15, 275, 14); spr(tb, 27, 29, 275, 14)
let clutter = spr(tb, 304, 0, 8, 43)
let opt = spr(tb, 0, 0, 9, 9); spr(tb, 0, 9, 9, 9)
let minB = spr(tb, 9, 0, 9, 9); spr(tb, 9, 9, 9, 9)
let closeB = spr(tb, 18, 0, 9, 9); spr(tb, 18, 9, 9, 9)
let shadeB = spr(tb, 0, 18, 9, 9); spr(tb, 9, 18, 9, 9); spr(tb, 0, 27, 9, 9); spr(tb, 9, 27, 9, 9)
check("main", 120, 7, [titleSel], "title bar"); check("main", 14, 40, [clutter], "clutter bar")
check("main", 10, 7, [opt], "options button"); check("main", 248, 7, [minB], "minimize button")
check("main", 258, 7, [shadeB], "shade button"); check("main", 268, 7, [closeB], "close button")
// CBUTTONS
let cb = sheet("cbuttons", 136, 36)
for (i, (x, w, h, dx)) in [(0, 23, 18, 16), (23, 23, 18, 39), (46, 23, 18, 62), (69, 23, 18, 85), (92, 22, 18, 108), (114, 22, 16, 136)].enumerated() {
    let c = spr(cb, x, 0, w, h); spr(cb, x, h, w, h)
    check("main", Double(dx + w / 2), Double((i == 5 ? 89 : 88) + h / 2), [c], ["prev", "play", "pause", "stop", "next", "eject"][i] + " button")
}
// POSBAR
let pb = sheet("posbar", 307, 10)
let posBg = spr(pb, 0, 0, 248, 10); spr(pb, 248, 0, 29, 10); spr(pb, 278, 0, 29, 10)
check("main", 200, 77, [posBg], "position bar")
// VOLUME / BALANCE
let vol = sheet("volume", 68, 433)
let volFrames = (0..<28).map { spr(vol, 0, $0 * 15, 68, 13) }
let volThumb = spr(vol, 15, 422, 14, 11); spr(vol, 0, 422, 14, 11)
check("main", 108, 63, volFrames, "volume background"); _ = volThumb
let bal = sheet("balance", 68, 433)
let balFrames = (0..<28).map { spr(bal, 9, $0 * 15, 38, 13) }
spr(bal, 15, 422, 14, 11); spr(bal, 0, 422, 14, 11)
check("main", 178, 63, balFrames, "balance background")
// SHUFREP
let sr = sheet("shufrep", 92, 85)
let rep = [0, 15, 30, 45].map { spr(sr, 0, $0, 28, 15) }, shuf = [0, 15, 30, 45].map { spr(sr, 28, $0, 47, 15) }
let eqb = [spr(sr, 0, 61, 23, 12), spr(sr, 0, 73, 23, 12)], plb = [spr(sr, 23, 61, 23, 12), spr(sr, 23, 73, 23, 12)]
spr(sr, 46, 61, 23, 12); spr(sr, 46, 73, 23, 12); spr(sr, 69, 61, 23, 12); spr(sr, 69, 73, 23, 12)
check("main", 224, 96, [rep[0], rep[2]], "repeat button"); check("main", 187, 96, [shuf[0], shuf[2]], "shuffle button")
check("main", 230, 64, eqb, "EQ toggle"); check("main", 253, 64, plb, "PL toggle")
// MONOSTER, PLAYPAUS, NUMBERS
let ms = sheet("monoster", 56, 24)
let st = [spr(ms, 0, 0, 29, 12), spr(ms, 0, 12, 29, 12)], mo = [spr(ms, 29, 0, 27, 12), spr(ms, 29, 12, 27, 12)]
check("main", 253, 47, st, "stereo indicator"); check("main", 225, 47, mo, "mono indicator")
let pp = sheet("playpaus", 42, 9)
let states = [spr(pp, 0, 0, 9, 9), spr(pp, 9, 0, 9, 9), spr(pp, 18, 0, 9, 9)]; spr(pp, 36, 0, 3, 9); spr(pp, 39, 0, 3, 9)
check("main", 30, 32, states, "play/pause indicator")
let nb = sheet("numbers", 99, 13)
let digits = (0..<11).map { spr(nb, $0 * 9, 0, 9, 13) }
check("main", 52, 32, digits, "time digit (minutes)"); check("main", 94, 32, digits, "time digit (seconds)")
// TEXT: real glyphs from the app's pixel font, 5x6 cells
let tx = sheet("text", 155, 18); tx.fill(rgb(0, 0, 0))
let glyphRows = ["ABCDEFGHIJKLMNOPQRSTUVWXYZ\"@   ", "0123456789….:()-'!_+\\/[]^&%,=$#", "ÅÖÄ?*                          "]
for (row, chars) in glyphRows.enumerated() {
    for (col, ch) in chars.enumerated() {
        guard let gl = PixelFont.glyphs[ch] else { continue }
        for (gy, line) in gl.enumerated() { for (gx, c) in line.enumerated() where c == "#" && gx < 5 { tx.set(col * 5 + gx, row * 6 + gy, rgb(0, 230, 0)) } }
    }
}
// EQMAIN
let eq = sheet("eqmain", 275, 315); eq.fill(rgb(70, 30, 30))
let eqTitle = spr(eq, 0, 134, 275, 14); spr(eq, 0, 149, 275, 14)
let eqClose = spr(eq, 0, 116, 9, 9); spr(eq, 0, 125, 9, 9)
let on = [10, 69, 128, 187].map { spr(eq, $0, 119, 26, 12) }, auto = [36, 95, 154, 213].map { spr(eq, $0, 119, 32, 12) }
let frames = (0..<28).map { spr(eq, 13 + ($0 % 14) * 15, 164 + ($0 / 14) * 65, 14, 63) }
spr(eq, 0, 164, 11, 11); spr(eq, 0, 176, 11, 11)
let presets = spr(eq, 224, 164, 44, 12); spr(eq, 224, 176, 44, 12)
let graphBg = spr(eq, 0, 294, 113, 19)
for y in 0..<19 { eq.set(115, 294 + y, hsl(Double(y) * 18, 1, 0.5)) }
spr(eq, 0, 314, 113, 1)
check("eq", 5, 60, [rgb(70, 30, 30)], "eqmain.bmp background"); check("eq", 120, 7, [eqTitle], "EQ title bar")
check("eq", 268, 7, [eqClose], "EQ close button"); check("eq", 27, 24, [on[0], on[1]], "EQ ON button")
check("eq", 56, 24, [auto[0], auto[1]], "EQ AUTO button"); check("eq", 239, 24, [presets], "EQ PRESETS button")
check("eq", 28, 99, frames, "preamp slider background"); check("eq", 85, 99, frames, "60 Hz slider background")
check("eq", 247, 99, frames, "16 kHz slider background"); check("eq", 90, 19, [graphBg] + (0..<19).map { hsl(Double($0) * 18, 1, 0.5) }, "EQ graph")
// PLEDIT
let pl = sheet("pledit", 280, 186)
let tl = spr(pl, 0, 0, 25, 20), ttl = spr(pl, 26, 0, 100, 20), tt = spr(pl, 127, 0, 25, 20), tr = spr(pl, 153, 0, 25, 20)
spr(pl, 0, 21, 25, 20); spr(pl, 26, 21, 100, 20); spr(pl, 127, 21, 25, 20); spr(pl, 153, 21, 25, 20)
let lt = spr(pl, 0, 42, 12, 29), rt = spr(pl, 31, 42, 20, 29)
spr(pl, 52, 42, 9, 9); let handle = spr(pl, 52, 53, 8, 18); spr(pl, 61, 53, 8, 18)
let bl = spr(pl, 0, 72, 125, 38), brc = spr(pl, 126, 72, 150, 38)
check("pl", 12, 10, [tl], "playlist top-left corner"); check("pl", 137, 10, [ttl], "playlist title"); check("pl", 40, 10, [tt], "playlist top tile")
check("pl", 268, 16, [tr], "playlist top-right corner"); check("pl", 5, 60, [lt], "playlist left edge"); check("pl", 272, 100, [rt], "playlist right edge")
check("pl", 60, -5, [bl], "playlist bottom-left (buttons)"); check("pl", 200, -5, [brc], "playlist bottom-right"); check("pl", 263, 25, [handle], "playlist scroll handle")
check("pl", 100, -45, [rgb(0x10, 0x10, 0x40)], "playlist background colour (pledit.txt)")
// text files
var vis = (0..<24).map { _ in uniqueColor() }
vis[0] = rgb(5, 30, 5)
check("main", 24.5, 43.5, [vis[0]], "visualizer background (viscolor.txt)")
let visTxt = vis.map { "\($0 & 0xFF),\(($0 >> 8) & 0xFF),\(($0 >> 16) & 0xFF), // colour" }.joined(separator: "\n")
try! visTxt.write(to: dir.appendingPathComponent("VISCOLOR.TXT"), atomically: true, encoding: .utf8)
try! "[Text]\nNormal=#11EE11\nCurrent=#FFFF00\nNormalBG=#101040\nSelectedBG=#802020\nFont=Arial\n".write(to: dir.appendingPathComponent("PLEDIT.TXT"), atomically: true, encoding: .utf8)

for (name, b) in sheets {
    let url = dir.appendingPathComponent(name.uppercased() + ".BMP")
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.bmp.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, b.cgImage()!, nil)
    CGImageDestinationFinalize(d)
}
try! JSONEncoder().encode(checks).write(to: out.appendingPathComponent("manifest.json"))
let zip = Process()
zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
zip.currentDirectoryURL = dir
zip.arguments = ["-q", "-r", out.appendingPathComponent("TestSkin.wsz").path, "."]
try! zip.run(); zip.waitUntilExit()
print("wrote \(sheets.count) sheets, \(checks.count) checks")
