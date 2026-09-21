// ============================================================
// PluginDirectory.swift
// ARORuntime — one plugin directory, found the same way everywhere (#848)
// ============================================================
//
// A project's plugins used to be found by two loaders looking for two
// directory names that differ only in case:
//
//   * `Plugins/` — one subdirectory per plugin, each with a
//     `plugin.yaml`. What `aro add` installs and `aro new plugin`
//     scaffolds.
//   * `plugins/` — loose `.swift` files, prebuilt libraries, and Swift
//     packages with no manifest.
//
// On macOS and Windows those are the same directory, so whichever
// spelling a project used, both loaders walked it and one of them
// worked. On Linux — every CI runner and every Linux user — they are
// two directories, and only the matching loader ran. Three examples
// shipped the lowercase spelling and appeared to work everywhere
// because the developers were on macOS.
//
// That is a trap laid on exactly the platform the project ships CI on,
// and the split between "loose files" and "managed plugins" is not a
// distinction anybody asked for. So there is one directory now. This
// resolves it, canonically, and says which spelling it found so the
// caller can deprecate the old one.
//
// The subtlety worth naming: on a case-insensitive filesystem both
// names exist as far as `fileExists` is concerned, and returning two
// directories would load every plugin twice. So when both appear to
// exist, they are compared by file identity rather than by path, and
// the same directory under two names is reported once.

import Foundation

/// Where a project keeps its plugins.
public enum PluginDirectory {

    /// The directory name plugins belong in.
    public static let canonicalName = "Plugins"

    /// The spelling accepted for one release, with a warning.
    public static let legacyName = "plugins"

    /// Which spelling was found on disk.
    public enum Spelling: Sendable, Equatable {
        case canonical
        case legacy
    }

    public struct Resolved: Sendable, Equatable {
        public let url: URL
        public let spelling: Spelling

        public init(url: URL, spelling: Spelling) {
            self.url = url
            self.spelling = spelling
        }
    }

    /// The plugin directory of `project`, or `nil` when it has none.
    ///
    /// `Plugins/` wins when both spellings name distinct directories,
    /// because it is the one `aro add` writes to and the one every
    /// other tool assumes.
    public static func resolve(in project: URL) -> Resolved? {
        let canonical = project.appendingPathComponent(canonicalName)
        let legacy = project.appendingPathComponent(legacyName)
        let hasCanonical = isDirectory(canonical)
        let hasLegacy = isDirectory(legacy)

        if hasCanonical && hasLegacy {
            // Same directory under two names — a case-insensitive
            // filesystem. Report it once, as the canonical spelling,
            // so nothing loads twice.
            if sameDirectory(canonical, legacy) {
                return Resolved(url: canonical, spelling: .canonical)
            }
            // Genuinely two directories. The canonical one wins; the
            // caller is told the other exists so it can say so.
            return Resolved(url: canonical, spelling: .canonical)
        }
        if hasCanonical { return Resolved(url: canonical, spelling: .canonical) }
        if hasLegacy { return Resolved(url: legacy, spelling: .legacy) }
        return nil
    }

    /// A second plugin directory that will be ignored, if one exists.
    ///
    /// Only possible on a case-sensitive filesystem, where a project
    /// can genuinely hold both. Worth a warning: on macOS the same
    /// project has one directory and behaves differently.
    public static func shadowedDirectory(in project: URL) -> URL? {
        let canonical = project.appendingPathComponent(canonicalName)
        let legacy = project.appendingPathComponent(legacyName)
        guard isDirectory(canonical), isDirectory(legacy),
              !sameDirectory(canonical, legacy)
        else { return nil }
        return legacy
    }

    /// The deprecation notice for a project still using `plugins/`.
    public static func deprecationWarning(for project: URL) -> String {
        """
        [plugins] '\(legacyName)/' is deprecated — rename it to \
        '\(canonicalName)/'. Both names work in this release, but they are \
        the same directory only on macOS and Windows; on Linux they are two, \
        and plugins in the wrong one are silently not loaded. \
        (project: \(project.lastPathComponent), GitLab #848)
        """
    }

    // MARK: - Filesystem

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path,
                                                    isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    /// Whether two paths name the same directory.
    ///
    /// By file identity rather than by string: on a case-insensitive
    /// volume `Plugins` and `plugins` are different strings and the
    /// same inode, which is the entire bug this file exists for.
    static func sameDirectory(_ a: URL, _ b: URL) -> Bool {
        // Symlinks first: a link's file identity describes the link,
        // not what it points at, so asking without resolving would call
        // `Plugins` and a symlink to `Plugins` two different places.
        let a = a.resolvingSymlinksInPath()
        let b = b.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard
            let idA = try? a.resourceValues(forKeys: keys).fileResourceIdentifier,
            let idB = try? b.resourceValues(forKeys: keys).fileResourceIdentifier
        else {
            // No identity available — fall back to comparing resolved
            // paths, which still catches a symlink.
            return a.resolvingSymlinksInPath().standardizedFileURL.path
                == b.resolvingSymlinksInPath().standardizedFileURL.path
        }
        return idA.isEqual(idB)
    }
}
