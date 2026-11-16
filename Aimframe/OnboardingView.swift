import SwiftUI

/// Three short pages, skippable, shown on the first launch and again from the settings.
struct OnboardingView: View {
    let onDone: () -> Void
    @State private var page = 0

    private let pages: [(symbol: String, title: String, text: String)] = [
        ("viewfinder", "Punta, segui, scatta",
         "Tieni il telefono fermo sulla scena: Aimframe trova il soggetto e ti dice dove spostarti con un'indicazione alla volta."),
        ("figure.stand", "Outfit e pose",
         "Scegli una posa o una foto guida da ricalcare. Le istruzioni in giallo con la fotocamera sono per chi fotografa, quelle con la figura per chi posa."),
        ("checkmark.circle", "Verde vuol dire pronto",
         "Quando è tutto giusto e il telefono è fermo, Aimframe scatta da solo. Puoi annullare o usare sempre il pulsante. L'analisi avviene sul telefono.")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Salta", action: onDone)
                    .font(Theme.body())
                    .foregroundColor(Theme.ivoryDim)
                    .padding(16)
            }
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { i in
                    VStack(spacing: 22) {
                        Spacer()
                        ZStack {
                            Brackets(length: 0.3)
                                .stroke(Theme.ivory, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                                .frame(width: 130, height: 130)
                            Image(systemName: pages[i].symbol)
                                .font(.system(size: 42, weight: .semibold))
                                .foregroundColor(Theme.yellow)
                        }
                        .accessibilityHidden(true)
                        Text(pages[i].title)
                            .font(Theme.title(26))
                            .foregroundColor(Theme.ivory)
                            .multilineTextAlignment(.center)
                        Text(pages[i].text)
                            .font(Theme.body(16))
                            .foregroundColor(Theme.ivoryDim)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 28)
                        Spacer()
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            Button {
                if page < pages.count - 1 {
                    withAnimation(.easeInOut(duration: 0.25)) { page += 1 }
                } else {
                    onDone()
                }
            } label: {
                Text(page < pages.count - 1 ? "Avanti" : "Inizia")
                    .font(Theme.title())
                    .foregroundColor(Theme.background)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Theme.yellow)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .background(Theme.background.ignoresSafeArea())
    }
}
