import SwiftUI

/// The live picture with everything drawn on it. 3:4 like the sensor and the saved photo,
/// so what is drawn here lines up with the photo.
struct Viewfinder: View {
    @ObservedObject var cam: CameraModel
    @GestureState private var drag: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1

    private var guideActive: Bool {
        cam.mode == .outfit && cam.selectedPoseID == "import"
            && ((cam.guideStyle == 0 && cam.referenceImage != nil) || (cam.guideStyle == 1 && cam.silhouette != nil))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                CameraPreview(session: cam.session)
                Overlay(cam: cam, size: geo.size, liveOffset: drag, liveScale: pinch)
                pills
                if cam.flash { Color.white.opacity(0.75).allowsHitTesting(false) }
            }
            .contentShape(Rectangle())
            .gesture(guideGesture(size: geo.size), including: guideActive ? .all : .subviews)
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
    }

    private func guideGesture(size: CGSize) -> some Gesture {
        let move = DragGesture()
            .updating($drag) { value, state, _ in state = value.translation }
            .onEnded { value in
                cam.guideOffset = CGSize(width: cam.guideOffset.width + value.translation.width / size.width,
                                         height: cam.guideOffset.height + value.translation.height / size.height)
            }
        let zoom = MagnificationGesture()
            .updating($pinch) { value, state, _ in state = value }
            .onEnded { value in cam.guideScale = min(max(cam.guideScale * value, 0.4), 3) }
        return move.simultaneously(with: zoom)
    }

    // MARK: Labels over the picture

    private var pills: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top) {
                if cam.mode == .landscape, cam.phase == .guiding || cam.phase == .locked, !cam.label.isEmpty {
                    Pill(text: cam.phase == .locked ? "\(cam.label) · Pronto" : cam.label,
                         color: cam.phase == .locked ? Theme.green : Theme.ivory,
                         symbol: cam.phase == .locked ? "checkmark.circle.fill" : "viewfinder")
                }
                Spacer()
                if cam.mode == .landscape, let c = cam.composition { CompositionBadge(result: c) }
            }
            Spacer()
            if !cam.systemNote.isEmpty {
                Pill(text: cam.systemNote, color: Theme.red, symbol: "exclamationmark.triangle.fill")
            }
            if let toast = cam.toast {
                Pill(text: toast, color: Theme.ivory)
                    .transition(.opacity)
            } else {
                if !cam.lightNote.isEmpty { Pill(text: cam.lightNote, color: Theme.yellow, symbol: "sun.max.fill") }
                if !cam.exposureText.isEmpty {
                    Text(cam.exposureText)
                        .font(Theme.small(11))
                        .monospacedDigit()
                        .foregroundColor(Theme.ivoryDim)
                }
            }
        }
        .padding(10)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: cam.toast)
    }
}

/// The composition indicator: a coarse value and the criteria actually measured.
struct CompositionBadge: View {
    let result: CompositionResult

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("Composizione \(result.word.lowercased())")
                .font(Theme.small(11))
                .foregroundColor(result.value >= 80 ? Theme.green : (result.value >= 60 ? Theme.yellow : Theme.ivory))
            HStack(spacing: 6) {
                ForEach(result.criteria, id: \.name) { c in
                    HStack(spacing: 2) {
                        Image(systemName: c.ok ? "checkmark" : "exclamationmark")
                        Text(c.name)
                    }
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(c.ok ? Theme.green : Theme.yellow)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Composizione \(result.word): " + result.criteria.map { "\($0.name) \($0.ok ? "ok" : "da sistemare")" }.joined(separator: ", "))
    }
}

/// Everything drawn on the picture.
private struct Overlay: View {
    @ObservedObject var cam: CameraModel
    let size: CGSize
    let liveOffset: CGSize
    let liveScale: CGFloat

    var body: some View {
        let w = size.width, h = size.height
        ZStack {
            if cam.showGrid { grid(w, h) }
            if let roll = cam.roll { level(roll, w, h) }

            switch cam.mode {
            case .landscape: landscape(w, h)
            case .outfit: outfit(w, h)
            case .carousel: carousel(w, h)
            }
        }
        .frame(width: w, height: h)
        .allowsHitTesting(false)
    }

    private func grid(_ w: CGFloat, _ h: CGFloat) -> some View {
        Path { p in
            for i in 1..<3 {
                let f = CGFloat(i) / 3
                p.move(to: CGPoint(x: w * f, y: 0)); p.addLine(to: CGPoint(x: w * f, y: h))
                p.move(to: CGPoint(x: 0, y: h * f)); p.addLine(to: CGPoint(x: w, y: h * f))
            }
        }
        .stroke(Theme.ivory.opacity(0.18), lineWidth: 1)
    }

    /// Stays flat with the horizon while the phone rolls; green when the phone is level.
    private func level(_ roll: Double, _ w: CGFloat, _ h: CGFloat) -> some View {
        let flat = abs(roll) < 0.035
        return Path { p in
            p.move(to: CGPoint(x: -w * 0.18, y: 0)); p.addLine(to: CGPoint(x: -w * 0.04, y: 0))
            p.move(to: CGPoint(x: w * 0.04, y: 0)); p.addLine(to: CGPoint(x: w * 0.18, y: 0))
        }
        .stroke(flat ? Theme.green : Theme.ivory.opacity(0.7), style: StrokeStyle(lineWidth: flat ? 2 : 1.5, lineCap: .round))
        .rotationEffect(.radians(-roll), anchor: .topLeading)
        .offset(x: w / 2, y: h / 2)
        .animation(.easeOut(duration: 0.12), value: roll)
    }

    @ViewBuilder
    private func landscape(_ w: CGFloat, _ h: CGFloat) -> some View {
        if let box = cam.subjectBox, cam.phase == .guiding || cam.phase == .locked {
            let locked = cam.phase == .locked
            let color = locked ? Theme.green : Theme.yellow
            let tx = cam.target.x * w, ty = cam.target.y * h
            let cx = box.midX * w, cy = box.midY * h
            ZStack {
                if !locked {
                    Path { p in p.move(to: CGPoint(x: cx, y: cy)); p.addLine(to: CGPoint(x: tx, y: ty)) }
                        .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                }
                Circle()
                    .fill(color)
                    .frame(width: 12, height: 12)
                    .position(x: tx, y: ty)
                Brackets()
                    .stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                    .frame(width: box.width * w, height: box.height * h)
                    .position(x: cx, y: cy)
            }
            .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.85), value: box)
        }
    }

    @ViewBuilder
    private func outfit(_ w: CGFloat, _ h: CGFloat) -> some View {
        let importOn = cam.selectedPoseID == "import"
        let showPhoto = importOn && cam.guideStyle == 0 && cam.referenceImage != nil
        let showShape = importOn && cam.guideStyle == 1 && cam.silhouette != nil
        let mirrored = cam.isFront != cam.guideFlipped
        let scale = cam.guideScale * liveScale
        let dx = cam.guideOffset.width * w + liveOffset.width
        let dy = cam.guideOffset.height * h + liveOffset.height
        ZStack {
            if showPhoto, let photo = cam.referenceImage {
                guideImage(photo, w, h, mirrored: mirrored, scale: scale, dx: dx, dy: dy).opacity(cam.guideOpacity)
            }
            if showShape, let shape = cam.silhouette {
                guideImage(shape, w, h, mirrored: mirrored, scale: scale, dx: dx, dy: dy).opacity(cam.poseMatched ? 0.45 : max(cam.guideOpacity, 0.6))
            }
            if !showPhoto && !showShape && !cam.ghost.isEmpty {
                skeleton(cam.ghost, w, h)
                    .stroke((cam.poseMatched ? Theme.green : Theme.yellow).opacity(0.85),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            skeleton(cam.body, w, h)
                .stroke(Theme.ivory.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            ForEach(Array(cam.body.keys), id: \.self) { j in
                if let p = cam.body[j] {
                    Circle().fill(Theme.ivory).frame(width: 5, height: 5).position(x: p.x * w, y: p.y * h)
                }
            }
            if let n = cam.countdown {
                Text("\(n)")
                    .font(.system(size: 110, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.ivory)
                    .shadow(color: .black.opacity(0.6), radius: 10)
                    .transition(.scale.combined(with: .opacity))
                    .id(n)
            }
        }
        .animation(.easeOut(duration: 0.2), value: cam.countdown)
    }

    private func guideImage(_ image: UIImage, _ w: CGFloat, _ h: CGFloat, mirrored: Bool, scale: CGFloat, dx: CGFloat, dy: CGFloat) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: w, height: h)
            .scaleEffect(x: mirrored ? -scale : scale, y: scale)
            .offset(x: dx, y: dy)
            .frame(width: w, height: h)
            .clipped()
    }

    @ViewBuilder
    private func carousel(_ w: CGFloat, _ h: CGFloat) -> some View {
        if cam.carouselStep.usesBody {
            skeleton(cam.body, w, h)
                .stroke((cam.carouselReady ? Theme.green : Theme.ivory).opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        } else {
            // Detail shots: a fixed frame to fill, no body detection.
            Brackets(length: 0.18)
                .stroke(Theme.yellow, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                .frame(width: w * 0.72, height: h * 0.6)
                .position(x: w / 2, y: h / 2)
        }
    }

    private func skeleton(_ joints: [Joint: CGPoint], _ w: CGFloat, _ h: CGFloat) -> Path {
        var path = Path()
        for (a, b) in PoseMath.bones {
            guard let pa = joints[a], let pb = joints[b] else { continue }
            path.move(to: CGPoint(x: pa.x * w, y: pa.y * h))
            path.addLine(to: CGPoint(x: pb.x * w, y: pb.y * h))
        }
        return path
    }
}
