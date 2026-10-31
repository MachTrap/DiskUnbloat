import Foundation
import Darwin

public func canonicalURL(_ url: URL) -> URL {
    let path = url.path.withCString { pointer in realpath(pointer, nil).map { value in defer { free(value) }; return String(cString: value) } }
    return URL(fileURLWithPath: path ?? url.standardizedFileURL.path)
}
