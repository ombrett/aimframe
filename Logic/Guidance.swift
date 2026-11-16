import CoreGraphics
import Foundation

// Pure decision logic for the camera guide. No UIKit, no AVFoundation: every function takes the
// time and the measurements as parameters, so the same code runs in the app and in the CI tests.

/// Who an instruction is meant for.
enum Audience: Equatable {
    case none          // status, nothing to do
    case photographer  // the person holding the phone
    case subject       // the person being photographed
}

/// How an instruction is shown: yellow = do something, green = condition met.
enum Tone: Equatable {
    case neutral, guide, good, warning
}

struct Instruction: Equatable {
    var text: String
    var audience: Audience = .none
    var tone: Tone = .neutral

    static func guide(_ text: String, for audience: Audience) -> Instruction {
        Instruction(text: text, audience: audience, tone: .guide)
    }
    static func good(_ text: String, for audience: Audience = .none) -> Instruction {
        Instruction(text: text, audience: audience, tone: .good)
    }
    static func info(_ text: String) -> Instruction {
        Instruction(text: text, audience: .none, tone: .neutral)
    }
    static func warning(_ text: String) -> Instruction {
        Instruction(text: text, audience: .none, tone: .warning)
    }
}

/// Keeps one instruction on screen until a different one has been asked for steadily for `hold` seconds,
/// so the guide does not flicker between opposite directions.
struct HintStabilizer {
    var hold: Double = 0.6
    private(set) var current: Instruction?
    private var candidate: Instruction?
    private var candidateSince: Double = 0

    /// `urgent` changes the instruction at once (lock reached, subject lost, countdown).
    mutating func update(_ next: Instruction, now: Double, urgent: Bool = false) -> Instruction {
        guard let shown = current, !urgent, next != shown else {
            current = next
            candidate = nil
            return next
        }
        if next != candidate {
            candidate = next
            candidateSince = now
        }
        if now - candidateSince >= hold {
            current = next
            candidate = nil
        }
        return current ?? shown
    }

    mutating func reset() {
        current = nil
        candidate = nil
    }
}

// MARK: - Aiming (landscape)

enum AimAxis: Equatable { case horizontal, vertical }

enum Aim {
    /// Inside this distance (fraction of the frame) an axis counts as lined up.
    static let deadZone: CGFloat = 0.035

    /// One instruction for the photographer. `dx`/`dy` say where the subject is compared with where it
    /// should be: dx > 0 the subject is too far right, dy > 0 too high (Vision coordinates, y up).
    /// The axis being corrected is kept until the other one is clearly worse, to avoid ping-pong.
    static func instruction(dx: CGFloat, dy: CGFloat, axis: inout AimAxis?) -> String? {
        let ax = abs(dx), ay = abs(dy)
        if ax < deadZone && ay < deadZone {
            axis = nil
            return nil
        }
        var chosen: AimAxis = ax >= ay ? .horizontal : .vertical
        if let previous = axis {
            let keep = previous == .horizontal ? ax >= deadZone && ay < ax * 1.6 : ay >= deadZone && ax < ay * 1.6
            if keep { chosen = previous }
        }
        axis = chosen
        let amount = chosen == .horizontal ? ax : ay
        let small = amount < 0.12
        switch chosen {
        case .horizontal:
            return (small ? "Sposta leggermente il telefono " : "Sposta il telefono ") + (dx > 0 ? "a destra" : "a sinistra")
        case .vertical:
            return dy > 0 ? (small ? "Alza leggermente il telefono" : "Alza il telefono")
                          : (small ? "Abbassa leggermente il telefono" : "Abbassa il telefono")
        }
    }
}

// MARK: - Automatic shot

/// Takes one photo when the framing has been right and the phone still for long enough.
/// After a shot it waits until the phone points somewhere else (by angle, not by shaking) before it can fire again.
struct AutoShot {
    var hold: Double = 1.0                  // seconds of "ready and steady" before the shot
    var rearmAngle: Double = 0.6            // radians away from where the last photo was taken (about 35°)

    private(set) var progress: Double?      // 0...1 while counting, nil otherwise
    private(set) var armed = true
    private(set) var cancelled = false
    private var readySince: Double?

    /// How far the phone now points from where it pointed at the last shot, in radians.
    /// Hand tremor goes back and forth around zero, so it never re-arms.
    mutating func observe(angleSinceShot: Double) {
        if !armed && angleSinceShot >= rearmAngle { armed = true }
    }

    /// Returns true exactly when the photo should be taken.
    mutating func update(now: Double, ready: Bool, steady: Bool, enabled: Bool) -> Bool {
        if !ready { cancelled = false }
        guard enabled, armed, !cancelled, ready, steady else {
            readySince = nil
            progress = nil
            return false
        }
        let start = readySince ?? now
        readySince = start
        let p = (now - start) / hold
        if p >= 1 {
            armed = false
            readySince = nil
            progress = nil
            return true
        }
        progress = max(0, p)
        return false
    }

    /// The user tapped "Annulla": no automatic shot until the framing is lost and found again.
    mutating func cancel() {
        cancelled = true
        readySince = nil
        progress = nil
    }

    /// A manual shot counts as a shot: wait for a new scene before shooting automatically.
    mutating func didShootManually() {
        armed = false
        readySince = nil
        progress = nil
    }

    mutating func reset() {
        armed = true
        cancelled = false
        readySince = nil
        progress = nil
    }
}

// MARK: - Exposure

/// Decides a small exposure correction from what the camera sees, with hysteresis so it does not
/// pump. When the sky is burnt but the subject is already dark, it does not darken further.
struct ExposureDecider {
    private(set) var bias: Float = 0
    private var pending: Float = 0
    private var votes = 0
    var votesNeeded = 4

    /// `mean` and `subjectMean` are 0...1 brightness, `highlights` the share of nearly white pixels.
    /// Returns the new bias only when it changes.
    mutating func update(mean: Double, highlights: Double, subjectMean: Double?) -> Float? {
        var want = bias
        if bias < 0 {
            let sceneDarker = highlights < 0.01 && mean < 0.35
            let subjectTooDark = (subjectMean ?? 1) < 0.3
            if sceneDarker || subjectTooDark { want = 0 }
        } else if bias > 0 {
            if highlights > 0.04 || mean > 0.45 { want = 0 }
        } else if highlights > 0.10 {
            // A burnt sky: darken only if the subject can afford it.
            want = (subjectMean ?? 0.5) < 0.35 ? 0 : -0.5
        } else if mean < 0.2 && highlights < 0.02 {
            want = 0.5
        }
        if want == pending { votes += 1 } else { pending = want; votes = 1 }
        guard votes >= votesNeeded, want != bias else { return nil }
        bias = want
        return want
    }

    mutating func reset() {
        bias = 0
        pending = 0
        votes = 0
    }

    var note: String {
        bias < 0 ? "Cielo molto luminoso: esposizione −\(String(format: "%.1f", -bias))"
            : (bias > 0 ? "Scena scura: esposizione +\(String(format: "%.1f", bias))" : "")
    }
}

// MARK: - Light

/// How much light the camera has, from the shutter time and ISO it chose. With little light the
/// photo comes out dark and noisy whatever the framing, so the app says so instead of "ready".
enum LightLevel: Equatable {
    case good, low, veryLow
}

enum LightCheck {
    /// `previous` adds hysteresis so the warning does not flicker at the threshold.
    static func level(iso: Double, seconds: Double, previous: LightLevel) -> LightLevel {
        let veryLowIn = iso >= 4000 || seconds >= 1.0 / 8
        let veryLowOut = iso < 3200 && seconds < 1.0 / 10
        let lowIn = iso >= 1600 || seconds >= 1.0 / 25
        let lowOut = iso < 1250 && seconds < 1.0 / 30
        switch previous {
        case .veryLow:
            if !veryLowOut { return .veryLow }
            return lowOut ? .good : .low
        case .low:
            if veryLowIn { return .veryLow }
            return lowOut ? .good : .low
        case .good:
            if veryLowIn { return .veryLow }
            return lowIn ? .low : .good
        }
    }

    static func advice(_ level: LightLevel) -> String? {
        switch level {
        case .good: return nil
        case .low: return "Poca luce: avvicinati a una finestra o accendi una luce"
        case .veryLow: return "Troppo buio: la foto verrà scura e mossa. Cerca più luce"
        }
    }
}

// MARK: - Composition indicator

struct Criterion: Equatable {
    let name: String
    let ok: Bool
}

struct CompositionResult: Equatable {
    let value: Int          // 0...100 in steps of 10
    let word: String
    let criteria: [Criterion]
}

enum Composition {
    /// Only measured things count; anything unknown is left out instead of counted as perfect.
    /// - roll: tilt of the phone in radians (nil when it is pointing steeply up or down)
    /// - box: the subject, 0...1 coordinates (nil when there is none)
    /// - distance: how far the subject is from its target point, 0...1 (nil when unknown)
    static func evaluate(roll: Double?, box: CGRect?, distance: CGFloat?, light: LightLevel? = nil) -> CompositionResult? {
        var parts: [(weight: Double, score: Double)] = []
        var criteria: [Criterion] = []
        if let l = light {
            parts.append((0.25, l == .good ? 1 : (l == .low ? 0.5 : 0.1)))
            criteria.append(Criterion(name: "Luce", ok: l == .good))
        }
        if let d = distance {
            let s = max(0, 1 - Double(d) / 0.3)
            parts.append((0.5, s))
            criteria.append(Criterion(name: "Posizione", ok: d < 0.06))
        }
        if let b = box {
            let margin = min(b.minX, b.minY, 1 - b.maxX, 1 - b.maxY)
            let s = margin < 0.015 ? 0.3 : 1
            parts.append((0.25, s))
            criteria.append(Criterion(name: "Bordi", ok: margin >= 0.015))
        }
        if let r = roll {
            let tilt = abs(r)
            let s = max(0, min(1, 1 - (tilt - 0.026) / 0.15))
            parts.append((0.25, s))
            criteria.append(Criterion(name: "Orizzonte", ok: tilt < 0.035))
        }
        guard !parts.isEmpty else { return nil }
        let total = parts.reduce(0) { $0 + $1.weight }
        let raw = parts.reduce(0) { $0 + $1.weight * $1.score } / total
        let value = Int((raw * 10).rounded()) * 10
        // It measures framing and light, not whether the scene is beautiful: the words say only that.
        let word = value >= 80 ? "ok" : (value >= 60 ? "quasi" : "da sistemare")
        return CompositionResult(value: value, word: word, criteria: criteria)
    }
}

// MARK: - Carousel

/// The shots of an Instagram carousel, in order.
enum CarouselStep: Int, CaseIterable {
    case full, half, shoes, accessories

    var title: String {
        switch self {
        case .full: return "Outfit completo"
        case .half: return "Mezzo busto"
        case .shoes: return "Scarpe"
        case .accessories: return "Accessori"
        }
    }

    var tip: String {
        switch self {
        case .full: return "Dalla testa ai piedi, con un po' di spazio sopra e sotto"
        case .half: return "Dalla testa alla vita"
        case .shoes: return "Avvicinati alle scarpe e riempi il riquadro"
        case .accessories: return "Avvicinati a borsa, gioielli o mani e riempi il riquadro"
        }
    }

    /// Detail shots have no full body to detect: they use a fixed framing guide and the manual shutter.
    var usesBody: Bool { self == .full || self == .half }
}

enum BodyFraming {
    /// Joints in Vision coordinates (0...1, y up). Returns nil when the framing is right.
    /// Instructions are for whoever holds the phone (`selfie` = the person is holding it).
    static func issue(step: CarouselStep, joints: [Joint: CGPoint], selfie: Bool) -> Instruction? {
        guard step.usesBody else { return nil }
        guard let neck = joints[.neck] else {
            return .guide(selfie ? "Mettiti davanti alla fotocamera" : "Inquadra la persona", for: .photographer)
        }
        let top = joints[.nose]?.y ?? neck.y
        let mover: Audience = .photographer
        switch step {
        case .full:
            let ankles = [joints[.lAnkle], joints[.rAnkle]].compactMap { $0 }
            guard let bottom = ankles.map({ $0.y }).min() else {
                return .guide(selfie ? "Allontana il telefono: non vedo i piedi" : "Allontanati: non vedo i piedi", for: mover)
            }
            if bottom < 0.04 { return .guide(selfie ? "Allontana il telefono: i piedi sono al bordo" : "Allontanati: i piedi sono al bordo", for: mover) }
            if top > 0.92 { return .guide(selfie ? "Allontana il telefono: la testa è al bordo" : "Allontanati: la testa è al bordo", for: mover) }
            if top - bottom < 0.5 { return .guide(selfie ? "Avvicina il telefono" : "Avvicinati alla persona", for: mover) }
        case .half:
            guard let root = joints[.root] else {
                return .guide(selfie ? "Allontana il telefono: non vedo la vita" : "Allontanati: non vedo la vita", for: mover)
            }
            if top > 0.92 { return .guide(selfie ? "Allontana il telefono: la testa è al bordo" : "Allontanati: la testa è al bordo", for: mover) }
            if root.y < 0.03 { return .guide("Abbassa leggermente il telefono", for: mover) }
            if top - root.y < 0.45 { return .guide(selfie ? "Avvicina il telefono" : "Avvicinati alla persona", for: mover) }
        case .shoes, .accessories:
            return nil
        }
        let centre = joints[.root]?.x ?? neck.x
        if centre < 0.3 || centre > 0.7 {
            if selfie {
                // Unmirrored front-camera picture: the person's own left is on the right of the picture,
                // so someone too far to the picture's left has drifted to their own right.
                return .guide(centre < 0.3 ? "Spostati un po' alla tua sinistra" : "Spostati un po' alla tua destra", for: .subject)
            }
            // The person is off to one side of the picture: turn the phone towards them.
            return .guide(centre < 0.3 ? "Sposta il telefono a sinistra" : "Sposta il telefono a destra", for: mover)
        }
        return nil
    }
}
