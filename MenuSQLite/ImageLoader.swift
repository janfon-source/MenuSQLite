import AppKit

/// Loads the images a Markdown preview shows and keeps them, so typing doesn't load them again.
/// Files (and data: URLs) load at once, and again when the file changes. Web images load in the
/// background; `didLoad` is posted when one arrives, so the preview can render again.
final class ImageLoader {
    static let shared = ImageLoader()
    static let didLoad = Notification.Name("MenuNoteImageLoaderDidLoad")

    enum State {
        case loaded(NSImage)
        case loading
        case failed
    }

    private var web: [URL: State] = [:]
    private var files: [URL: (modified: Date?, state: State)] = [:]

    func image(for url: URL) -> State {
        if url.isFileURL {
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if let cached = files[url], cached.modified == modified { return cached.state }
            let state = Self.decode(try? Data(contentsOf: url))
            files[url] = (modified, state)
            return state
        }
        if let cached = web[url] { return cached }
        switch url.scheme?.lowercased() {
        case "data":
            web[url] = Self.decode(try? Data(contentsOf: url))
        case "https", "http":
            web[url] = .loading
            URLSession.shared.dataTask(with: url) { data, _, _ in
                DispatchQueue.main.async {
                    self.web[url] = Self.decode(data)
                    NotificationCenter.default.post(name: Self.didLoad, object: self)
                }
            }.resume()
        default:
            web[url] = .failed
        }
        return web[url]!
    }

    private static func decode(_ data: Data?) -> State {
        data.flatMap(NSImage.init(data:)).map(State.loaded) ?? .failed
    }
}
