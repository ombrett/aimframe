import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

// Runs on the CI Mac before the app is built. Exercises the decision logic and the looks with
// measured inputs, prints every result, and fails the build if a check fails.

var failures = 0
var passes = 0

func check(_ ok: Bool, _ name: String, _ detail: String = "") {
    if ok { passes += 1; print("PASS  \(name) \(detail)") } else { failures += 1; print("FAIL  \(name) \(detail)") }
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ci-out"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// MARK: Hint stabiliser

do {
    var s = HintStabilizer()
    let left = Instruction.guide("Sposta il telefono a sinistra", for: .photographer)
    let right = Instruction.guide("Sposta il telefono a destra", for: .photographer)
    var shown: [String] = []
    var t = 0.0
    for i in 0..<20 {                             // opposite requests every 0.1 s
        shown.append(s.update(i % 2 == 0 ? left : right, now: t).text)
        t += 0.1
    }
    check(Set(shown).count == 1, "hint: flickering requests keep one instruction", "\(Set(shown))")
    var last = ""
    for _ in 0..<10 { last = s.update(right, now: t).text; t += 0.1 }
    check(last == right.text, "hint: a steady new request takes over after the hold time")
    let urgent = s.update(.good("Pronto"), now: t, urgent: true)
    check(urgent.text == "Pronto", "hint: urgent instruction is shown at once")
}

// MARK: Aim

do {
    var axis: AimAxis?
    let a = Aim.instruction(dx: 0.10, dy: 0.09, axis: &axis)
    let b = Aim.instruction(dx: 0.09, dy: 0.10, axis: &axis)
    check(a == b && axis == .horizontal, "aim: keeps the axis being corrected", "\(a ?? "-") / \(b ?? "-")")
    let c = Aim.instruction(dx: 0.02, dy: 0.20, axis: &axis)
    check(c == "Alza il telefono", "aim: switches when the other axis is clearly worse", c ?? "-")
    let d = Aim.instruction(dx: 0.01, dy: -0.02, axis: &axis)
    check(d == nil && axis == nil, "aim: inside the dead zone says nothing")
    var axis2: AimAxis?
    check(Aim.instruction(dx: 0.05, dy: 0, axis: &axis2) == "Sposta leggermente il telefono a destra", "aim: small offsets say 'leggermente'")
}

// MARK: Auto shot

do {
    var a = AutoShot()
    var fires = 0
    var t = 0.0
    for _ in 0..<120 {                            // 4 s ready and steady at 30 Hz
        if a.update(now: t, ready: true, steady: true, enabled: true) { fires += 1 }
        t += 1.0 / 30
    }
    check(fires == 1, "auto: one shot per lock", "fires=\(fires)")
    a.observe(angleSinceShot: 0.2)                                  // 0.2 rad: not enough
    var again = 0
    for _ in 0..<60 { if a.update(now: t, ready: true, steady: true, enabled: true) { again += 1 }; t += 1.0 / 30 }
    check(again == 0 && !a.armed, "auto: a small turn does not re-arm")
    a.observe(angleSinceShot: 1.0)                                  // 1 rad: a new scene
    check(a.armed, "auto: turning to a new scene re-arms")
    for _ in 0..<60 { if a.update(now: t, ready: true, steady: true, enabled: true) { again += 1 }; t += 1.0 / 30 }
    check(again == 1, "auto: shoots again on the new scene", "fires=\(again)")

    var b = AutoShot()
    t = 0
    var unsteadyFires = 0
    for i in 0..<120 {                            // shaking every few frames never completes the hold
        if b.update(now: t, ready: true, steady: i % 10 != 0, enabled: true) { unsteadyFires += 1 }
        t += 1.0 / 30
    }
    check(unsteadyFires == 0, "auto: needs the phone still for the whole hold")

    var c = AutoShot()
    t = 0
    _ = c.update(now: t, ready: true, steady: true, enabled: true)
    t += 0.5
    _ = c.update(now: t, ready: true, steady: true, enabled: true)
    check((c.progress ?? 0) > 0.4, "auto: progress is visible", "\(c.progress ?? -1)")
    c.cancel()
    var cancelledFires = 0
    for _ in 0..<60 { if c.update(now: t, ready: true, steady: true, enabled: true) { cancelledFires += 1 }; t += 1.0 / 30 }
    check(cancelledFires == 0, "auto: cancel stops the shot while the framing stays")
    _ = c.update(now: t, ready: false, steady: true, enabled: true)
    for _ in 0..<40 { if c.update(now: t, ready: true, steady: true, enabled: true) { cancelledFires += 1 }; t += 1.0 / 30 }
    check(cancelledFires == 1, "auto: after losing and finding the framing it works again")

    // 15 s of hand tremor and taps: the angle wobbles around the shot position and never re-arms.
    var j = AutoShot()
    var jt = 0.0
    var firedOnce = false
    for _ in 0..<45 { if j.update(now: jt, ready: true, steady: true, enabled: true) { firedOnce = true }; jt += 1.0 / 30 }
    for i in 0..<450 {
        j.observe(angleSinceShot: 0.08 + 0.07 * sin(Double(i) * 0.9))
        _ = j.update(now: jt, ready: true, steady: true, enabled: true)
        jt += 1.0 / 30
    }
    check(firedOnce && !j.armed, "auto: 15 s of jitter on the same scene does not re-arm")

    var d = AutoShot()
    d.didShootManually()
    var manualFires = 0
    for _ in 0..<60 { if d.update(now: t, ready: true, steady: true, enabled: true) { manualFires += 1 }; t += 1.0 / 30 }
    check(manualFires == 0, "auto: no automatic shot right after a manual one")
}

// MARK: Exposure

do {
    var e = ExposureDecider()
    var changes: [Float] = []
    for _ in 0..<6 { if let b = e.update(mean: 0.6, highlights: 0.2, subjectMean: 0.55) { changes.append(b) } }
    check(changes == [-0.5], "exposure: burnt sky with a bright subject darkens", "\(changes)")
    for _ in 0..<6 { if let b = e.update(mean: 0.5, highlights: 0.05, subjectMean: 0.5) { changes.append(b) } }
    check(e.bias == -0.5, "exposure: holds while the scene stays bright (no pumping)")
    for _ in 0..<6 { if let b = e.update(mean: 0.25, highlights: 0.002, subjectMean: 0.25) { changes.append(b) } }
    check(e.bias == 0, "exposure: releases when the scene gets darker", "\(changes)")

    var f = ExposureDecider()
    for _ in 0..<8 { _ = f.update(mean: 0.55, highlights: 0.25, subjectMean: 0.2) }
    check(f.bias == 0, "exposure: backlit dark subject is not darkened further")

    var g = ExposureDecider()
    for _ in 0..<8 { _ = g.update(mean: 0.6, highlights: 0.2, subjectMean: 0.6) }
    for _ in 0..<8 { _ = g.update(mean: 0.5, highlights: 0.08, subjectMean: 0.25) }
    check(g.bias == 0, "exposure: releases if the subject becomes too dark")

    var h = ExposureDecider()
    for _ in 0..<3 { _ = h.update(mean: 0.6, highlights: 0.2, subjectMean: 0.6) }
    check(h.bias == 0, "exposure: needs several frames before changing")
}

// MARK: Composition

do {
    let noRoll = Composition.evaluate(roll: nil, box: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), distance: 0.0)
    check(noRoll?.criteria.contains(where: { $0.name == "Orizzonte" }) == false, "score: unknown horizon is left out")
    let edge = Composition.evaluate(roll: 0, box: CGRect(x: 0.0, y: 0.4, width: 0.2, height: 0.2), distance: 0.0)
    check(edge?.criteria.first(where: { $0.name == "Bordi" })?.ok == false, "score: subject touching the edge is flagged")
    let good = Composition.evaluate(roll: 0.01, box: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3), distance: 0.02)
    check(good?.value == 100 && good?.word == "Ottima", "score: lined up and level", "\(good?.value ?? -1)")
    let tilted = Composition.evaluate(roll: 0.2, box: CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3), distance: 0.02)
    check((tilted?.value ?? 100) < (good?.value ?? 0), "score: tilt lowers it", "\(tilted?.value ?? -1)")
    check((tilted?.value ?? 1) % 10 == 0, "score: shown in steps of 10")
    check(Composition.evaluate(roll: nil, box: nil, distance: nil) == nil, "score: nothing measured, nothing shown")
}

// MARK: Pose wording

do {
    // Person facing the camera: their left shoulder is on the right of the picture.
    var j: [Joint: CGPoint] = [
        .neck: CGPoint(x: 0.5, y: 0.7), .root: CGPoint(x: 0.5, y: 0.45), .nose: CGPoint(x: 0.5, y: 0.78),
        .lShoulder: CGPoint(x: 0.58, y: 0.7), .rShoulder: CGPoint(x: 0.42, y: 0.7),
        .lElbow: CGPoint(x: 0.6, y: 0.6), .rElbow: CGPoint(x: 0.4, y: 0.6)
    ]
    let up = CGFloat.pi / 2, down = -CGFloat.pi / 2
    let t1 = PoseMath.instruction(limb: .lForearm, user: down, ref: up, joints: j, facing: true)
    check(t1 == "Alza la mano sinistra", "pose: facing camera, person's left arm", t1)
    let t2 = PoseMath.instruction(limb: .rForearm, user: up, ref: down, joints: j, facing: true)
    check(t2 == "Abbassa la mano destra", "pose: facing camera, person's right arm", t2)
    // Seen from behind, left and right swap on the picture.
    j[.lShoulder] = CGPoint(x: 0.42, y: 0.7); j[.rShoulder] = CGPoint(x: 0.58, y: 0.7)
    j[.lElbow] = CGPoint(x: 0.4, y: 0.6)
    let t3 = PoseMath.instruction(limb: .lForearm, user: down, ref: up, joints: j, facing: false)
    check(t3 == "Alza la mano sinistra", "pose: from behind, person's left arm", t3)

    let pose = PoseMath.library[0].angles
    let same = PoseMath.compare(user: pose, ref: pose)
    check(same.matched && same.score > 0.99, "pose: identical pose matches")
    var bent = pose
    bent[.lForearm] = (bent[.lForearm] ?? 0) + 0.9
    let off = PoseMath.compare(user: bent, ref: pose)
    check(!off.matched && off.worst == .lForearm, "pose: one wrong limb is the one corrected", "\(String(describing: off.worst))")
    var slightly = pose
    for (k, v) in slightly { slightly[k] = v + 0.2 }  // about 11°: different build or stance
    check(PoseMath.compare(user: slightly, ref: pose).matched, "pose: small differences are tolerated")
}

// MARK: Body framing

do {
    let full: [Joint: CGPoint] = [
        .nose: CGPoint(x: 0.5, y: 0.85), .neck: CGPoint(x: 0.5, y: 0.8), .root: CGPoint(x: 0.5, y: 0.5),
        .lAnkle: CGPoint(x: 0.52, y: 0.1), .rAnkle: CGPoint(x: 0.48, y: 0.1)
    ]
    check(BodyFraming.issue(step: .full, joints: full, selfie: false) == nil, "framing: full figure is fine")
    var noFeet = full
    noFeet[.lAnkle] = nil; noFeet[.rAnkle] = nil
    let msg = BodyFraming.issue(step: .full, joints: noFeet, selfie: false)
    check(msg?.audience == .photographer && msg?.text.contains("piedi") == true, "framing: no feet asks the photographer", msg?.text ?? "-")
    let half: [Joint: CGPoint] = [.nose: CGPoint(x: 0.5, y: 0.86), .neck: CGPoint(x: 0.5, y: 0.78), .root: CGPoint(x: 0.5, y: 0.18)]
    check(BodyFraming.issue(step: .half, joints: half, selfie: false) == nil, "framing: half-length does not need feet")
    let farHalf = BodyFraming.issue(step: .half, joints: noFeet, selfie: false)
    check(farHalf?.text == "Avvicinati alla persona", "framing: half-length too small asks to get closer", farHalf?.text ?? "-")
    var left = full
    left[.root] = CGPoint(x: 0.2, y: 0.5)
    check(BodyFraming.issue(step: .full, joints: left, selfie: true)?.text == "Spostati un po' alla tua sinistra", "framing: selfie side uses the person's own left")
    check(BodyFraming.issue(step: .shoes, joints: [:], selfie: false) == nil, "framing: detail shots need no body")
}

// MARK: Looks

let ctx = Grade.context
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func card(width w: CGFloat, height h: CGFloat) -> CIImage {
    let all = CGRect(x: 0, y: 0, width: w, height: h)
    var img = CIImage(color: CIColor(red: 0.45, green: 0.47, blue: 0.5)).cropped(to: all)
    // Sky: top third, blue to nearly white
    let sky = CIFilter.linearGradient()
    sky.point0 = CGPoint(x: 0, y: h)
    sky.point1 = CGPoint(x: 0, y: h * 0.66)
    sky.color0 = CIColor(red: 0.35, green: 0.6, blue: 0.95)
    sky.color1 = CIColor(red: 0.97, green: 0.97, blue: 0.98)
    if let s = sky.outputImage?.cropped(to: CGRect(x: 0, y: h * 0.66, width: w, height: h * 0.34)) { img = s.composited(over: img) }
    // Skin patches across the middle
    let skins: [CIColor] = [CIColor(red: 0.96, green: 0.80, blue: 0.69), CIColor(red: 0.87, green: 0.67, blue: 0.53),
                            CIColor(red: 0.70, green: 0.50, blue: 0.36), CIColor(red: 0.45, green: 0.30, blue: 0.22)]
    for (i, c) in skins.enumerated() {
        let r = CGRect(x: w * CGFloat(i) / 4, y: h * 0.36, width: w / 4, height: h * 0.28)
        img = CIImage(color: c).cropped(to: r).composited(over: img)
    }
    // Grey ramp at the bottom
    let ramp = CIFilter.linearGradient()
    ramp.point0 = CGPoint(x: 0, y: 0)
    ramp.point1 = CGPoint(x: w, y: 0)
    ramp.color0 = CIColor(red: 0, green: 0, blue: 0)
    ramp.color1 = CIColor(red: 1, green: 1, blue: 1)
    if let r = ramp.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: w, height: h * 0.3)) { img = r.composited(over: img) }
    return img.cropped(to: all)
}

func pixels(_ image: CIImage) -> [Float] {
    let e = image.extent
    let w = Int(e.width), h = Int(e.height)
    var buf = [Float](repeating: 0, count: w * h * 4)
    ctx.render(image, toBitmap: &buf, rowBytes: w * 16, bounds: e, format: .RGBAf, colorSpace: sRGB)
    return buf
}

func blocks(_ image: CIImage, cols: Int, rows: Int) -> [Double] {
    let e = image.extent
    var out: [Double] = []
    for r in 0..<rows {
        for c in 0..<cols {
            let rect = CGRect(x: e.minX + e.width * CGFloat(c) / CGFloat(cols), y: e.minY + e.height * CGFloat(r) / CGFloat(rows),
                              width: e.width / CGFloat(cols), height: e.height / CGFloat(rows))
            let a = Grade.average(image, rect: rect)
            out.append(Double(a.r)); out.append(Double(a.g)); out.append(Double(a.b))
        }
    }
    return out
}

func savePNG(_ image: CIImage, _ name: String) {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    try? ctx.writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: sRGB)
}

do {
    let small = card(width: 400, height: 500)
    let big = card(width: 1600, height: 2000)
    savePNG(small, "card-original.png")

    let original = pixels(small)
    let zero = pixels(Grade.render(small, look: Grade.look("teal"), intensity: 0))
    check(zero == original, "look: intensity 0 gives back the original exactly")

    let grained = pixels(Grade.grain(small, 0.045))
    var maxDiff: Float = 0
    var sumDiff: Float = 0
    for i in stride(from: 0, to: original.count, by: 4) {
        let d = abs(grained[i] - original[i])
        maxDiff = max(maxDiff, d)
        sumDiff += d
    }
    let meanDiff = sumDiff / Float(original.count / 4)
    check(maxDiff * 255 <= 12 && meanDiff * 255 <= 3, "grain: no pixel moves more than a few levels",
          String(format: "max %.1f, mean %.2f levels", maxDiff * 255, meanDiff * 255))

    for look in Grade.looks {
        let preview = Grade.render(small, look: look, intensity: 1)
        let full = Grade.render(big, look: look, intensity: 1)
        let fullDown = full.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
        let a = blocks(preview, cols: 8, rows: 10), b = blocks(fullDown, cols: 8, rows: 10)
        let worst = zip(a, b).map { abs($0 - $1) }.max() ?? 1
        check(worst < 0.04, "look \(look.id): preview matches the full-size photo", String(format: "worst block %.3f", worst))

        if look.protects {
            // All four skin patches, measured in their middle: close to the original and still skin-coloured
            // (red above green above blue), so no purple or green casts.
            var worstShift: CGFloat = 0
            var hueKept = true
            for i in 0..<4 {
                let r = CGRect(x: CGFloat(i) * 100 + 30, y: 210, width: 40, height: 80)
                let a = Grade.average(small, rect: r), g = Grade.average(preview, rect: r)
                worstShift = max(worstShift, abs(g.r - a.r), abs(g.g - a.g), abs(g.b - a.b))
                if !(g.r > g.g && g.g > g.b) { hueKept = false }
            }
            check(worstShift < 0.08, "look \(look.id): every skin tone stays close", String(format: "worst shift %.3f", worstShift))
            check(hueKept, "look \(look.id): skin keeps its hue (no purple or green cast)")
        }
        // Corners: darker is fine, black is not.
        let corner = Grade.average(preview, rect: CGRect(x: 0, y: 470, width: 30, height: 30))
        let cornerBefore = Grade.average(small, rect: CGRect(x: 0, y: 470, width: 30, height: 30))
        let centre = Grade.average(preview, rect: CGRect(x: 185, y: 470, width: 30, height: 30))
        let centreBefore = Grade.average(small, rect: CGRect(x: 185, y: 470, width: 30, height: 30))
        let cornerRatio = (corner.r + corner.g + corner.b + 0.01) / (cornerBefore.r + cornerBefore.g + cornerBefore.b + 0.01)
        let centreRatio = (centre.r + centre.g + centre.b + 0.01) / (centreBefore.r + centreBefore.g + centreBefore.b + 0.01)
        check(cornerRatio > centreRatio * 0.6, "look \(look.id): vignette stays gentle", String(format: "corner %.2f vs centre %.2f", cornerRatio, centreRatio))
        let skyRect = CGRect(x: 0, y: 470, width: 400, height: 30)
        let skyTop = Grade.average(preview, rect: CGRect(x: 0, y: 340, width: 400, height: 10))
        _ = skyRect
        check(skyTop.r < 0.995 || skyTop.g < 0.995, "look \(look.id): bright sky keeps some detail")
        savePNG(preview, "look-\(look.id).png")
        let half = Grade.render(small, look: look, intensity: 0.5)
        let mid = Grade.average(half, rect: small.extent), lo = Grade.average(small, rect: small.extent), hi = Grade.average(preview, rect: small.extent)
        let between = (min(lo.r, hi.r) - 0.01...max(lo.r, hi.r) + 0.01).contains(mid.r)
        check(between, "look \(look.id): 50% sits between original and full look")
    }

    for style in [1, 2] {
        let framed = Grade.framed(big, style: style)
        let e = framed.extent
        let side = max(big.extent.width, big.extent.height)
        let expectedW = big.extent.width + 2 * (side * 0.04).rounded()
        let expectedH = big.extent.height + (side * 0.04).rounded() + (side * 0.11).rounded()
        check(e.width == expectedW && e.height == expectedH && e.height > e.width, "frame \(style): keeps the photo's pixels and portrait orientation",
              "\(Int(e.width))x\(Int(e.height))")
        // The photo sits above the caption: its sky must be near the top of the card.
        let topBand = Grade.average(framed, rect: CGRect(x: e.width * 0.3, y: e.height - (side * 0.04) - 40, width: e.width * 0.4, height: 30))
        check(topBand.b > topBand.r, "frame \(style): photo is upright (sky at the top)")
        savePNG(Grade.scaled(framed, maxSide: 600), "frame-\(style).png")
    }

    let advice = Grade.recommend(Grade.scaled(small, maxSide: 220))
    check(!advice.reason.isEmpty && Grade.looks.contains(where: { $0.id == advice.id }), "advice: names a real look with a measured reason", advice.reason)
}

// MARK: Export of real files (orientation, mirroring, size, metadata)

func jpegData(_ image: CIImage, orientation: Int, lens: String) -> Data {
    let cg = ctx.createCGImage(image, from: image.extent)!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
    let props: [String: Any] = [
        kCGImagePropertyOrientation as String: orientation,
        kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifLensModel as String: lens]
    ]
    CGImageDestinationAddImage(dest, cg, props as CFDictionary)
    CGImageDestinationFinalize(dest)
    return out as Data
}

do {
    // Stored sideways (landscape pixels) with the sky on the left and orientation 6:
    // shown upright, the sky must end up at the top and the photo must be portrait.
    let upright = card(width: 300, height: 400)
    let sideways = upright.oriented(.right)                    // the pixels a phone stores for a portrait shot
    let raw = jpegData(sideways.transformed(by: CGAffineTransform(translationX: -sideways.extent.minX, y: -sideways.extent.minY)),
                       orientation: 6, lens: "TestLens")
    for (frame, label) in [(0, "no frame"), (1, "white frame")] {
        let out = Grade.export(raw, look: "teal", intensity: 1, frame: frame)
        let back = CIImage(data: out, options: [.applyOrientationProperty: true])!
        let e = back.extent
        check(e.height > e.width, "export (\(label)): rotated photo comes out portrait", "\(Int(e.width))x\(Int(e.height))")
        let top = Grade.average(back, rect: CGRect(x: e.width * 0.3, y: e.height * 0.9, width: e.width * 0.4, height: e.height * 0.05))
        check(top.b > top.r, "export (\(label)): sky at the top after re-opening the file")
        if frame == 0 {
            check(Int(e.width) == 300 && Int(e.height) == 400, "export: same pixel size as the original")
        }
        let src = CGImageSourceCreateWithData(out as CFData, nil)!
        let meta = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
        let exif = meta[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        check((exif[kCGImagePropertyExifLensModel as String] as? String) == "TestLens", "export (\(label)): EXIF kept")
        let orient = meta[kCGImagePropertyOrientation as String] as? Int ?? 1
        check(orient == 1, "export (\(label)): orientation tag reset to upright", "\(orient)")
    }

    // A mirrored selfie (orientation 2): a red mark on the left of the stored pixels must appear on the right.
    let plain = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 400))
    let mark = CIImage(color: CIColor(red: 0.9, green: 0.1, blue: 0.1)).cropped(to: CGRect(x: 0, y: 150, width: 60, height: 100))
    let mirroredRaw = jpegData(mark.composited(over: plain), orientation: 2, lens: "Front")
    let mout = CIImage(data: Grade.export(mirroredRaw, look: "clean", intensity: 1, frame: 0), options: [.applyOrientationProperty: true])!
    let right = Grade.average(mout, rect: CGRect(x: 250, y: 170, width: 40, height: 60))
    let left = Grade.average(mout, rect: CGRect(x: 10, y: 170, width: 40, height: 60))
    check(right.r > right.g + 0.3 && left.r < left.g + 0.1, "export: mirrored selfie keeps the mirror")

    let untouched = Grade.export(raw, look: "teal", intensity: 0, frame: 0)
    check(untouched == raw, "export: no look and no frame keeps the original file byte for byte")
}

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
