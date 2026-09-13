import Foundation

enum WindowsEnvironment {
    /// Shared callers set uppercase keys. Prefer those explicit overrides over inherited mixed-case keys.
    static func canonicalized(_ environment: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for key in environment.keys.sorted() {
            let canonical = key.uppercased()
            if result[canonical] == nil || key == canonical { result[canonical] = environment[key] }
        }
        return result
    }

    static func value(_ name: String, in environment: [String: String]) -> String? {
        self.canonicalized(environment)[name.uppercased()]
    }

    static func pathEntries(_ value: String) -> [String] {
        value.split(separator: ";").compactMap { entry in
            var path = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 {
                path = String(path.dropFirst().dropLast())
            }
            return path.isEmpty ? nil : path
        }
    }

    static func effectivePATH(environment: [String: String], additionalPaths: [String] = []) -> String {
        var paths = additionalPaths + self.pathEntries(self.value("PATH", in: environment) ?? "")
        if paths.isEmpty {
            let root = self.value("SystemRoot", in: environment) ?? "C:\\Windows"
            paths = [root + "\\System32", root]
        }
        var seen = Set<String>()
        return paths.filter { path in
            !path.isEmpty && seen.insert(path.replacingOccurrences(of: "/", with: "\\").uppercased()).inserted
        }.joined(separator: ";")
    }

    static func findExecutable(
        _ name: String,
        paths: [String],
        environment: [String: String],
        fileManager: FileManager = .default,
        allowed: (String, FileManager) -> Bool = { _, _ in true }) -> String?
    {
        let extensions = self.pathEntries(self.value("PATHEXT", in: environment) ?? ".COM;.EXE;.BAT;.CMD")
            .filter { $0.hasPrefix(".") && !$0.contains("/") && !$0.contains("\\") }
        let names = URL(fileURLWithPath: name).pathExtension.isEmpty
            ? extensions.map { name + $0 } + [name]
            : [name]
        let directories = name.contains("/") || name.contains("\\") ? [""] : paths
        for directory in directories {
            for name in names {
                let candidate = directory.isEmpty ? name : URL(fileURLWithPath: directory)
                    .appendingPathComponent(name).path
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory),
                   !isDirectory.boolValue, allowed(candidate, fileManager)
                {
                    return candidate
                }
            }
        }
        return nil
    }
}
