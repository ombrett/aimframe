import PhotosUI
import SwiftUI

struct CameraScreen: View {
    @ObservedObject var cam: CameraModel
    @State private var pickerItem: PhotosPickerItem?
    @State private var showBrowser = false
    @State private var showGallery = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 10) {
            topBar
            Viewfinder(cam: cam)
            InstructionBar(instruction: cam.instruction)
            modeRows
            Spacer(minLength: 0)
            ShutterRow(cam: cam, showGallery: $showGallery)
        }
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $showBrowser, onDismiss: { cam.setPaused(false) }) {
            InspirationBrowser(cam: cam)
        }
        .sheet(isPresented: $showGallery, onDismiss: { cam.setPaused(false) }) {
            GalleryView()
        }
        .sheet(isPresented: $showSettings, onDismiss: { cam.setPaused(false) }) {
            SettingsView(cam: cam)
        }
        .fullScreenCover(isPresented: Binding(get: { cam.reviewImage != nil }, set: { if !$0 { cam.discardReview() } })) {
            ReviewView(cam: cam)
        }
        .fullScreenCover(isPresented: Binding(get: { cam.carouselReviewOpen }, set: { if !$0 { cam.closeCarouselReview(clear: false) } })) {
            CarouselReviewView(cam: cam)
        }
        .onChange(of: pickerItem) { item in
            guard let item = item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                await MainActor.run {
                    pickerItem = nil
                    if let data = data { cam.importInspiration(data) } else { cam.showToast("Non riesco ad aprire questa foto.") }
                }
            }
        }
        .onChange(of: showGallery) { open in if open { cam.setPaused(true) } }
        .onChange(of: showSettings) { open in if open { cam.setPaused(true) } }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(AppMode.allCases, id: \.self) { mode in
                    Button { cam.setMode(mode) } label: {
                        Text(mode.rawValue)
                            .font(Theme.small(13))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundColor(cam.mode == mode ? Theme.background : Theme.ivoryDim)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 32)
                            .background(cam.mode == mode ? Theme.ivory : Color.clear)
                            .clipShape(Capsule())
                    }
                    .accessibilityAddTraits(cam.mode == mode ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Theme.panel)
            .clipShape(Capsule())

            Spacer(minLength: 4)

            iconButton("gearshape", label: "Impostazioni") { showSettings = true }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Theme.ivory)
                .frame(width: 40, height: 40)
                .background(Theme.panel)
                .clipShape(Circle())
        }
        .accessibilityLabel(label)
    }

    // MARK: Rows under the instruction

    @ViewBuilder
    private var modeRows: some View {
        switch cam.mode {
        case .landscape:
            ZoomRow(cam: cam)
        case .outfit:
            VStack(spacing: 8) {
                if !cam.isFront { ZoomRow(cam: cam) }
                poseRow
                if cam.selectedPoseID == "import" && cam.referenceImage != nil { GuideControls(cam: cam) }
            }
        case .carousel:
            VStack(spacing: 8) {
                carouselRow
                if !cam.isFront { ZoomRow(cam: cam) }
            }
        }
    }

    private var poseRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { cam.selectPose(nil) } label: { ChipLabel(title: "Libera", selected: cam.selectedPoseID == "free") }
                if let imported = cam.importedPose {
                    Button { cam.selectPose(imported) } label: {
                        ChipLabel(title: "Foto guida", selected: cam.selectedPoseID == imported.id, symbol: "photo")
                    }
                }
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    ChipLabel(title: "Dal rullino", symbol: "plus")
                }
                Button { cam.importFromClipboard() } label: { ChipLabel(title: "Incolla", symbol: "doc.on.clipboard") }
                Button {
                    cam.setPaused(true)
                    showBrowser = true
                } label: { ChipLabel(title: "Cerca online", symbol: "globe") }
                ForEach(PoseMath.library) { pose in
                    Button { cam.selectPose(pose) } label: { ChipLabel(title: pose.name, selected: cam.selectedPoseID == pose.id) }
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private var carouselRow: some View {
        let done = Set(cam.carouselShots.map { $0.step })
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(CarouselStep.allCases, id: \.self) { step in
                    Button { cam.setCarouselStep(step) } label: {
                        ChipLabel(title: "\(step.rawValue + 1). \(step.title)", selected: cam.carouselStep == step,
                                  symbol: done.contains(step) ? "checkmark" : nil)
                    }
                    .accessibilityLabel("\(step.title)\(done.contains(step) ? ", fatto" : "")")
                }
                if !cam.carouselShots.isEmpty {
                    Button { cam.openCarouselReview() } label: {
                        ChipLabel(title: "Rivedi (\(cam.carouselShots.count))", selected: true, symbol: "square.stack")
                    }
                }
            }
            .padding(.horizontal, 14)
        }
    }
}

// MARK: - Instruction

struct InstructionBar: View {
    let instruction: Instruction

    private var who: (symbol: String, text: String)? {
        switch instruction.audience {
        case .photographer: return ("camera.fill", "Per chi fotografa")
        case .subject: return ("figure.stand", "Per chi posa")
        case .none: return nil
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            if let who = who {
                Label(who.text, systemImage: who.symbol)
                    .font(Theme.small(11))
                    .foregroundColor(Theme.ivoryDim)
                    .textCase(.uppercase)
            }
            HStack(spacing: 8) {
                Image(systemName: Theme.symbol(for: instruction.tone))
                    .font(.system(size: 16, weight: .semibold))
                    .accessibilityHidden(true)
                Text(instruction.text)
                    .font(Theme.title(18))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
            .foregroundColor(Theme.color(for: instruction.tone))
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .padding(.horizontal, 16)
        .animation(.easeOut(duration: 0.2), value: instruction)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Zoom

struct ZoomRow: View {
    @ObservedObject var cam: CameraModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(cam.zoomPresets, id: \.self) { z in
                let on = abs(cam.zoomShown - z) < 0.05
                Button { cam.setZoom(display: z) } label: {
                    Text(Self.text(z))
                        .font(Theme.small(13))
                        .monospacedDigit()
                        .foregroundColor(on ? Theme.yellow : Theme.ivoryDim)
                        .frame(minWidth: 46, minHeight: 34)
                        .background(on ? Theme.yellowWash : Theme.panel)
                        .clipShape(Capsule())
                }
                .accessibilityLabel("Zoom \(Self.text(z))")
            }
            if !cam.zoomPresets.contains(where: { abs(cam.zoomShown - $0) < 0.05 }) {
                Text(Self.text(cam.zoomShown))
                    .font(Theme.small(13))
                    .monospacedDigit()
                    .foregroundColor(Theme.yellow)
                    .frame(minWidth: 46, minHeight: 34)
                    .background(Theme.yellowWash)
                    .clipShape(Capsule())
            }
        }
    }

    static func text(_ z: CGFloat) -> String {
        let r = (z * 10).rounded() / 10
        return r == r.rounded() ? "\(Int(r))×" : String(format: "%.1f×", Double(r))
    }
}

// MARK: - Guide photo controls

struct GuideControls: View {
    @ObservedObject var cam: CameraModel

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                if cam.silhouette != nil {
                    Picker("Guida", selection: $cam.guideStyle) {
                        Text("Foto").tag(0)
                        Text("Sagoma").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                }
                Slider(value: $cam.guideOpacity, in: 0.1...0.9)
                    .tint(Theme.yellow)
                    .accessibilityLabel("Trasparenza della guida")
                Text("\(Int((cam.guideOpacity * 100).rounded()))%")
                    .font(Theme.small(12))
                    .monospacedDigit()
                    .foregroundColor(Theme.ivoryDim)
                    .frame(width: 36, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Button { cam.guideFlipped.toggle(); Haptics.selection() } label: {
                    ChipLabel(title: "Ribalta", selected: cam.guideFlipped, symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                Button { cam.resetGuideTransform(); Haptics.tap() } label: {
                    ChipLabel(title: "Centra", symbol: "arrow.counterclockwise")
                }
                Text("Trascina o pizzica la guida")
                    .font(Theme.small(11))
                    .foregroundColor(Theme.ivoryDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Shutter row

struct ShutterRow: View {
    @ObservedObject var cam: CameraModel
    @Binding var showGallery: Bool

    var body: some View {
        ZStack {
            HStack {
                Button { showGallery = true } label: {
                    Group {
                        if let thumb = cam.lastThumb {
                            Image(uiImage: thumb).resizable().scaledToFill()
                        } else {
                            Image(systemName: "photo.on.rectangle").foregroundColor(Theme.ivoryDim).font(.system(size: 20))
                        }
                    }
                    .frame(width: 54, height: 54)
                    .background(Theme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel("Galleria di Aimframe")

                Spacer()
                rightButton
            }
            .padding(.horizontal, 28)

            shutter
        }
        .overlay(alignment: .top) { cancelButton.offset(y: -44) }
        .padding(.bottom, 14)
    }

    private var shutter: some View {
        let ready = cam.phase == .locked || cam.poseMatched || cam.carouselReady
        return Button { cam.capture() } label: {
            ZStack {
                Circle().stroke(ready ? Theme.green : Theme.ivory, lineWidth: 4)
                if let p = cam.autoProgress {
                    Circle()
                        .trim(from: 0, to: p)
                        .stroke(Theme.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Circle().fill(Theme.ivory).padding(8)
            }
            .frame(width: 76, height: 76)
        }
        .accessibilityLabel("Scatta")
    }

    @ViewBuilder
    private var cancelButton: some View {
        if cam.autoProgress != nil || cam.countdown != nil {
            Button {
                if cam.countdown != nil { cam.cancelCountdown() } else { cam.cancelAutoShot() }
            } label: {
                Label("Annulla scatto", systemImage: "xmark")
                    .font(Theme.small(13))
                    .foregroundColor(Theme.ivory)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                    .background(Color.black.opacity(0.7))
                    .clipShape(Capsule())
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var rightButton: some View {
        if cam.mode == .landscape {
            let idle = cam.phase == .free || cam.phase == .lost
            Button { cam.scanOrClear() } label: {
                Image(systemName: idle ? "sparkle" : "xmark")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(idle ? Theme.yellow : Theme.ivory)
                    .frame(width: 54, height: 54)
                    .background(Theme.panel)
                    .clipShape(Circle())
            }
            .accessibilityLabel(idle ? "Analizza la scena" : "Togli la guida")
        } else {
            Button { cam.flipCamera() } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Theme.ivory)
                    .frame(width: 54, height: 54)
                    .background(Theme.panel)
                    .clipShape(Circle())
            }
            .accessibilityLabel(cam.isFront ? "Passa alla fotocamera posteriore" : "Passa alla fotocamera frontale")
        }
    }
}
