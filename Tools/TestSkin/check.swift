import AppKit
// Compares rendered window PNGs against the synthetic skin's manifest. Usage: checkskin <dir with manifest.json> <render dir>
struct Check: Decodable { let panel: String; let x: Double; let y: Double; let any: [String]; let name: String }
let mdir = CommandLine.arguments[1], rdir = CommandLine.arguments[2]
let checks = try! JSONDecoder().decode([Check].self, from: Data(contentsOf: URL(fileURLWithPath: mdir + "/manifest.json")))
let meta = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: rdir + "/meta.json"))) as! [String: Any]
var reps: [String: NSBitmapImageRep] = [:]
var pass = 0
for c in checks {
    let rep = reps[c.panel] ?? NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: rdir + "/\(c.panel).png")))!
    reps[c.panel] = rep
    let m = meta[c.panel] as! [String: Any]
    let k = Double(m["px"] as! Int) / (m["w"] as! Double) * (meta["scale"] as! Double)   // pixels per skin unit
    let y = c.y < 0 ? (m["skinH"] as! Double) + c.y : c.y
    let px = Int(c.x * k), py = Int(y * k)
    guard let col = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { print("✗ \(c.name): out of bounds"); continue }
    let got = String(format: "%02x%02x%02x", Int((col.redComponent * 255).rounded()), Int((col.greenComponent * 255).rounded()), Int((col.blueComponent * 255).rounded()))
    func close(_ a: String, _ b: String) -> Bool {
        let x = Int(a, radix: 16)!, y = Int(b, radix: 16)!
        return (0..<3).allSatisfy { abs(((x >> ($0 * 8)) & 0xFF) - ((y >> ($0 * 8)) & 0xFF)) <= 28 }
    }
    if c.any.contains(where: { close($0, got) }) { pass += 1 } else { print("✗ \(c.name) at (\(c.x), \(y)): got #\(got), expected one of \(c.any.prefix(4).map { "#" + $0 })") }
}
print("\(pass)/\(checks.count) sprite placements correct")
