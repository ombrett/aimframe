import SwiftUI
import UIKit
import WebKit

/// Holds the web view and pulls the picture the user is looking at out of the page.
final class BrowserStore: ObservableObject {
    let webView: WKWebView
    @Published var busy = false
    @Published var message: String?

    init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
    }

    /// A web address opens that page; anything else is searched on Google Images, which needs no account.
    func open(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.lowercased().hasPrefix("http"), let url = URL(string: trimmed) {
            webView.load(URLRequest(url: url))
            return
        }
        if !trimmed.contains(" "), trimmed.contains("."), let url = URL(string: "https://" + trimmed) {
            webView.load(URLRequest(url: url))
            return
        }
        var parts = URLComponents(string: "https://www.google.com/search")
        parts?.queryItems = [URLQueryItem(name: "q", value: trimmed), URLQueryItem(name: "tbm", value: "isch")]
        if let url = parts?.url { webView.load(URLRequest(url: url)) }
    }

    /// Pinterest itself. It asks for a Pinterest account before showing results.
    func openPinterest(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts = URLComponents(string: "https://www.pinterest.com/search/pins/")
        parts?.queryItems = [URLQueryItem(name: "q", value: trimmed.isEmpty ? "outfit pose" : trimmed)]
        if let url = parts?.url { webView.load(URLRequest(url: url)) }
    }

    /// Finds the largest picture visible on screen and downloads it.
    func grabLargestImage(completion: @escaping (Data?) -> Void) {
        let script = """
        (function(){
          var best = "", area = 0, list = document.images;
          for (var i = 0; i < list.length; i++) {
            var r = list[i].getBoundingClientRect();
            var w = Math.min(r.right, window.innerWidth) - Math.max(r.left, 0);
            var h = Math.min(r.bottom, window.innerHeight) - Math.max(r.top, 0);
            if (w > 0 && h > 0 && w * h > area) { area = w * h; best = list[i].currentSrc || list[i].src || ""; }
          }
          return best;
        })()
        """
        webView.evaluateJavaScript(script) { result, _ in
            guard let source = result as? String, !source.isEmpty else {
                completion(nil)
                return
            }
            if source.hasPrefix("data:") {
                if let comma = source.firstIndex(of: ","), source.contains(";base64") {
                    completion(Data(base64Encoded: String(source[source.index(after: comma)...])))
                } else {
                    completion(nil)
                }
                return
            }
            // Pinterest serves small previews in the grid; ask for the larger copy first.
            var candidates: [URL] = []
            for small in ["/236x/", "/474x/", "/564x/"] where source.contains(small) {
                if let bigger = URL(string: source.replacingOccurrences(of: small, with: "/736x/")) { candidates.append(bigger) }
            }
            if let original = URL(string: source) { candidates.append(original) }
            self.download(candidates, completion: completion)
        }
    }

    private func download(_ urls: [URL], completion: @escaping (Data?) -> Void) {
        guard let url = urls.first else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        URLSession.shared.dataTask(with: url) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            if ok, let data = data, UIImage(data: data) != nil {
                DispatchQueue.main.async { completion(data) }
            } else {
                self.download(Array(urls.dropFirst()), completion: completion)
            }
        }.resume()
    }
}

private struct WebViewHolder: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// A small browser for finding a pose online and copying it into the outfit guide.
struct InspirationBrowser: View {
    @ObservedObject var cam: CameraModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = BrowserStore()
    @State private var query = "outfit pose figura intera"

    private let accent = Color(red: 1.0, green: 0.77, blue: 0.24)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Cerca una posa o incolla un link", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit { store.open(query) }
                Button("Chiudi") { dismiss() }
                    .foregroundColor(accent)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            HStack(spacing: 8) {
                Button("Cerca su Google Immagini") { store.open(query) }
                Button("Apri Pinterest") { store.openPinterest(query) }
                Spacer()
            }
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundColor(accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            WebViewHolder(webView: store.webView)

            VStack(spacing: 8) {
                Text(store.message ?? "Tocca una foto per ingrandirla, poi tocca il tasto.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(store.message == nil ? Color(white: 0.7) : Color(red: 1.0, green: 0.48, blue: 0.4))
                    .multilineTextAlignment(.center)
                Button {
                    usePose()
                } label: {
                    Text(store.busy ? "Preparo la guida…" : "Usa come foto guida")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(Color(red: 0.1, green: 0.08, blue: 0.01))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(accent)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(store.busy)
            }
            .padding(12)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { store.open(query) }
    }

    private func usePose() {
        store.busy = true
        store.message = nil
        store.grabLargestImage { data in
            guard let data = data else {
                store.busy = false
                store.message = "Non trovo una foto in questa pagina. Apri la foto a tutto schermo e riprova."
                return
            }
            cam.importInspiration(data) { found in
                store.busy = false
                if found {
                    dismiss()
                } else {
                    store.message = "Non riesco a usare questa foto. Provane un'altra."
                }
            }
        }
    }
}
