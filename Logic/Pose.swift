import CoreGraphics
import Foundation

/// Body points the outfit mode works with. "l" and "r" are the labels Vision gives.
enum Joint: String, CaseIterable {
    case nose, neck, lShoulder, rShoulder, lElbow, rElbow, lWrist, rWrist
    case lHip, rHip, lKnee, rKnee, lAnkle, rAnkle, root
}

/// A pose is described by the direction of each limb, so it does not depend on body size or distance.
enum Limb: String, CaseIterable {
    case torso, head, lUpperArm, lForearm, rUpperArm, rForearm, lThigh, lShin, rThigh, rShin

    var ends: (Joint, Joint) {
        switch self {
        case .torso: return (.root, .neck)
        case .head: return (.neck, .nose)
        case .lUpperArm: return (.lShoulder, .lElbow)
        case .lForearm: return (.lElbow, .lWrist)
        case .rUpperArm: return (.rShoulder, .rElbow)
        case .rForearm: return (.rElbow, .rWrist)
        case .lThigh: return (.lHip, .lKnee)
        case .lShin: return (.lKnee, .lAnkle)
        case .rThigh: return (.rHip, .rKnee)
        case .rShin: return (.rKnee, .rAnkle)
        }
    }

    var mirrored: Limb {
        switch self {
        case .torso: return .torso
        case .head: return .head
        case .lUpperArm: return .rUpperArm
        case .lForearm: return .rForearm
        case .rUpperArm: return .lUpperArm
        case .rForearm: return .lForearm
        case .lThigh: return .rThigh
        case .lShin: return .rShin
        case .rThigh: return .lThigh
        case .rShin: return .lShin
        }
    }
}

/// A pose to copy: the angle of each limb in radians (0 = towards the right of the picture, 90° = up).
struct RefPose: Identifiable, Equatable {
    let id: String
    let name: String
    let angles: [Limb: CGFloat]
}

struct PoseComparison {
    var score: CGFloat = 0          // 0...1
    var worst: Limb?
    var worstDiff: CGFloat = 0
    var count = 0
    var matched = false
}

enum PoseMath {

    static let bones: [(Joint, Joint)] = [
        (.neck, .nose), (.neck, .lShoulder), (.neck, .rShoulder),
        (.lShoulder, .lElbow), (.lElbow, .lWrist), (.rShoulder, .rElbow), (.rElbow, .rWrist),
        (.neck, .root), (.root, .lHip), (.root, .rHip),
        (.lHip, .lKnee), (.lKnee, .lAnkle), (.rHip, .rKnee), (.rKnee, .rAnkle)
    ]

    /// How far off a limb may be and still count as matching.
    static let tolerance: CGFloat = 28 * .pi / 180

    static func wrap(_ a: CGFloat) -> CGFloat {
        var x = a
        while x > .pi { x -= 2 * .pi }
        while x <= -.pi { x += 2 * .pi }
        return x
    }

    /// `joints` are 0...1 with the origin at the bottom left; `aspect` is picture width / height.
    static func angles(_ joints: [Joint: CGPoint], aspect: CGFloat) -> [Limb: CGFloat] {
        var out: [Limb: CGFloat] = [:]
        for limb in Limb.allCases {
            let (a, b) = limb.ends
            guard let pa = joints[a], let pb = joints[b] else { continue }
            let dx = (pb.x - pa.x) * aspect, dy = pb.y - pa.y
            if dx * dx + dy * dy < 1e-6 { continue }
            out[limb] = atan2(dy, dx)
        }
        return out
    }

    static func mirror(_ angles: [Limb: CGFloat]) -> [Limb: CGFloat] {
        var out: [Limb: CGFloat] = [:]
        for (limb, a) in angles { out[limb.mirrored] = wrap(.pi - a) }
        return out
    }

    static func compare(user: [Limb: CGFloat], ref: [Limb: CGFloat]) -> PoseComparison {
        var result = PoseComparison()
        var total: CGFloat = 0
        var allWithin = true
        for (limb, r) in ref {
            guard let u = user[limb] else { continue }
            let diff = abs(wrap(u - r))
            total += max(0, 1 - diff / (CGFloat.pi / 3))
            result.count += 1
            if diff > tolerance { allWithin = false }
            if diff > result.worstDiff {
                result.worstDiff = diff
                result.worst = limb
            }
        }
        guard result.count > 0 else { return result }
        result.score = total / CGFloat(result.count)
        result.matched = allWithin && result.count >= 6
        return result
    }

    /// The reference pose drawn on the person's own body: same hips and limb lengths, the reference's directions.
    static func ghost(joints: [Joint: CGPoint], ref: [Limb: CGFloat], aspect: CGFloat) -> [Joint: CGPoint] {
        guard let root = joints[.root], let neck = joints[.neck] else { return [:] }
        func metric(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * aspect, y: p.y) }
        func unmetric(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / aspect, y: p.y) }
        func length(_ a: Joint, _ b: Joint, fallback: CGFloat) -> CGFloat {
            guard let pa = joints[a], let pb = joints[b] else { return fallback }
            let ma = metric(pa), mb = metric(pb)
            return max(hypot(mb.x - ma.x, mb.y - ma.y), 0.01)
        }
        func step(from p: CGPoint, limb: Limb, length: CGFloat, fallbackAngle: CGFloat) -> CGPoint {
            let a = ref[limb] ?? fallbackAngle
            return CGPoint(x: p.x + cos(a) * length, y: p.y + sin(a) * length)
        }

        let mRoot = metric(root), mNeck = metric(neck)
        let torso = max(hypot(mNeck.x - mRoot.x, mNeck.y - mRoot.y), 0.02)
        var m: [Joint: CGPoint] = [:]
        m[.root] = mRoot
        let gNeck = step(from: mRoot, limb: .torso, length: torso, fallbackAngle: .pi / 2)
        m[.neck] = gNeck
        let shift = CGPoint(x: gNeck.x - mNeck.x, y: gNeck.y - mNeck.y)
        m[.nose] = step(from: gNeck, limb: .head, length: length(.neck, .nose, fallback: torso * 0.35), fallbackAngle: .pi / 2)

        let arms: [(Joint, Joint, Joint, Limb, Limb)] = [
            (.lShoulder, .lElbow, .lWrist, .lUpperArm, .lForearm),
            (.rShoulder, .rElbow, .rWrist, .rUpperArm, .rForearm)
        ]
        for (s, e, w, upper, fore) in arms {
            guard let sh = joints[s] else { continue }
            let ms = metric(sh)
            let gs = CGPoint(x: ms.x + shift.x, y: ms.y + shift.y)
            m[s] = gs
            let ge = step(from: gs, limb: upper, length: length(s, e, fallback: torso * 0.55), fallbackAngle: -.pi / 2)
            m[e] = ge
            m[w] = step(from: ge, limb: fore, length: length(e, w, fallback: torso * 0.5), fallbackAngle: -.pi / 2)
        }
        let legs: [(Joint, Joint, Joint, Limb, Limb)] = [
            (.lHip, .lKnee, .lAnkle, .lThigh, .lShin),
            (.rHip, .rKnee, .rAnkle, .rThigh, .rShin)
        ]
        for (h, k, a, thigh, shin) in legs {
            guard let hip = joints[h] else { continue }
            let mh = metric(hip)
            m[h] = mh
            let gk = step(from: mh, limb: thigh, length: length(h, k, fallback: torso * 0.8), fallbackAngle: -.pi / 2)
            m[k] = gk
            m[a] = step(from: gk, limb: shin, length: length(k, a, fallback: torso * 0.8), fallbackAngle: -.pi / 2)
        }

        var out: [Joint: CGPoint] = [:]
        for (j, p) in m { out[j] = unmetric(p) }
        return out
    }

    /// One spoken correction for the limb that is furthest off, in the person's own left and right.
    static func instruction(limb: Limb, user u: CGFloat, ref r: CGFloat, joints: [Joint: CGPoint], facing: Bool) -> String {
        let dx = cos(r) - cos(u), dy = sin(r) - sin(u)
        let midX = ((joints[.lShoulder]?.x ?? 0.5) + (joints[.rShoulder]?.x ?? 0.5)) / 2
        let startX = joints[limb.ends.0]?.x ?? midX
        let onPictureRight = startX > midX
        // Someone facing the camera has their left side on the right of the picture.
        let personLeft = facing ? onPictureRight : !onPictureRight

        switch limb {
        case .torso, .head:
            let towardsPictureRight = dx > 0
            let towardsPersonLeft = facing ? towardsPictureRight : !towardsPictureRight
            let part = limb == .torso ? "il busto" : "la testa"
            return "Inclina \(part) verso la tua \(towardsPersonLeft ? "sinistra" : "destra")"
        default:
            let part: String
            switch limb {
            case .lUpperArm, .rUpperArm: part = "il gomito \(personLeft ? "sinistro" : "destro")"
            case .lForearm, .rForearm: part = "la mano \(personLeft ? "sinistra" : "destra")"
            case .lThigh, .rThigh: part = "il ginocchio \(personLeft ? "sinistro" : "destro")"
            default: part = "il piede \(personLeft ? "sinistro" : "destro")"
            }
            if abs(dy) >= abs(dx) { return (dy > 0 ? "Alza " : "Abbassa ") + part }
            let outward: CGFloat = onPictureRight ? 1 : -1
            return (dx * outward > 0 ? "Allarga " : "Avvicina al corpo ") + part
        }
    }

    // MARK: Built-in poses (person facing the camera; angles in degrees, approximate)

    private static func pose(_ id: String, _ name: String, _ deg: [Limb: CGFloat]) -> RefPose {
        var a: [Limb: CGFloat] = [:]
        for (l, d) in deg { a[l] = d * .pi / 180 }
        return RefPose(id: id, name: name, angles: a)
    }

    static let library: [RefPose] = [
        pose("tasca", "Mano in tasca", [
            .torso: 90, .head: 90,
            .lUpperArm: -75, .lForearm: -110, .rUpperArm: -100, .rForearm: -95,
            .lThigh: -80, .lShin: -95, .rThigh: -92, .rShin: -90
        ]),
        pose("fianco", "Mano sul fianco", [
            .torso: 90, .head: 90,
            .lUpperArm: -40, .lForearm: -150, .rUpperArm: -100, .rForearm: -95,
            .lThigh: -85, .lShin: -90, .rThigh: -95, .rShin: -90
        ]),
        pose("capelli", "Mano tra i capelli", [
            .torso: 90, .head: 95,
            .lUpperArm: -80, .lForearm: -85, .rUpperArm: 135, .rForearm: 30,
            .lThigh: -85, .lShin: -90, .rThigh: -95, .rShin: -90
        ]),
        pose("passo", "Passo in avanti", [
            .torso: 90, .head: 90,
            .lUpperArm: -95, .lForearm: -100, .rUpperArm: -85, .rForearm: -75,
            .lThigh: -75, .lShin: -100, .rThigh: -105, .rShin: -80
        ]),
        pose("incrociate", "Gambe incrociate", [
            .torso: 90, .head: 90,
            .lUpperArm: -80, .lForearm: -105, .rUpperArm: -100, .rForearm: -75,
            .lThigh: -100, .lShin: -105, .rThigh: -88, .rShin: -85
        ]),
        pose("conserte", "Braccia conserte", [
            .torso: 90, .head: 90,
            .lUpperArm: -85, .lForearm: 175, .rUpperArm: -95, .rForearm: 5,
            .lThigh: -85, .lShin: -90, .rThigh: -95, .rShin: -90
        ])
    ]
}
