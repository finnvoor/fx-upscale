import Foundation

public extension URL {
    func renamed(_ transform: (_ currentName: String) -> String) -> URL {
        deletingLastPathComponent()
            .appending(component: transform(deletingPathExtension().lastPathComponent))
            .appendingPathExtension(pathExtension)
    }
}
