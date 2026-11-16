import SwiftUI

/// Root: the short first-run guide, then the camera. The camera permission is asked only after the guide.
struct ContentView: View {
    @StateObject private var cam = CameraModel()
    @AppStorage("onboardingDone") private var onboardingDone = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if !onboardingDone {
                OnboardingView {
                    onboardingDone = true
                    cam.start()
                }
            } else {
                switch cam.status {
                case .granted, .unknown:
                    CameraScreen(cam: cam)
                case .denied:
                    PermissionView(
                        symbol: "camera.fill",
                        title: "Serve la fotocamera",
                        text: "Aimframe usa la fotocamera per guidarti mentre inquadri. Le immagini vengono analizzate solo sul telefono.",
                        button: "Apri Impostazioni",
                        action: openAppSettings)
                case .unavailable:
                    PermissionView(
                        symbol: "exclamationmark.triangle.fill",
                        title: "Fotocamera non disponibile",
                        text: "Non riesco ad aprire la fotocamera posteriore. Chiudi le altre app che la usano e riapri Aimframe.",
                        button: nil,
                        action: {})
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { if onboardingDone { cam.start() } }
        .onChange(of: scenePhase) { phase in
            cam.setActive(phase == .active)
            if phase == .active && onboardingDone && cam.status == .denied { cam.start() }
        }
    }
}

struct PermissionView: View {
    let symbol: String
    let title: String
    let text: String
    let button: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundColor(Theme.yellow)
            Text(title)
                .font(Theme.title(24))
                .foregroundColor(Theme.ivory)
                .multilineTextAlignment(.center)
            Text(text)
                .font(Theme.body(16))
                .foregroundColor(Theme.ivoryDim)
                .multilineTextAlignment(.center)
            if let button = button {
                Button(action: action) {
                    Text(button)
                        .font(Theme.title())
                        .foregroundColor(Theme.background)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Theme.yellow)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.top, 6)
            }
        }
        .padding(28)
        .frame(maxWidth: 420)
    }
}
