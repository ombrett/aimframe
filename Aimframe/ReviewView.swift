import SwiftUI

/// Shown right after a shot: the photo with the recommended look, other looks to try, and Save.
struct ReviewView: View {
    @ObservedObject var cam: CameraModel

    private let accent = Color(red: 1.0, green: 0.77, blue: 0.24)
    private let panel = Color(white: 0.11)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                if let image = cam.reviewImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }

                Text(cam.recommendReason)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundColor(Color(white: 0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Grade.looks) { look in
                            Button {
                                cam.selectLook(look.id)
                            } label: {
                                lookCell(look)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                }

                HStack(spacing: 12) {
                    Text("Intensità")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(Color(white: 0.65))
                    Slider(value: Binding(get: { cam.intensity }, set: { cam.setIntensity($0) }), in: 0...1)
                        .tint(accent)
                    Text("\(Int((cam.intensity * 100).rounded()))%")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(Color(white: 0.65))
                        .frame(width: 44, alignment: .trailing)
                }
                .padding(.horizontal, 18)

                Picker("Cornice", selection: Binding(get: { cam.frameStyle }, set: { cam.setFrameStyle($0) })) {
                    Text("Senza cornice").tag(0)
                    Text("Bianca").tag(1)
                    Text("Nera").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                HStack(spacing: 12) {
                    Button {
                        cam.discardReview()
                    } label: {
                        Text("Scarta")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(panel)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    Button {
                        cam.saveReview()
                    } label: {
                        Text(cam.savingReview ? "Salvo…" : "Salva")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundColor(Color(red: 0.1, green: 0.08, blue: 0.01))
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(accent)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(cam.savingReview)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func lookCell(_ look: Look) -> some View {
        let selected = cam.selectedLook == look.id
        let recommended = cam.recommendedLook == look.id
        return VStack(spacing: 5) {
            ZStack {
                if let thumb = cam.lookThumbs[look.id] {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    panel
                }
            }
            .frame(width: 66, height: 88)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? accent : Color.clear, lineWidth: 2.5))

            Text(look.name)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(selected ? accent : Color(white: 0.75))
                .lineLimit(1)
            Text(recommended ? "Consigliato" : " ")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(accent)
        }
        .frame(width: 84)
    }
}
