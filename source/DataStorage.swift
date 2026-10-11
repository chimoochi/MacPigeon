import Foundation

enum DataStorage {
    private static let migrationLock = NSLock()
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    static var root: URL { support.appendingPathComponent("MacPigeon", isDirectory: true) }

    // Copy legacy data once. Existing destination files take precedence, and the
    // old directory remains available as a recovery copy after an upgrade.
    static func prepare(in support: URL = DataStorage.support) throws {
        migrationLock.lock()
        defer { migrationLock.unlock() }
        let files = FileManager.default
        let root = support.appendingPathComponent("MacPigeon", isDirectory: true)
        let old = support.appendingPathComponent("MacPigeon Lab", isDirectory: true)
        try privateDirectory(root)
        let marker = root.appendingPathComponent(".legacy-data-migrated-v1")
        if files.fileExists(atPath: marker.path) { return }
        if files.fileExists(atPath: old.path) {
            guard try files.attributesOfItem(atPath: old.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            for source in try files.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) {
                let name = source.lastPathComponent == "SelectedTest" ? "Delivery" : source.lastPathComponent
                try copyMissing(source, to: root.appendingPathComponent(name))
            }
        }
        try Data("1\n".utf8).write(to: marker, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    }

    private static func privateDirectory(_ url: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: url.path) {
            guard try files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw CocoaError(.fileWriteFileExists)
            }
        } else {
            try files.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func copyMissing(_ source: URL, to destination: URL) throws {
        let files = FileManager.default
        let type = try files.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType
        guard type == .typeDirectory || type == .typeRegular else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        if type == .typeDirectory {
            try privateDirectory(destination)
            for child in try files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try copyMissing(child, to: destination.appendingPathComponent(child.lastPathComponent))
            }
        } else {
            if files.fileExists(atPath: destination.path) {
                guard try files.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType == .typeRegular else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                return
            }
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".migration-" + UUID().uuidString)
            defer { try? files.removeItem(at: temporary) }
            try files.copyItem(at: source, to: temporary)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try files.moveItem(at: temporary, to: destination)
        }
    }
}
