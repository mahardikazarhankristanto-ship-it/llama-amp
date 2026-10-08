import AVFoundation
import Foundation

// Key detection benchmark on a labelled dataset (GiantSteps layout: audio/<id>.mp3, annotations/key/<id>.key).
// Usage: keybench <dataset dir> [limit]
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let limit = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : Int.max
let names: [String: Int] = ["C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3, "E": 4, "F": 5, "F#": 6, "Gb": 6, "G": 7, "G#": 8, "Ab": 8, "A": 9, "A#": 10, "Bb": 10, "B": 11]
func parseKey(_ s: String) -> Int? {
    let p = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
    guard p.count == 2, let t = names[String(p[0])] else { return nil }
    return p[1].lowercased().hasPrefix("min") ? t + 12 : t
}
/// MIREX weighting: exact 1, perfect fifth 0.5, relative 0.3, parallel 0.2.
func mirex(_ est: Int, _ ref: Int) -> Double {
    if est == ref { return 1 }
    let em = est >= 12, rm = ref >= 12, et = est % 12, rt = ref % 12
    if em == rm && ((et - rt + 12) % 12 == 7 || (rt - et + 12) % 12 == 7) { return 0.5 }
    if !rm && em && et == (rt + 9) % 12 { return 0.3 }
    if rm && !em && et == (rt + 3) % 12 { return 0.3 }
    if et == rt && em != rm { return 0.2 }
    return 0
}

var items: [(URL, Int)] = []
for f in (try! FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("annotations/key"), includingPropertiesForKeys: nil)).sorted(by: { $0.path < $1.path }) {
    let id = f.deletingPathExtension().lastPathComponent
    let mp3 = root.appendingPathComponent("audio/\(id).mp3")
    guard FileManager.default.fileExists(atPath: mp3.path), let k = parseKey((try? String(contentsOf: f, encoding: .utf8)) ?? "") else { continue }
    items.append((mp3, k))
    if items.count >= limit { break }
}
print("tracks with audio and a single key label: \(items.count)")

let allVariants: [(String, KeyDetect.Options?)] = [
    ("old (v1)", nil),
    ("hpcp+harm+hpss", KeyDetect.Options(hpss: true, tuning: true, peaks: true, harmonics: 4)),
    ("hpcp+harm+hpss, energy", KeyDetect.Options(hpss: true, tuning: true, peaks: true, harmonics: 4, energyWeighted: true)),
    ("hpcp+harm.8+hpss", KeyDetect.Options(hpss: true, tuning: true, peaks: true, harmonics: 6, harmonicDecay: 0.8)),
    ("hpcp+harm+hpss, no tuning", KeyDetect.Options(hpss: true, tuning: false, peaks: true, harmonics: 4)),
]
let only = ProcessInfo.processInfo.environment["ONLY"]
let variants = only == nil ? allVariants : allVariants.filter { $0.0 == "old (v1)" || $0.0 == only }
var chromas = [[KeyDetect.Chroma?]](repeating: [KeyDetect.Chroma?](repeating: nil, count: variants.count), count: items.count)
var oldKeys = [Int?](repeating: nil, count: items.count)
let lock = NSLock()
let t0 = Date()
var done = 0
DispatchQueue.concurrentPerform(iterations: items.count) { i in
    guard let f = try? AVAudioFile(forReading: items[i].0), let x = BeatGrid.readMono(f, from: 0, count: f.length) else { return }
    let sr = f.processingFormat.sampleRate
    var row = [KeyDetect.Chroma?](repeating: nil, count: variants.count)
    var old: Int?
    for (v, (_, o)) in variants.enumerated() {
        if let o { row[v] = KeyDetect.chroma(x, sr: sr, o) } else { old = MusicKey.detect(MusicKey.chroma(x, sr: sr)) }
    }
    lock.lock(); chromas[i] = row; oldKeys[i] = old; done += 1
    if done % 50 == 0 { print("  analyzed \(done)/\(items.count) (\(Int(Date().timeIntervalSince(t0)))s)") }
    lock.unlock()
}

func report(_ label: String, _ est: [Int?]) -> Double {
    var exact = 0, compat = 0, n = 0, w = 0.0
    for (i, e) in est.enumerated() {
        guard let e else { continue }
        n += 1
        let r = items[i].1
        if e == r { exact += 1 }
        if MusicKey.distance(e, r) <= 1 { compat += 1 }
        w += mirex(e, r)
    }
    let pad = label.padding(toLength: 52, withPad: " ", startingAt: 0)
    print(String(format: "%@ exact %5.1f%%   weighted %5.1f%%   DJ-compatible %5.1f%%", pad, 100 * Double(exact) / Double(max(1, n)), 100 * w / Double(max(1, n)), 100 * Double(compat) / Double(max(1, n))))
    return Double(exact) / Double(max(1, n))
}

print("")
_ = report("old (v1): krumhansl, 3 windows", oldKeys)
let profileSets: [[String]] = [["krumhansl"], ["temperley"], ["shaath"], ["edma"], ["edma", "temperley"], ["edma", "temperley", "shaath"], ["edma", "shaath"]]
var best = (0.0, "")
for (v, (vname, o)) in variants.enumerated() where o != nil {
    for ps in profileSets where ProcessInfo.processInfo.environment["FIXED"] != nil {
        for bw in [0.0, 0.3, 0.6, 1.0] {
            let est = chromas.map { $0[v].flatMap { KeyDetect.detect($0, profiles: ps, bassWeight: bw)?.key } }
            let label = "\(vname): \(ps.joined(separator: "+")), bass \(bw)"
            let ex = report(label, est)
            if ex > best.0 { best = (ex, label) }
        }
    }
}
// data-driven profiles, 5-fold cross-validation: every track is scored with profiles learned without it
print("\n-- learned profiles (5-fold cross-validation) --")
for (v, (vname, o)) in variants.enumerated() where o != nil {
    for bw in [0.0, 0.3, 0.6, 1.0, 1.5] {
        var est = [Int?](repeating: nil, count: items.count)
        for fold in 0..<5 {
            let train = items.indices.filter { $0 % 5 != fold }.compactMap { i in chromas[i][v].map { ($0, items[i].1) } }
            let prof = KeyDetect.learn(train, bassWeight: bw)
            for i in items.indices where i % 5 == fold { est[i] = chromas[i][v].flatMap { KeyDetect.detect($0, profile: prof, bassWeight: bw)?.key } }
        }
        let label = "\(vname): LEARNED (cv), bass \(bw)"
        let ex = report(label, est)
        if ex > best.0 { best = (ex, label) }
        for blend in [["shaath"], ["temperley"]] {
            var est2 = [Int?](repeating: nil, count: items.count)
            for fold in 0..<5 {
                let train = items.indices.filter { $0 % 5 != fold }.compactMap { i in chromas[i][v].map { ($0, items[i].1) } }
                let prof = KeyDetect.learn(train, bassWeight: bw)
                for i in items.indices where i % 5 == fold { est2[i] = chromas[i][v].flatMap { KeyDetect.detect($0, profile: prof, bassWeight: bw, blend: blend, blendWeight: 0.5)?.key } }
            }
            let l2 = "\(vname): LEARNED+\(blend[0]) (cv), bass \(bw)"
            let e2 = report(l2, est2)
            if e2 > best.0 { best = (e2, l2) }
        }
    }
}
if let v = variants.firstIndex(where: { $0.0 == ProcessInfo.processInfo.environment["EXPORT"] }) {
    let bw = Double(ProcessInfo.processInfo.environment["BW"] ?? "0.6")!
    let prof = KeyDetect.learn(items.indices.compactMap { i in chromas[i][v].map { ($0, items[i].1) } }, bassWeight: bw)
    print("major:", prof.0.map { String(format: "%.5f", $0) }.joined(separator: ", "))
    print("minor:", prof.1.map { String(format: "%.5f", $0) }.joined(separator: ", "))
}
print("\nbest exact: \(best.1) -> \(String(format: "%.1f%%", best.0 * 100))   (\(Int(Date().timeIntervalSince(t0)))s)")

// error pattern for one configuration
if ProcessInfo.processInfo.environment["DIAG"] != nil {
    var hist = [String: Int]()
    for (i, row) in chromas.enumerated() {
        guard let c = row.last ?? nil, let e = KeyDetect.detect(c, profiles: ["temperley"], bassWeight: 0.3)?.key else { continue }
        let r = items[i].1
        let iv = ((e % 12) - (r % 12) + 12) % 12
        let mode = (e >= 12) == (r >= 12) ? "same mode" : (e >= 12 ? "est minor/ref major" : "est major/ref minor")
        hist["+\(iv) semitones, \(mode)", default: 0] += 1
    }
    for (k, v) in hist.sorted(by: { $0.value > $1.value }) { print(String(format: "%4d  %@", v, k)) }
    let refMinor = items.filter { $0.1 >= 12 }.count
    print("labels: \(refMinor) minor / \(items.count - refMinor) major")
    // what does the chroma of a few tracks look like vs their label?
    let pcn = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    for i in 0..<5 {
        guard let c = chromas[i].last ?? nil else { continue }
        let s = c.full.reduce(0, +)
        let top = c.full.indices.sorted { c.full[$0] > c.full[$1] }.prefix(4).map { pcn[$0] }
        print(items[i].0.lastPathComponent, "label", MusicKey.name(items[i].1), "tuning", String(format: "%.0f", c.tuningCents), "top pcs", top, String(format: "(%.2f)", c.full.max()! / s))
    }
}

// how well does the confidence score separate right from wrong answers? (cross-validated learned profiles, last variant)
if ProcessInfo.processInfo.environment["CONF"] != nil, let v = variants.indices.last {
    let bw = 0.6
    var res: [(conf: Double, right: Bool, compat: Bool)] = []
    for fold in 0..<5 {
        let train = items.indices.filter { $0 % 5 != fold }.compactMap { i in chromas[i][v].map { ($0, items[i].1) } }
        let prof = KeyDetect.learn(train, bassWeight: bw)
        for i in items.indices where i % 5 == fold {
            guard let c = chromas[i][v], let d = KeyDetect.detect(c, profile: prof, bassWeight: bw) else { continue }
            res.append((d.confidence, d.key == items[i].1, MusicKey.distance(d.key, items[i].1) <= 1))
        }
    }
    res.sort { $0.conf > $1.conf }
    for frac in [0.25, 0.5, 0.75, 1.0] {
        let top = res.prefix(Int(Double(res.count) * frac))
        let ex = Double(top.filter(\.right).count) / Double(top.count), cp = Double(top.filter(\.compat).count) / Double(top.count)
        print(String(format: "most confident %3.0f%% of songs (confidence ≥ %.4f): exact %.1f%%, DJ-compatible %.1f%%", frac * 100, top.last!.conf, ex * 100, cp * 100))
    }
}
