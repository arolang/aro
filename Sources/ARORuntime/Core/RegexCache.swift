// ============================================================
// RegexCache.swift
// ARO Runtime - Compiled NSRegularExpression Cache
// ============================================================

import Foundation

/// Thread-safe cache for compiled `NSRegularExpression` instances.
///
/// Keyed by (pattern, options) so identical regex compilations are reused.
/// Uses `NSCache` for automatic memory-pressure eviction.
public final class RegexCache: Sendable {
    public static let shared = RegexCache()

    private let cache = NSCacheWrapper()

    public init() {}

    /// Return a cached `NSRegularExpression`, compiling and caching on first access.
    public func regex(
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) throws -> NSRegularExpression {
        let key = "\(pattern)\0\(options.rawValue)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let compiled = try NSRegularExpression(pattern: pattern, options: options)
        cache.setObject(compiled, forKey: key)
        return compiled
    }
}

/// Thin `Sendable` wrapper around `NSCache` (which is already thread-safe).
private final class NSCacheWrapper: @unchecked Sendable {
    private let underlying = NSCache<NSString, NSRegularExpression>()

    init() {
        underlying.countLimit = 512
    }

    func object(forKey key: NSString) -> NSRegularExpression? {
        underlying.object(forKey: key)
    }

    func setObject(_ obj: NSRegularExpression, forKey key: NSString) {
        underlying.setObject(obj, forKey: key)
    }
}
