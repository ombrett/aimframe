import SwiftUI

/// Shown right after a shot: the photo with the suggested look, the other looks, Before/After and Save.
/// Nothing is written until Save: every change stays reversible.
struct ReviewView: View {
    @ObservedObject var cam: CameraModel
    @State private var showingOriginal = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 12) {
                HStack {
                    Button { cam.discardReview() } label: {
                        Label("Scarta", systemImage: "trash").font(Theme.body())
                    }
                    .foregroundColor(Theme.ivoryDim)
                    Spacer()
                    Button { cam.resetEdits() } label: {
                        Label("Ripristina", systemImage: "arrow.uturn.backward").font(Theme.body())
                    }
                    .foregroundColor(Theme.ivoryDim)
                    .disabled(cam.selectedLook == cam.recommendedLook && cam.intensity == 1 && cam.frameStyle == 0)
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)

                photo

                VStack(spacing: 3) {
                    Text(cam.recommendReason)
                        .font(Theme.body(14))
                        .foregroundColor(Theme.ivory)
                    Text("Suggerimento automatico da luce e colori misurati, non da un'AI generativa")
                        .font(Theme.small(11))
                        .foregroundColor(Theme.ivoryDim)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)

                if cam.photosDenied { PhotosDeniedBanner() }
                looks
                intensityRow

                Picker("Cornice", selection: Binding(get: { cam.frameStyle }, set: { cam.setFrameStyle($0) })) {
                    Text("Senza cornice").tag(0)
                    Text("Bianca").tag(1)
                    Text("Nera").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                Button { cam.saveReview() } label: {
                    Label(cam.savingReview ? "Salvo…" : "Salva in Foto", systemImage: "square.and.arrow.down")
                        .font(Theme.title())
                        .foregroundColor(Theme.background)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Theme.yellow)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(cam.savingReview)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var photo: some View {
        ZStack(alignment: .topLeading) {
            if let image = showingOriginal ? (cam.reviewOriginal ?? cam.reviewImage) : cam.reviewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Pill(text: showingOriginal ? "Prima" : "Dopo · tieni premuto per l'originale",
                 color: showingOriginal ? Theme.ivory : Theme.ivoryDim,
                 symbol: showingOriginal ? "eye" : "hand.tap")
                .padding(8)
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 40, pressing: { pressing in
            if pressing != showingOriginal { Haptics.selection() }
            showingOriginal = pressing
        }, perform: {})
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showingOriginal ? "Foto originale" : "Foto con il look \(Grade.look(cam.selectedLook).name)")
        .accessibilityHint("Tieni premuto per confrontare con l'originale")
    }

    private var looks: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Grade.looks) { look in
                    Button { cam.selectLook(look.id) } label: { cell(look) }
                        .accessibilityLabel(look.name + (cam.recommendedLook == look.id ? ", consigliato" : ""))
                        .accessibilityAddTraits(cam.selectedLook == look.id ? .isSelected : [])
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private func cell(_ look: Look) -> some View {
        let selected = cam.selectedLook == look.id
        let recommended = cam.recommendedLook == look.id
        return VStack(spacing: 4) {
            ZStack {
                if let thumb = cam.lookThumbs[look.id] {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    Theme.panel
                }
            }
            .frame(width: 62, height: 82)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Theme.yellow : Color.clear, lineWidth: 2.5))
            Text(look.name)
                .font(Theme.small(11))
                .foregroundColor(selected ? Theme.yellow : Theme.ivoryDim)
                .lineLimit(1)
            Label("Consigliato", systemImage: "star.fill")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(Theme.yellow)
                .opacity(recommended ? 1 : 0)
        }
        .frame(width: 80)
    }

    private var intensityRow: some View {
        HStack(spacing: 12) {
            Text("Originale")
                .font(Theme.small(12))
                .foregroundColor(Theme.ivoryDim)
            Slider(value: Binding(get: { cam.intensity }, set: { cam.setIntensity($0) }), in: 0...1)
                .tint(Theme.yellow)
                .accessibilityLabel("Intensità del look")
                .accessibilityValue("\(Int((cam.intensity * 100).rounded())) per cento")
            Text("\(Int((cam.intensity * 100).rounded()))%")
                .font(Theme.small(12))
                .monospacedDigit()
                .foregroundColor(Theme.ivoryDim)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 18)
    }
}
