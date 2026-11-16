import CoreImage
import SwiftUI

/// The carousel's photos side by side with one shared look, editable, saved together.
struct CarouselReviewView: View {
    @ObservedObject var cam: CameraModel
    @State private var look = "teal"
    @State private var intensity: Double = 1
    @State private var frame = 0
    @State private var previews: [UUID: UIImage] = [:]
    @State private var saving = false
    @State private var showOriginal = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 12) {
                HStack {
                    Button("Continua a scattare") { cam.closeCarouselReview(clear: false) }
                        .foregroundColor(Theme.ivoryDim)
                    Spacer()
                    Text("Carosello")
                        .font(Theme.title())
                        .foregroundColor(Theme.ivory)
                    Spacer()
                    Button("Ricomincia") { cam.closeCarouselReview(clear: true) }
                        .foregroundColor(Theme.red)
                }
                .font(Theme.body(14))
                .padding(.horizontal, 16)
                .padding(.top, 6)

                TabView {
                    ForEach(cam.carouselShots) { shot in
                        VStack(spacing: 6) {
                            if let image = showOriginal ? shot.thumb : previews[shot.id] {
                                Image(uiImage: image).resizable().scaledToFit()
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else {
                                ProgressView().tint(Theme.ivory)
                            }
                            Text("\(shot.step.rawValue + 1). \(shot.step.title)")
                                .font(Theme.small(12))
                                .foregroundColor(Theme.ivoryDim)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 28)
                        .contentShape(Rectangle())
                        .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 40, pressing: { showOriginal = $0 }, perform: {})
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .frame(maxHeight: .infinity)

                Text("Stesso look su tutte le foto, così il carosello è coerente. Tieni premuto per l'originale.")
                    .font(Theme.small(11))
                    .foregroundColor(Theme.ivoryDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Grade.looks) { l in
                            Button {
                                look = l.id
                                Haptics.selection()
                                refresh()
                            } label: { ChipLabel(title: l.name, selected: look == l.id) }
                        }
                    }
                    .padding(.horizontal, 14)
                }

                HStack(spacing: 12) {
                    Text("Originale").font(Theme.small(12)).foregroundColor(Theme.ivoryDim)
                    Slider(value: $intensity, in: 0...1, onEditingChanged: { editing in if !editing { refresh() } })
                        .tint(Theme.yellow)
                        .accessibilityLabel("Intensità del look")
                    Text("\(Int((intensity * 100).rounded()))%")
                        .font(Theme.small(12)).monospacedDigit().foregroundColor(Theme.ivoryDim)
                        .frame(width: 40, alignment: .trailing)
                }
                .padding(.horizontal, 18)

                Picker("Cornice", selection: $frame) {
                    Text("Senza cornice").tag(0)
                    Text("Bianca").tag(1)
                    Text("Nera").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .onChange(of: frame) { _ in refresh() }

                Button {
                    saving = true
                    cam.saveCarousel(look: look, intensity: intensity, frame: frame) { _ in
                        saving = false
                        Haptics.success()
                        cam.closeCarouselReview(clear: true)
                    }
                } label: {
                    Label(saving ? "Salvo…" : "Salva \(cam.carouselShots.count) foto in Foto", systemImage: "square.and.arrow.down.on.square")
                        .font(Theme.title())
                        .foregroundColor(Theme.background)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Theme.yellow)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(saving || cam.carouselShots.isEmpty)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            refresh()
            // Start from the look suggested for the first photo (worked out off the main thread).
            guard let first = cam.carouselShots.first else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                guard let full = CIImage(data: first.data, options: [.applyOrientationProperty: true]) else { return }
                let id = Grade.recommend(Grade.scaled(full, maxSide: 220)).id
                DispatchQueue.main.async {
                    if look != id {
                        look = id
                        refresh()
                    }
                }
            }
        }
    }

    private func refresh() {
        for shot in cam.carouselShots {
            cam.carouselPreview(shot, look: look, intensity: intensity, frame: frame) { image in
                if let image = image { previews[shot.id] = image }
            }
        }
    }
}
