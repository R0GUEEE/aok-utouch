import Foundation
import os

/// The guest that ships inside the app.
///
/// The IPA carries a gzipped disc image; the first time the machine is started
/// it is unpacked into Application Support, where it lives unbacked-up and out
/// of the user's Documents. Importing an image by hand still wins, and a reset
/// puts the bundled one back.
enum GuestImage {
    static let bundledName = "guest.img.gz"
    static let installedName = "guest.img"

    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AokVM", isDirectory: true)
    }

    static var url: URL { directory.appendingPathComponent(installedName) }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static var bundledURL: URL? {
        Bundle.main.url(forResource: "guest", withExtension: "img.gz")
    }

    /// What the build called this guest, from guest.json in the bundle.
    static var bundledLabel: String? {
        guard let url = Bundle.main.url(forResource: "guest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String, !name.isEmpty
        else { return nil }
        return name
    }

    static var installedSize: Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Unpacks the bundled image if it is not there yet. Blocking; call it off
    /// the main thread. `progress` is called with 0...1 as compressed input is
    /// consumed, roughly nine times a second.
    static func installIfNeeded(progress: (Double) -> Void = { _ in }) throws {
        if isInstalled { return }
        guard let source = bundledURL else {
            throw Failure(reason: "this build has no bundled guest image")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let partial = directory.appendingPathComponent(installedName + ".partial")
        try? fm.removeItem(at: partial)
        guard fm.createFile(atPath: partial.path, contents: nil) else {
            throw Failure(reason: "cannot create \(partial.lastPathComponent)")
        }
        let output = try FileHandle(forWritingTo: partial)

        let attributes = try? fm.attributesOfItem(atPath: source.path)
        let compressedSize = (attributes?[.size] as? NSNumber)?.doubleValue ?? 0
        guard let gz = source.path.withCString({ gzopen($0, "rb") }) else {
            throw Failure(reason: "cannot open the bundled image")
        }
        defer { gzclose(gz) }

        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var written: Int64 = 0
        var lastReport = Date.distantPast

        while true {
            let read = buffer.withUnsafeMutableBytes { raw in
                gzread(gz, raw.baseAddress, UInt32(raw.count))
            }
            if read < 0 {
                try? output.close()
                try? fm.removeItem(at: partial)
                throw Failure(reason: "the bundled image is corrupt")
            }
            if read == 0 { break }
            try output.write(contentsOf: buffer[0..<Int(read)])
            written += Int64(read)

            let now = Date()
            if compressedSize > 0, now.timeIntervalSince(lastReport) > 0.1 {
                lastReport = now
                progress(min(1.0, Double(gzoffset(gz)) / compressedSize))
            }
        }
        try output.close()

        // Never let a half-written guest reach the engine.
        guard written > 64 * 1024 * 1024 else {
            try? fm.removeItem(at: partial)
            throw Failure(reason: "unpacked image is only \(written) bytes")
        }
        try? fm.removeItem(at: url)
        try fm.moveItem(at: partial, to: url)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
        progress(1.0)
    }

    static func reset() throws {
        try? FileManager.default.removeItem(at: url)
    }
}
