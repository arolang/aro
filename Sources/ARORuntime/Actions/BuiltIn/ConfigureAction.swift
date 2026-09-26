// ============================================================
// ConfigureAction.swift
// ARO Runtime - Configure (ARO-0035) and the settings it can write
// ============================================================
//
// `Configure the <category: key> with <value>.` writes a runtime setting.
// It used to be a fifth verb on `UpdateAction`, which meant one type held four
// jobs — entity update, repository `into` update, repository configuration and
// http-server configuration — and the only statement of what a setting *is*
// was a `switch` in the middle of it.
//
// The settings are declared here instead, in `ConfigurableSettings.all`, so
// there is a list to read and, in time, a list `aro check` can validate
// `Configure the <category: key>` against — today it accepts any key.
//
// Configuring something that is not a declared setting is an entity update:
// `Configure the <validation: timeout> with 30.` builds the dictionary as it
// goes. That is what the verb has always done, and `EntityUpdate` is the part
// it shares with `Update`.

import Foundation
import AROParser

// MARK: - The settings table

/// One runtime setting a `Configure` statement can write.
public struct ConfigurableSetting: Sendable {
    /// What is being configured. The category is the statement's result base:
    /// `http-server` names the server, a `*-repository` name names a repository.
    public enum Category: String, Sendable {
        case httpServer = "http-server"
        case httpClient = "http-client"
        /// The `.store` files behind seeded repositories (ARO-0073).
        case stores
        /// The application itself — the limits that apply across all of it
        /// (ARO-0088 §10a, GitLab #862).
        case application
        case repository
    }

    public let category: Category

    /// Every spelling of the key that selects this setting.
    public let keys: Set<String>

    /// The name this setting is stored and reported under.
    public let canonicalKey: String

    /// What a valid value looks like, for the error message.
    public let expects: String

    public init(category: Category, keys: Set<String>, canonicalKey: String, expects: String) {
        self.category = category
        self.keys = keys
        self.canonicalKey = canonicalKey
        self.expects = expects
    }
}

/// The settings the runtime knows how to apply.
public enum ConfigurableSettings {
    public static let all: [ConfigurableSetting] = [
        ConfigurableSetting(
            category: .httpServer,
            keys: ["max-body", "max-request-body", "maxBody"],
            canonicalKey: "max-body",
            expects: "a size like \"1MB\", \"512KB\", or a byte count"
        ),
        // Application-wide limits (ARO-0088 §10a, GitLab #862). A ceiling and
        // a rate are different limits and both can be set: one request at a
        // time still exceeds a per-minute quota.
        ConfigurableSetting(
            category: .application,
            keys: ["concurrency"],
            canonicalKey: "concurrency",
            expects: "a whole number of concurrent units of work, or 0 for no ceiling"
        ),
        ConfigurableSetting(
            category: .httpClient,
            keys: ["concurrency"],
            canonicalKey: "concurrency",
            expects: "a whole number of concurrent requests, or 0 for no ceiling"
        ),
        ConfigurableSetting(
            category: .httpClient,
            keys: ["rate", "rate-limit"],
            canonicalKey: "rate",
            expects: "a rate like \"10/s\", \"100/minute\" or \"5/2s\""
        ),
        ConfigurableSetting(
            category: .stores,
            keys: ["write-back", "writeback"],
            canonicalKey: "write-back",
            expects: "\"auto\" (write as changes land) or \"manual\" (write only on Commit)"
        ),
        ConfigurableSetting(
            category: .repository,
            keys: ["ttl"],
            canonicalKey: "ttl",
            expects: "a number of seconds"
        ),
        ConfigurableSetting(
            category: .repository,
            keys: ["maxSize"],
            canonicalKey: "maxSize",
            expects: "a maximum number of entries"
        )
    ]

    /// The declared setting a `<category: key>` pair selects, if any.
    public static func setting(category: ConfigurableSetting.Category, key: String) -> ConfigurableSetting? {
        all.first { $0.category == category && $0.keys.contains(key) }
    }

    /// Every key a category accepts — the list a diagnostic would name.
    public static func keys(for category: ConfigurableSetting.Category) -> Set<String> {
        all.filter { $0.category == category }.reduce(into: Set<String>()) { $0.formUnion($1.keys) }
    }

    // MARK: - Applying a setting

    /// `Configure the <http-server: max-body> with "1MB".` (ARO-0035,
    /// GitLab #477). The default ceiling for routes whose contract declares
    /// no `x-aro-max-body`; a route's own declaration still wins, because a
    /// limit belongs with the route it protects.
    ///
    /// Returns `nil` when the statement is not an http-server setting, so the
    /// caller falls through to the entity-update path.
    static func applyHTTPServerSetting(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) throws -> (any Sendable)? {
        guard result.base == ConfigurableSetting.Category.httpServer.rawValue,
              let key = result.specifiers.first else { return nil }

        let raw = context.resolveAny("_literal_")
            ?? context.resolveAny(object.base)
            ?? object.base

        if let bytes = bodyLimitBytes(from: raw) {
            guard let setting = setting(category: .httpServer, key: key) else { return nil }
            switch setting.canonicalKey {
            case "max-body":
                RuntimeDefaults.maxMaterializedBody = bytes
                return ["max-body": bytes] as [String: any Sendable]
            default:
                return nil
            }
        }

        // A value that is not a size is only an error for a key that plainly
        // meant one. `maxBody` is deliberately absent from this test, as it
        // has been since the setting was added: an unparseable value there
        // falls through to the entity-update path rather than failing.
        if key.hasPrefix("max-body") || key == "max-request-body" {
            throw ActionError.invalidInput(
                "Configure the <http-server: \(key)>: \(setting(category: .httpServer, key: "max-body")?.expects ?? "")",
                received: String(describing: raw))
        }
        return nil
    }

    /// Whether the statement configures a file — `Configure the <r> for the
    /// <file: "./run.sh"> with { permissions: "755" }.` (ARO-0036 §10,
    /// GitLab #861). Reaches the file service, so it needs `await`.
    ///
    /// The path is the *object*, matching `Stat`, `Exists` and `Delete`, and
    /// not the result — which is what keeps this out of the way of
    /// `Configure the <category: key>`, where the category is the result.
    static func isFileSetting(object: ObjectDescriptor) -> Bool {
        (object.base == "file" || object.base == "directory") && !object.specifiers.isEmpty
    }

    /// `Configure the <mode> for the <file: "./run.sh"> with { permissions: "755" }.`
    ///
    /// Binds `{ path, permissions, octal, previous }` — the previous mode
    /// because a chmod cannot be read back once it has happened, and a program
    /// that changes a mode usually wants to report what it changed.
    static func applyFileSetting(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        let path = try context.resolveString(
            base: object.base,
            specifiers: object.specifiers,
            excluding: ["file", "directory"],
            field: "a file or directory path",
            action: "Configure"
        )

        let settings = context.resolveAny("_with_") ?? context.resolveAny("_literal_")
        guard let fields = settings as? [String: any Sendable] else {
            throw ActionError.missingRequiredField(
                field: "with { permissions: \"755\" }", action: "Configure the <file: …>")
        }
        guard let raw = fields["permissions"] ?? fields["mode"] else {
            let known = fields.keys.sorted().joined(separator: ", ")
            throw ActionError.invalidInput(
                "Configure the <\(object.base): …>: the only file setting is 'permissions'",
                received: known.isEmpty ? "{}" : known)
        }
        let text = raw as? String ?? String(describing: raw)
        guard let mode = FileMode.parse(text) else {
            throw ActionError.invalidInput(
                "Configure the <\(object.base): …> with { permissions: … }: \(FileMode.expected)",
                received: text)
        }

        guard let fileService = context.service(FileSystemService.self) else {
            throw ActionError.missingService("FileSystemService")
        }
        let previous = try await fileService.setPermissions(path: path, mode: mode)

        var record: [String: any Sendable] = [
            "path": path,
            "permissions": mode.symbolic,
            "octal": mode.octal
        ]
        if let previous {
            record["previous"] = previous.symbolic
        }
        context.bind(result.base, value: record, allowRebind: true)
        return record
    }

    /// `Configure the <application: concurrency> with 8.` and
    /// `Configure the <http-client: rate> with "10/s".` (ARO-0088 §10a,
    /// GitLab #862).
    ///
    /// Returns `nil` when the statement is not one of these, so the caller
    /// falls through to the entity-update path.
    static func applyLimitSetting(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) throws -> (any Sendable)? {
        guard let category = ConfigurableSetting.Category(rawValue: result.base),
              category == .application || category == .httpClient else { return nil }

        let value = context.resolveAny("_literal_")
            ?? context.resolveAny("_with_")
            ?? context.resolveAny(object.base)
            ?? object.base

        // `Configure the <http-client> with { concurrency: 2, rate: "10/s" }.`
        //
        // Two statements naming the same category is a rebind, and the parser
        // says so and points here (GitLab #506) — so the object form has to
        // work, or the hint sends people somewhere that does not.
        guard let key = result.specifiers.first else {
            guard let fields = value as? [String: any Sendable] else { return nil }
            var applied: [String: any Sendable] = [:]
            for (field, fieldValue) in fields {
                guard let one = try applyLimit(category: category, key: field, raw: fieldValue) else {
                    throw ActionError.invalidInput(
                        "Configure the <\(result.base)>: '\(field)' is not a setting "
                        + "(\(keys(for: category).sorted().joined(separator: ", ")))",
                        received: field)
                }
                applied.merge(one) { _, new in new }
            }
            return applied.isEmpty ? nil : applied
        }

        return try applyLimit(category: category, key: key, raw: value)
    }

    /// `Configure the <session> with { idle: "30m", absolute: "12h",
    ///  cookie: "aro_session", same-site: "Strict", secure: false }.`
    /// (ARO-0094 §8.2)
    ///
    /// Every field is optional and anything omitted keeps its default, which
    /// is the conservative one: a 30-minute idle window, a 12-hour ceiling,
    /// `SameSite=Lax`, and TLS required. `secure: false` is the one that has
    /// to be written out, because it is the one that is only ever right on a
    /// developer's machine.
    static func applySessionSetting(key: String?,
                                    object: ObjectDescriptor,
                                    context: ExecutionContext) async throws -> any Sendable {
        let raw = context.resolveAny("_with_")
            ?? context.resolveAny("_literal_")
            ?? context.resolveAny(object.base)

        // One setting at a time, the way every other Configure reads
        // (`Configure the <application: concurrency> with 4.`), or the whole
        // policy in one object when that is less to write.
        let fields: [String: any Sendable]
        if let key {
            fields = [key: raw]
        } else if let object = raw as? [String: any Sendable] {
            fields = object
        } else {
            throw ActionError.missingRequiredField(
                field: "with { idle, absolute, cookie, same-site, secure, origins }",
                action: "Configure the <session>")
        }

        let known = ["idle", "absolute", "cookie", "same-site", "sameSite", "secure", "origins"]
        for name in fields.keys where !known.contains(name) {
            throw ActionError.invalidInput(
                "Configure the <session>: '\(name)' is not a session setting "
                + "(idle, absolute, cookie, same-site, secure, origins)",
                received: name)
        }

        var policy = await SessionService.shared.currentPolicy()
        if let name = fields["cookie"] as? String, !name.isEmpty { policy.cookieName = name }
        if let idle = duration(from: fields["idle"]) { policy.idleTimeout = idle }
        if let absolute = duration(from: fields["absolute"]) { policy.absoluteTimeout = absolute }
        if let sameSite = fields["same-site"] as? String ?? fields["sameSite"] as? String {
            policy.sameSite = sameSite
        }
        if let secure = fields["secure"] as? Bool { policy.requiresSecureTransport = secure }
        if let origins = fields["origins"] as? [any Sendable] {
            policy.allowedOrigins = origins.compactMap { $0 as? String }
        }
        await SessionService.shared.configure(policy)

        return ["cookie": policy.cookieName,
                "idle": policy.idleTimeout,
                "absolute": policy.absoluteTimeout,
                "same-site": policy.sameSite,
                "secure": policy.requiresSecureTransport] as [String: any Sendable]
    }

    /// Seconds from a number, or from `"30m"` / `"12h"` / `"7d"`.
    private static func duration(from raw: (any Sendable)?) -> TimeInterval? {
        if let seconds = raw as? Int { return TimeInterval(seconds) }
        if let seconds = raw as? Double { return seconds }
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return nil
        }
        let units: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
        if let unit = text.last, let multiplier = units[unit],
           let value = Double(text.dropLast()) {
            return value * multiplier
        }
        return Double(text)
    }

    /// Apply one limit. `nil` when `key` names no setting in `category`.
    private static func applyLimit(
        category: ConfigurableSetting.Category,
        key: String,
        raw: any Sendable
    ) throws -> [String: any Sendable]? {
        guard let setting = setting(category: category, key: key) else { return nil }

        switch setting.canonicalKey {
        case "concurrency":
            guard let count = wholeNumber(from: raw), count >= 0 else {
                throw ActionError.invalidInput(
                    "Configure the <\(category.rawValue): \(key)>: \(setting.expects)",
                    received: String(describing: raw))
            }
            if category == .application {
                ApplicationLimits.applicationConcurrency = count
            } else {
                ApplicationLimits.httpConcurrency = count
            }
            return ["concurrency": count]

        case "rate":
            let text = raw as? String ?? String(describing: raw)
            guard let spec = RateSpec.parse(text) else {
                throw ActionError.invalidInput(
                    "Configure the <\(category.rawValue): \(key)>: \(setting.expects)",
                    received: text)
            }
            ApplicationLimits.httpRate = spec
            return ["rate": text,
                    "permits": spec.permits,
                    "interval": spec.interval]

        default:
            return nil
        }
    }

    /// A whole number written as an Int, a Double, or a numeric string.
    static func wholeNumber(from value: any Sendable) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? Double, n == n.rounded() { return Int(n) }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// Whether the statement configures store write-back — reaches an actor.
    static func isStoreSetting(result: ResultDescriptor) -> Bool {
        result.base == ConfigurableSetting.Category.stores.rawValue
            && result.specifiers.first != nil
    }

    /// `Configure the <stores: write-back> with "manual".` (ARO-0073 §5,
    /// GitLab #863) — stop writing on every mutation and write on `Commit`.
    static func applyStoreSetting(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        guard let key = result.specifiers.first,
              let setting = setting(category: .stores, key: key) else {
            return try EntityUpdate.apply(result: result, object: object, context: context)
        }
        let raw = context.resolveAny("_literal_")
            ?? context.resolveAny("_with_")
            ?? context.resolveAny(object.base)
            ?? object.base
        let text = (raw as? String ?? String(describing: raw)).lowercased()
        guard let mode = StoreWriteBackMode(rawValue: text) else {
            throw ActionError.invalidInput(
                "Configure the <stores: \(key)>: \(setting.expects)",
                received: text)
        }
        await StoreFlushRegistry.current?.setWriteBackMode(mode)
        return ["write-back": mode.rawValue] as [String: any Sendable]
    }

    /// Whether the statement configures a repository — `<x-repository: ttl>`.
    /// Storage is an actor, so applying it needs `await`.
    static func isRepositorySetting(result: ResultDescriptor) -> Bool {
        InMemoryRepositoryStorage.isRepositoryName(result.base) && result.specifiers.first != nil
    }

    /// `Configure the <cache-repository: ttl> with 60.`
    ///
    /// Reads whatever the repository is already configured with out of the
    /// bound dictionary, replaces the one field the statement names, and hands
    /// the pair to storage — so configuring `ttl` does not clear `maxSize`.
    static func applyRepositorySetting(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        let entity: any Sendable = context.resolveAny(result.base) ?? [String: any Sendable]()

        let updateValue: any Sendable
        if let literal = context.resolveAny("_literal_") {
            updateValue = literal
        } else if let resolved = context.resolveAny(object.base) {
            updateValue = resolved
        } else {
            updateValue = object.base
        }

        guard let fieldName = result.specifiers.first else { return entity }
        let storage = context.service(RepositoryStorageService.self) ?? context.container.repositoryStorage

        var currentTTL: TimeInterval? = nil
        var currentMaxSize: Int? = nil
        if let existing = context.resolveAny(result.base) as? [String: any Sendable] {
            if let t = existing["ttl"] as? TimeInterval { currentTTL = t }
            else if let t = existing["ttl"] as? Double { currentTTL = t }
            else if let t = existing["ttl"] as? Int { currentTTL = TimeInterval(t) }
            if let m = existing["maxSize"] as? Int { currentMaxSize = m }
            else if let m = existing["maxSize"] as? Double { currentMaxSize = Int(m) }
        }
        switch fieldName {
        case "ttl":
            if let v = updateValue as? Double { currentTTL = v }
            else if let v = updateValue as? Int { currentTTL = TimeInterval(v) }
        case "maxSize":
            if let v = updateValue as? Int { currentMaxSize = v }
            else if let v = updateValue as? Double { currentMaxSize = Int(v) }
        default: break
        }
        await storage.configure(repository: result.base, ttl: currentTTL, maxSize: currentMaxSize)
        var configDict = context.resolveAny(result.base) as? [String: any Sendable] ?? [:]
        configDict[fieldName] = updateValue
        context.bind(result.base, value: configDict, allowRebind: true)
        return configDict
    }

    /// A body limit written as `"1MB"`, `"512KB"` or a plain byte count.
    static func bodyLimitBytes(from value: any Sendable) -> Int? {
        if let text = value as? String { return ByteSize.parse(text) }
        if let number = value as? Int, number > 0 { return number }
        if let number = value as? Double, number > 0 { return Int(number) }
        return nil
    }
}

// MARK: - Configure

/// Writes a runtime setting (ARO-0035).
///
/// `Configure` differs from `Update` in what it means rather than in what it
/// does to a dictionary: the category it names need not exist yet, and a
/// category it has written is *configured*, so a later read of a setting that
/// was never given a value answers nil instead of failing — configuration is
/// optional by definition (ARO-0035 §3.2, GitLab #506). `FeatureSetExecutor`
/// records that mark, because only the owning context outlives the statement.
public struct ConfigureAction: SynchronousAction {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["configure"]
    public static let validPrepositions: Set<Preposition> = [.with, .to, .for, .from, .into]

    public init() {}

    /// Whether a statement's verb is this action's.
    public static func handles(_ verb: String) -> Bool {
        verbs.contains(verb.lowercased())
    }

    public func executeSynchronously(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Repository configuration reaches storage, which is an actor; store
        // write-back reaches the flush service, and a file permission change
        // reaches the file service. All three need `await`.
        if ConfigurableSettings.isRepositorySetting(result: result)
            || ConfigurableSettings.isStoreSetting(result: result)
            || ConfigurableSettings.isFileSetting(object: object) {
            throw NeedsAsyncExecution()
        }

        if let applied = try ConfigurableSettings.applyHTTPServerSetting(
            result: result, object: object, context: context) {
            return applied
        }

        if let applied = try ConfigurableSettings.applyLimitSetting(
            result: result, object: object, context: context) {
            return applied
        }

        // Anything else is an entity update that may create its own dictionary:
        // `Configure the <validation: timeout> with 30.`
        return try EntityUpdate.apply(result: result, object: object, context: context)
    }

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Decided before the synchronous body runs rather than by letting it
        // throw `NeedsAsyncExecution` and starting over — the sync path is
        // still the one the compiled runtime takes directly.
        if ConfigurableSettings.isFileSetting(object: object) {
            try validatePreposition(object.preposition)
            return try await ConfigurableSettings.applyFileSetting(
                result: result, object: object, context: context)
        }
        if ConfigurableSettings.isRepositorySetting(result: result) {
            try validatePreposition(object.preposition)
            return try await ConfigurableSettings.applyRepositorySetting(
                result: result, object: object, context: context)
        }
        if ConfigurableSettings.isStoreSetting(result: result) {
            try validatePreposition(object.preposition)
            return try await ConfigurableSettings.applyStoreSetting(
                result: result, object: object, context: context)
        }
        if result.base == "session" {
            try validatePreposition(object.preposition)
            return try await ConfigurableSettings.applySessionSetting(
                key: result.specifiers.first, object: object, context: context)
        }
        return try executeSynchronously(result: result, object: object, context: context)
    }
}
