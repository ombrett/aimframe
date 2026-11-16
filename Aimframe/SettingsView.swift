import SwiftUI

struct SettingsView: View {
    @ObservedObject var cam: CameraModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("onboardingDone") private var onboardingDone = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Scatto automatico", isOn: $cam.autoShot)
                    Toggle("Istruzioni vocali per chi posa", isOn: $cam.voiceOn)
                    Toggle("Griglia dei terzi", isOn: $cam.showGrid)
                } header: {
                    Text("Fotocamera")
                } footer: {
                    Text("Con lo scatto automatico, Aimframe scatta solo quando l'inquadratura è giusta e il telefono è fermo per un secondo. Il pulsante resta sempre disponibile.")
                }

                Section {
                    Toggle("Tieni una copia in Aimframe", isOn: $cam.keepCopy)
                    Toggle("Risoluzione massima (48 MP)", isOn: $cam.fullResolution)
                } header: {
                    Text("Salvataggio")
                } footer: {
                    Text("Le foto vanno sempre in Foto. La copia serve per la galleria dell'app. Senza risoluzione massima le foto arrivano fino a circa 24 MP: file più leggeri e salvataggio più rapido.")
                }

                Section {
                    Button("Rivedi la guida iniziale") {
                        onboardingDone = false
                        dismiss()
                    }
                } footer: {
                    Text("Analisi della scena, pose e look avvengono sul telefono con i modelli di Apple. Le foto non vengono caricate. Solo \"Cerca online\" usa internet, per mostrarti pagine web.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .tint(Theme.yellow)
            .navigationTitle("Impostazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }.foregroundColor(Theme.yellow)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
