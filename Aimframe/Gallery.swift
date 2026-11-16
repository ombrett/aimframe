import ImageIO
import SwiftUI
import UIKit

/// The photos taken with Aimframe. Photos access is add-only, so the app keeps its own copies
/// (in the app's Documents folder, never uploaded) to show them here.
final class GalleryStore: ObservableObject {
    static let shared = GalleryStore()

    struct Item: Identifiable, Hashable {
        let id: String
        let url: URL
        let thumbURL: URL
        let date: Date
    }

    @Published private(set) var items: [Item] = []
    private let folder: URL
    private let queue = DispatchQueue(label: "aimframe.gallery")

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = docs.appendingPathComponent("Gallery", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: self.folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
            let photos = files.filter { !$0.lastPathComponent.hasSuffix("-thumb.jpg") }
            let items: [Item] = photos.compactMap { url in
                let id = url.deletingPathExtension().lastPathComponent
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                return Item(id: id, url: url, thumbURL: self.folder.appendingPathComponent(id + "-thumb.jpg"), date: date)
            }.sorted { $0.date > $1.date }
            DispatchQueue.main.async { self.items = items }
        }
    }

    /// Stores a finished photo (HEIC or JPEG data) with a small thumbnail.
    func add(_ data: Data) {
        queue.async {
            let id = UUID().uuidString
            let ext = Self.isHEIF(data) ? "heic" : "jpg"
            let url = self.folder.appendingPathComponent("\(id).\(ext)")
            do {
                try data.write(to: url, options: .atomic)
                if let thumb = CameraModel.thumbnail(from: data, size: 400), let jpeg = thumb.jpegData(compressionQuality: 0.8) {
                    try jpeg.write(to: self.folder.appendingPathComponent(id + "-thumb.jpg"), options: .atomic)
                }
            } catch {
                return
            }
            self.reload()
        }
    }

    func delete(_ item: Item) {
        queue.async {
            try? FileManager.default.removeItem(at: item.url)
            try? FileManager.default.removeItem(at: item.thumbURL)
            self.reload()
        }
    }

    private static func isHEIF(_ data: Data) -> Bool {
        guard data.count > 12 else { return false }
        let brand = String(data: data.subdata(in: 8..<12), encoding: .ascii) ?? ""
        return ["heic", "heix", "mif1", "msf1", "hevc"].contains(brand)
    }
}

struct GalleryView: View {
    @ObservedObject var store = GalleryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var opened: GalleryStore.Item?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 4)]

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle").font(.system(size: 40)).foregroundColor(Theme.ivoryDim)
                        Text("Qui trovi le foto salvate con Aimframe")
                            .font(Theme.body())
                            .foregroundColor(Theme.ivoryDim)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(store.items) { item in
                                Button { opened = item } label: { GalleryThumb(url: item.thumbURL) }
                                    .accessibilityLabel("Foto del \(item.date.formatted(date: .abbreviated, time: .shortened))")
                            }
                        }
                        .padding(4)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Le tue foto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Chiudi") { dismiss() }.foregroundColor(Theme.yellow)
                }
            }
            .sheet(item: $opened) { item in
                GalleryDetail(item: item) {
                    store.delete(item)
                    opened = nil
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { store.reload() }
    }
}

private struct GalleryThumb: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Color(white: 0.1)
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                if let image = image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .clipped()
            .onAppear {
                guard image == nil else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    let loaded = UIImage(contentsOfFile: url.path)
                    DispatchQueue.main.async { image = loaded }
                }
            }
    }
}

private struct GalleryDetail: View {
    let item: GalleryStore.Item
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                if let image = image {
                    Image(uiImage: image).resizable().scaledToFit().padding(12)
                } else {
                    ProgressView().tint(Theme.ivory)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }.foregroundColor(Theme.ivory)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Elimina", systemImage: "trash")
                    }
                    Spacer()
                    ShareLink(item: item.url) {
                        Label("Condividi", systemImage: "square.and.arrow.up")
                    }
                    .foregroundColor(Theme.yellow)
                }
            }
            .confirmationDialog("Eliminare questa foto da Aimframe? La copia in Foto resta.", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Elimina", role: .destructive) { onDelete() }
                Button("Annulla", role: .cancel) {}
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                // Downsampled for the screen: the file itself stays full size for sharing.
                let loaded = CGImageSourceCreateWithURL(item.url as CFURL, nil).flatMap { source in
                    CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 2000
                    ] as CFDictionary)
                }.map { UIImage(cgImage: $0) }
                DispatchQueue.main.async { image = loaded }
            }
        }
    }
}
