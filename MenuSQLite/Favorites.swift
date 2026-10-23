import Foundation

/// A database kept under a name of one's own: a file on this Mac (its path) or on a server (a
/// RemoteLocation key), as the recent list keeps them.
struct Favorite: Equatable {
    var id = UUID()
    var name: String
    var key: String

    var remote: RemoteLocation? { RemoteLocation(key: key) }

    /// Where it is, as the list shows it: ~/folder/file.sqlite, or server:path.
    var summary: String {
        remote.map { "\($0.destination):\($0.path)" } ?? (key as NSString).abbreviatingWithTildeInPath
    }
}

/// The saved favorites, in the order they were put in, kept in the app's defaults.
enum Favorites {
    private static let defaultsKey = "menusqlite.favorites"

    static var all: [Favorite] {
        get {
            (UserDefaults.standard.array(forKey: defaultsKey) as? [[String: String]] ?? []).compactMap { entry in
                guard let name = entry["name"], let key = entry["key"], !key.isEmpty else { return nil }
                return Favorite(id: entry["id"].flatMap(UUID.init(uuidString:)) ?? UUID(), name: name, key: key)
            }
        }
        set {
            UserDefaults.standard.set(newValue.map { ["id": $0.id.uuidString, "name": $0.name, "key": $0.key] }, forKey: defaultsKey)
        }
    }

    /// The favorite for exactly this database, if there is one.
    static func matching(_ key: String) -> Favorite? {
        all.first { $0.key == key }
    }

    /// A name to start from: the file's name, without its extension.
    static func suggestedName(for key: String) -> String {
        let path = RemoteLocation(key: key)?.path ?? key
        return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
