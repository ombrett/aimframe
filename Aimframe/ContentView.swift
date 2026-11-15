import PhotosUI
import SwiftUI

private let aimColor = Color(red: 1.0, green: 0.77, blue: 0.24)
private let lockColor = Color(red: 0.34, green: 0.89, blue: 0.54)
private let panelColor = Color(white: 0.11)

struct ContentView: View {
    @StateObject private var cam = CameraModel()
    @State private var pickerItem: PhotosPickerItem?

    private var guideColor: Color { cam.phase == .locked ? lockColor : aimColor }

    private var hintColor: Color {
        if cam.mode == .outfit {
            return cam.poseMatched ? lockColor : (cam.selectedPoseID == "free" && cam.ghost.isEmpty ? Color(white: 0.8) : aimColor)
        }
        switch cam.phase {
        case .free: return Color(white: 0.65)
        case .guiding: return aimColor
        case .locked: return lockColor
        case .lost: return Color(red: 1.0, green: 0.48, blue: 0.4)
        }
    }

    private var zoomChoices: [CGFloat] { cam.hasUltraWide ? [0.5, 1, 2, 3] : [1, 2, 3] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if cam.authorized {
                VStack(spacing: 12) {
                    topBar

                    viewfinder

                    Text(cam.hint)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundColor(hintColor)
                        .multilineTextAlignment(.center)
                        .frame(minHeight: 40)
                        .padding(.horizontal, 16)

                    zoomRow
                    if cam.mode == .outfit { poseRow }
                    Spacer(minLength: 0)
                    controls
                }
            } else {
                Text("Aimframe non può usare la fotocamera. Consentila in Impostazioni → Aimframe.")
                    .font(.system(size: 17, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(32)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { cam.start() }
        .fullScreenCover(isPresented: Binding(get: { cam.reviewImage != nil }, set: { if !$0 { cam.discardReview() } })) {
            ReviewView(cam: cam)
        }
        .onChange(of: pickerItem) { item in
            guard let item = item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                await MainActor.run {
                    pickerItem = nil
                    if let data = data { cam.importInspiration(data) }
                }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Picker("Modalità", selection: Binding(get: { cam.mode }, set: { cam.setMode($0) })) {
                ForEach(AppMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 230)

            Spacer()

            if cam.mode == .outfit {
                toggleButton(on: cam.autoShot, symbolOn: "timer", symbolOff: "timer", label: "Autoscatto") {
                    cam.setAutoShot(!cam.autoShot)
                }
                toggleButton(on: cam.voiceOn, symbolOn: "speaker.wave.2.fill", symbolOff: "speaker.slash.fill", label: "Voce") {
                    cam.setVoice(!cam.voiceOn)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private func toggleButton(on: Bool, symbolOn: String, symbolOff: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: on ? symbolOn : symbolOff)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(on ? aimColor : Color(white: 0.5))
                .frame(width: 38, height: 34)
                .background(on ? Color(red: 0.17, green: 0.14, blue: 0.07) : panelColor)
                .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .accessibilityLabel(label + (on ? " attivo" : " spento"))
    }

    private var poseRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                poseChip(title: "Libera", selected: cam.selectedPoseID == "free") { cam.selectPose(nil) }
                if let imported = cam.importedPose {
                    poseChip(title: "★ Ispirazione", selected: cam.selectedPoseID == imported.id) { cam.selectPose(imported) }
                }
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    chipLabel("＋ Da una foto", selected: false)
                }
                ForEach(PoseMath.library) { pose in
                    poseChip(title: pose.name, selected: cam.selectedPoseID == pose.id) { cam.selectPose(pose) }
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private func poseChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(title, selected: selected) }
    }

    private func chipLabel(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundColor(selected ? aimColor : Color(white: 0.75))
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(selected ? Color(red: 0.17, green: 0.14, blue: 0.07) : panelColor)
            .clipShape(Capsule())
    }

    private func skeleton(_ joints: [Joint: CGPoint], in size: CGSize) -> Path {
        var path = Path()
        for (a, b) in PoseMath.bones {
            guard let pa = joints[a], let pb = joints[b] else { continue }
            path.move(to: CGPoint(x: pa.x * size.width, y: pa.y * size.height))
            path.addLine(to: CGPoint(x: pb.x * size.width, y: pb.y * size.height))
        }
        return path
    }

    private var viewfinder: some View {
        ZStack {
            CameraPreview(session: cam.session)
            GeometryReader { geo in
                overlay(in: geo.size)
            }
            if cam.flash {
                Color.white.opacity(0.8)
            }
            if let toast = cam.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Capsule())
                        .padding(.bottom, 14)
                }
            }
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func overlay(in size: CGSize) -> some View {
        let w = size.width, h = size.height

        // Rule of thirds
        Path { p in
            for i in 1..<3 {
                let f = CGFloat(i) / 3
                p.move(to: CGPoint(x: w * f, y: 0)); p.addLine(to: CGPoint(x: w * f, y: h))
                p.move(to: CGPoint(x: 0, y: h * f)); p.addLine(to: CGPoint(x: w, y: h * f))
            }
        }
        .stroke(Color.white.opacity(0.18), lineWidth: 1)

        // Level line: stays flat with the horizon while the phone rolls
        if let roll = cam.roll {
            let flat = abs(roll) < 0.026
            Path { p in
                p.move(to: CGPoint(x: -w * 0.2, y: 0)); p.addLine(to: CGPoint(x: -w * 0.04, y: 0))
                p.move(to: CGPoint(x: w * 0.04, y: 0)); p.addLine(to: CGPoint(x: w * 0.2, y: 0))
            }
            .stroke(flat ? lockColor : Color.white.opacity(0.75), lineWidth: 1.5)
            .rotationEffect(.radians(-roll), anchor: .topLeading)
            .offset(x: w / 2, y: h / 2)
        }

        if cam.mode == .outfit {
            // The pose to copy, drawn on the person's own body
            if !cam.ghost.isEmpty {
                skeleton(cam.ghost, in: size)
                    .stroke((cam.poseMatched ? lockColor : aimColor).opacity(0.85),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            // What the AI sees of the body right now
            skeleton(cam.body, in: size)
                .stroke(Color.white.opacity(0.75), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            if let n = cam.countdown {
                Text("\(n)")
                    .font(.system(size: 120, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.6), radius: 8)
                    .position(x: w / 2, y: h / 2)
            }
        }

        if cam.mode == .landscape, let box = cam.subjectBox, cam.phase == .guiding || cam.phase == .locked {
            let tx = cam.target.x * w, ty = cam.target.y * h
            let cx = box.midX * w, cy = box.midY * h

            // Where the subject should end up
            Path { p in
                p.move(to: CGPoint(x: tx - 9, y: ty)); p.addLine(to: CGPoint(x: tx + 9, y: ty))
                p.move(to: CGPoint(x: tx, y: ty - 9)); p.addLine(to: CGPoint(x: tx, y: ty + 9))
            }
            .stroke(guideColor, lineWidth: 2)

            if cam.phase == .guiding {
                Path { p in
                    p.move(to: CGPoint(x: cx, y: cy)); p.addLine(to: CGPoint(x: tx, y: ty))
                }
                .stroke(guideColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
            }

            // The subject the AI is following
            RoundedRectangle(cornerRadius: 10)
                .stroke(guideColor, lineWidth: 3)
                .frame(width: box.width * w, height: box.height * h)
                .position(x: cx, y: cy)

            Text(cam.label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(guideColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .position(x: min(max(cx, 60), w - 60), y: min(box.maxY * h + 16, h - 14))
        }
    }

    private var zoomRow: some View {
        HStack(spacing: 8) {
            ForEach(zoomChoices, id: \.self) { z in
                let on = abs(cam.zoomShown - z) < 0.05
                Button {
                    cam.setZoom(display: z)
                } label: {
                    Text(zoomText(z))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(on ? aimColor : Color(white: 0.65))
                        .frame(minWidth: 46, minHeight: 34)
                        .background(on ? Color(red: 0.17, green: 0.14, blue: 0.07) : panelColor)
                        .clipShape(Capsule())
                }
            }
            if !zoomChoices.contains(where: { abs(cam.zoomShown - $0) < 0.05 }) {
                Text(zoomText(cam.zoomShown))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(aimColor)
                    .frame(minWidth: 46, minHeight: 34)
                    .background(Color(red: 0.17, green: 0.14, blue: 0.07))
                    .clipShape(Capsule())
            }
        }
    }

    private func zoomText(_ z: CGFloat) -> String {
        let rounded = (z * 10).rounded() / 10
        if rounded == rounded.rounded() { return "\(Int(rounded))×" }
        return String(format: "%.1f×", Double(rounded))
    }

    private var controls: some View {
        HStack {
            Group {
                if let thumb = cam.lastThumb {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    panelColor
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .accessibilityLabel("Ultima foto")

            Spacer()

            Button {
                cam.capture()
            } label: {
                ZStack {
                    Circle().stroke((cam.phase == .locked || cam.poseMatched) ? lockColor : Color.white, lineWidth: 4)
                    Circle().fill(Color.white).padding(7)
                }
                .frame(width: 76, height: 76)
            }
            .accessibilityLabel("Scatta")

            Spacer()

            if cam.mode == .landscape {
                Button {
                    cam.scanOrClear()
                } label: {
                    Image(systemName: cam.phase == .free ? "sparkles" : "xmark")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(cam.phase == .free ? aimColor : .white)
                        .frame(width: 56, height: 56)
                        .background(cam.phase == .free ? panelColor : Color(white: 0.2))
                        .clipShape(Circle())
                }
                .accessibilityLabel(cam.phase == .free ? "Analizza la scena" : "Togli la guida")
            } else {
                Button {
                    cam.flipCamera()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 56, height: 56)
                        .background(panelColor)
                        .clipShape(Circle())
                }
                .accessibilityLabel("Cambia fotocamera")
            }
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 18)
    }
}
