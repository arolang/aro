// ============================================================
// ActionBridge.swift
// AROCRuntime - C-callable Action Interface
// ============================================================

import Foundation
import AROParser
import ARORuntime

// MARK: - Descriptor Types for C Interop

/// C-compatible result descriptor (defined in C header)
/// struct AROResultDescriptor {
///     const char* base;
///     const char** specifiers;
///     int specifier_count;
/// };

/// C-compatible object descriptor (defined in C header)
/// struct AROObjectDescriptor {
///     const char* base;
///     int preposition;
///     const char** specifiers;
///     int specifier_count;
/// };

// MARK: - Helper Functions

private func toResultDescriptor(_ ptr: UnsafeRawPointer) -> ResultDescriptor {
    // Read raw C struct with proper alignment:
    // struct AROResultDescriptor {
    //     const char* base;        // offset 0, 8 bytes
    //     const char** specifiers; // offset 8, 8 bytes
    //     int specifier_count;     // offset 16, 4 bytes
    // };
    let basePtr = ptr.load(as: UnsafePointer<CChar>?.self)
    let base = basePtr.map { String(cString: $0) } ?? ""

    let specsPtr = ptr.load(fromByteOffset: 8, as: UnsafeMutablePointer<UnsafePointer<CChar>?>?.self)
    let specCount = ptr.load(fromByteOffset: 16, as: Int32.self)

    var specifiers: [String] = []
    if let specs = specsPtr {
        for i in 0..<Int(specCount) {
            if let spec = specs[i] {
                specifiers.append(String(cString: spec))
            }
        }
    }

    let dummyLocation = SourceLocation(line: 0, column: 0, offset: 0)
    let dummySpan = SourceSpan(at: dummyLocation)
    return ResultDescriptor(base: base, specifiers: specifiers, span: dummySpan)
}

private func toObjectDescriptor(_ ptr: UnsafeRawPointer) -> ObjectDescriptor {
    // Read raw C struct with proper alignment:
    // struct AROObjectDescriptor {
    //     const char* base;        // offset 0, 8 bytes
    //     int preposition;         // offset 8, 4 bytes
    //     // 4 bytes padding for pointer alignment
    //     const char** specifiers; // offset 16, 8 bytes
    //     int specifier_count;     // offset 24, 4 bytes
    // };
    let basePtr = ptr.load(as: UnsafePointer<CChar>?.self)
    let base = basePtr.map { String(cString: $0) } ?? ""

    let prepInt = ptr.load(fromByteOffset: 8, as: Int32.self)
    let preposition = intToPreposition(Int(prepInt)) ?? .from

    // Account for padding: specifiers is at offset 16, not 12
    let specsPtr = ptr.load(fromByteOffset: 16, as: UnsafeMutablePointer<UnsafePointer<CChar>?>?.self)
    let specCount = ptr.load(fromByteOffset: 24, as: Int32.self)

    var specifiers: [String] = []
    if let specs = specsPtr {
        for i in 0..<Int(specCount) {
            if let spec = specs[i] {
                specifiers.append(String(cString: spec))
            }
        }
    }

    let dummyLocation = SourceLocation(line: 0, column: 0, offset: 0)
    let dummySpan = SourceSpan(at: dummyLocation)
    return ObjectDescriptor(preposition: preposition, base: base, specifiers: specifiers, span: dummySpan)
}

private func intToPreposition(_ value: Int) -> Preposition? {
    switch value {
    case 1: return .from
    case 2: return .for
    case 3: return .with
    case 4: return .to
    case 5: return .into
    case 6: return .via
    case 7: return .against
    default: return nil
    }
}

private func getContext(_ contextPtr: UnsafeMutableRawPointer?) -> AROCContextHandle? {
    guard let ptr = contextPtr else { return nil }
    return Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()
}

private func boxResult(_ value: any Sendable) -> UnsafeMutableRawPointer {
    let boxed = AROCValue(value: value)
    return UnsafeMutableRawPointer(Unmanaged.passRetained(boxed).toOpaque())
}

// MARK: - REQUEST Actions

/// Extract action - extract data from a source
@_cdecl("aro_action_extract")
public func aro_action_extract(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr,
          let object = objectPtr else { return nil }

    let resultDesc = toResultDescriptor(result)
    let objectDesc = toObjectDescriptor(object)

    // Resolve source
    let sourceValue = ctxHandle.context.resolveAny(objectDesc.base)

    // Extract based on specifiers
    var extracted: any Sendable = sourceValue ?? ""

    if let dict = sourceValue as? [String: any Sendable],
       let key = objectDesc.specifiers.first {
        extracted = dict[key] ?? ""
    }

    // Bind result
    ctxHandle.context.bind(resultDesc.base, value: extracted)

    return boxResult(extracted)
}

/// Fetch action - fetch data from external source
@_cdecl("aro_action_fetch")
public func aro_action_fetch(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr,
          let object = objectPtr else { return nil }

    let resultDesc = toResultDescriptor(result)
    let objectDesc = toObjectDescriptor(object)

    // For now, return a placeholder - actual HTTP fetch would be async
    let fetchResult = FetchResult(url: objectDesc.base, data: nil, error: "Not implemented in sync context")
    ctxHandle.context.bind(resultDesc.base, value: fetchResult)

    return boxResult(fetchResult)
}

struct FetchResult: Sendable {
    let url: String
    let data: String?
    let error: String?
}

/// Retrieve action - retrieve from repository
@_cdecl("aro_action_retrieve")
public func aro_action_retrieve(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr,
          let object = objectPtr else { return nil }

    let resultDesc = toResultDescriptor(result)
    let objectDesc = toObjectDescriptor(object)

    // Resolve from context
    let value = ctxHandle.context.resolveAny(objectDesc.base) ?? ""
    ctxHandle.context.bind(resultDesc.base, value: value)

    return boxResult(value)
}

/// Parse action - parse data
@_cdecl("aro_action_parse")
public func aro_action_parse(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr,
          let object = objectPtr else { return nil }

    let resultDesc = toResultDescriptor(result)
    let objectDesc = toObjectDescriptor(object)

    let sourceValue = ctxHandle.context.resolveAny(objectDesc.base)
    var parsed: any Sendable = sourceValue ?? ""

    // Try JSON parsing if string
    if let str = sourceValue as? String,
       let data = str.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        // Convert to Sendable dict - only include string values for now
        var sendableDict: [String: any Sendable] = [:]
        for (key, value) in json {
            if let strVal = value as? String {
                sendableDict[key] = strVal
            } else if let intVal = value as? Int {
                sendableDict[key] = intVal
            } else if let boolVal = value as? Bool {
                sendableDict[key] = boolVal
            } else if let doubleVal = value as? Double {
                sendableDict[key] = doubleVal
            }
        }
        parsed = sendableDict
    }

    ctxHandle.context.bind(resultDesc.base, value: parsed)
    return boxResult(parsed)
}

/// Read action - read from file
@_cdecl("aro_action_read")
public func aro_action_read(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr,
          let object = objectPtr else { return nil }

    let resultDesc = toResultDescriptor(result)
    let objectDesc = toObjectDescriptor(object)

    // Get file path
    let path: String
    if let resolvedPath: String = ctxHandle.context.resolve(objectDesc.base) {
        path = resolvedPath
    } else {
        path = objectDesc.base
    }

    // Read file
    var content: String = ""
    if let fileContent = try? String(contentsOfFile: path, encoding: .utf8) {
        content = fileContent
    }

    ctxHandle.context.bind(resultDesc.base, value: content)
    return boxResult(content)
}

// MARK: - OWN Actions

/// Compute action
@_cdecl("aro_action_compute")
public func aro_action_compute(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr,
          let object = objectPtr else { return nil }

    let resultDesc = toResultDescriptor(result)
    let objectDesc = toObjectDescriptor(object)

    let input = ctxHandle.context.resolveAny(objectDesc.base)
    let computationName = resultDesc.specifiers.first ?? "identity"

    var computed: any Sendable = input ?? ""

    switch computationName.lowercased() {
    case "hash":
        if let str = input as? String {
            computed = str.hashValue
        }
    case "length", "count":
        if let str = input as? String {
            computed = str.count
        } else if let arr = input as? [any Sendable] {
            computed = arr.count
        }
    case "uppercase":
        if let str = input as? String {
            computed = str.uppercased()
        }
    case "lowercase":
        if let str = input as? String {
            computed = str.lowercased()
        }
    default:
        break
    }

    ctxHandle.context.bind(resultDesc.base, value: computed)
    return boxResult(computed)
}

/// Validate action
@_cdecl("aro_action_validate")
public func aro_action_validate(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr,
          let object = objectPtr else { return nil }

    let resultDesc = toResultDescriptor(result)
    let objectDesc = toObjectDescriptor(object)

    let value = ctxHandle.context.resolveAny(objectDesc.base)
    let ruleName = resultDesc.specifiers.first ?? "required"

    var isValid = true

    switch ruleName.lowercased() {
    case "required", "exists":
        if value == nil {
            isValid = false
        } else if let str = value as? String, str.isEmpty {
            isValid = false
        }
    case "nonempty":
        if let str = value as? String {
            isValid = !str.isEmpty
        }
    case "email":
        if let str = value as? String {
            isValid = str.contains("@") && str.contains(".")
        } else {
            isValid = false
        }
    case "numeric":
        if value is Int || value is Double {
            isValid = true
        } else if let str = value as? String {
            isValid = Double(str) != nil
        } else {
            isValid = false
        }
    default:
        break
    }

    let validationResult = ValidationResultBridge(isValid: isValid, rule: ruleName)
    ctxHandle.context.bind(resultDesc.base, value: validationResult)
    return boxResult(validationResult)
}

struct ValidationResultBridge: Sendable {
    let isValid: Bool
    let rule: String
}

/// Compare action
@_cdecl("aro_action_compare")
public func aro_action_compare(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr,
          let object = objectPtr else { return nil }

    let resultDesc = toResultDescriptor(result)
    let objectDesc = toObjectDescriptor(object)

    let lhs = ctxHandle.context.resolveAny(resultDesc.base)
    let rhs = ctxHandle.context.resolveAny(objectDesc.base)

    var matches = false

    if let lhsStr = lhs as? String, let rhsStr = rhs as? String {
        matches = lhsStr == rhsStr
    } else if let lhsInt = lhs as? Int, let rhsInt = rhs as? Int {
        matches = lhsInt == rhsInt
    } else if let lhsBool = lhs as? Bool, let rhsBool = rhs as? Bool {
        matches = lhsBool == rhsBool
    }

    let compResult = ComparisonResultBridge(matches: matches)
    return boxResult(compResult)
}

struct ComparisonResultBridge: Sendable {
    let matches: Bool
}

/// Transform action
@_cdecl("aro_action_transform")
public func aro_action_transform(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr,
          let object = objectPtr else { return nil }

    let resultDesc = toResultDescriptor(result)
    let objectDesc = toObjectDescriptor(object)

    let value = ctxHandle.context.resolveAny(objectDesc.base)
    let transformType = resultDesc.specifiers.first ?? "identity"

    var transformed: any Sendable = value ?? ""

    switch transformType.lowercased() {
    case "string":
        transformed = String(describing: value ?? "")
    case "int", "integer":
        if let i = value as? Int {
            transformed = i
        } else if let s = value as? String, let i = Int(s) {
            transformed = i
        }
    case "double", "float":
        if let d = value as? Double {
            transformed = d
        } else if let s = value as? String, let d = Double(s) {
            transformed = d
        }
    case "bool", "boolean":
        if let b = value as? Bool {
            transformed = b
        } else if let s = value as? String {
            transformed = s.lowercased() == "true" || s == "1"
        }
    default:
        break
    }

    ctxHandle.context.bind(resultDesc.base, value: transformed)
    return boxResult(transformed)
}

/// Create action
@_cdecl("aro_action_create")
public func aro_action_create(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr,
          let object = objectPtr else { return nil }

    let resultDesc = toResultDescriptor(result)
    let objectDesc = toObjectDescriptor(object)

    let sourceData = ctxHandle.context.resolveAny(objectDesc.base) ?? ""

    // Bind the actual value directly, not a wrapper struct
    ctxHandle.context.bind(resultDesc.base, value: sourceData)
    return boxResult(sourceData)
}

struct CreatedEntityBridge: Sendable {
    let type: String
    let data: (any Sendable)?
}

/// Update action
@_cdecl("aro_action_update")
public func aro_action_update(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr,
          let object = objectPtr else { return nil }

    let resultDesc = toResultDescriptor(result)
    let objectDesc = toObjectDescriptor(object)

    let entity = ctxHandle.context.resolveAny(resultDesc.base)
    let updates = ctxHandle.context.resolveAny(objectDesc.base)

    // Simple merge if both are dictionaries
    var updated: any Sendable = entity ?? updates ?? ""

    if var dict = entity as? [String: any Sendable],
       let updateDict = updates as? [String: any Sendable] {
        for (key, value) in updateDict {
            dict[key] = value
        }
        updated = dict
    }

    ctxHandle.context.bind(resultDesc.base, value: updated)
    return boxResult(updated)
}

// MARK: - RESPONSE Actions

/// Return action
@_cdecl("aro_action_return")
public func aro_action_return(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr,
          let object = objectPtr else { return nil }

    let resultDesc = toResultDescriptor(result)
    let objectDesc = toObjectDescriptor(object)

    var data: [String: any Sendable] = [:]
    for specifier in objectDesc.specifiers {
        if let value = ctxHandle.context.resolveAny(specifier) {
            data[specifier] = value
        }
    }

    let response = ResponseBridge(
        status: resultDesc.base,
        reason: objectDesc.base,
        data: data
    )

    ctxHandle.context.setResponse(Response(status: resultDesc.base, reason: objectDesc.base, data: [:]))
    return boxResult(response)
}

struct ResponseBridge: Sendable {
    let status: String
    let reason: String
    let data: [String: any Sendable]
}

/// Throw action
@_cdecl("aro_action_throw")
public func aro_action_throw(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let result = resultPtr,
          let object = objectPtr else { return nil }

    let resultDesc = toResultDescriptor(result)
    let objectDesc = toObjectDescriptor(object)

    // In compiled code, we return an error marker
    let error = ErrorBridge(type: resultDesc.base, reason: objectDesc.base)
    return boxResult(error)
}

struct ErrorBridge: Sendable {
    let type: String
    let reason: String
}

/// Emit action - emit an event
@_cdecl("aro_action_emit")
public func aro_action_emit(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr,
          let object = objectPtr else { return nil }

    let resultDesc = toResultDescriptor(result)
    let objectDesc = toObjectDescriptor(object)

    let eventData = ctxHandle.context.resolveAny(objectDesc.base)
    ctxHandle.context.emit(CustomRuntimeEvent(
        type: resultDesc.base,
        data: eventData.map { String(describing: $0) }
    ))

    return boxResult(true)
}

/// Log action
@_cdecl("aro_action_log")
public func aro_action_log(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr else { return nil }

    let resultDesc = toResultDescriptor(result)

    let message: String
    if let value: String = ctxHandle.context.resolve(resultDesc.base) {
        message = value
    } else if let value = ctxHandle.context.resolveAny(resultDesc.base) {
        message = String(describing: value)
    } else {
        message = resultDesc.base
    }

    print("[ARO] \(message)")
    return boxResult(message)
}

/// Store action
@_cdecl("aro_action_store")
public func aro_action_store(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr,
          let object = objectPtr else { return nil }

    let resultDesc = toResultDescriptor(result)
    let objectDesc = toObjectDescriptor(object)

    let data = ctxHandle.context.resolveAny(resultDesc.base)
    let repoName = objectDesc.base

    // Emit store event
    ctxHandle.context.emit(CustomRuntimeEvent(
        type: "data.stored",
        data: "repository=\(repoName)"
    ))

    return boxResult(StoreResultBridge(repository: repoName, success: true))
}

struct StoreResultBridge: Sendable {
    let repository: String
    let success: Bool
}

/// Write action
@_cdecl("aro_action_write")
public func aro_action_write(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr,
          let object = objectPtr else { return nil }

    let resultDesc = toResultDescriptor(result)
    let objectDesc = toObjectDescriptor(object)

    let content: String
    if let value: String = ctxHandle.context.resolve(resultDesc.base) {
        content = value
    } else if let value = ctxHandle.context.resolveAny(resultDesc.base) {
        content = String(describing: value)
    } else {
        content = ""
    }

    let path: String
    if let resolvedPath: String = ctxHandle.context.resolve(objectDesc.base) {
        path = resolvedPath
    } else {
        path = objectDesc.base
    }

    // Write file
    var success = false
    do {
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        success = true
    } catch {
        print("[ARO] Write error: \(error)")
    }

    return boxResult(WriteResultBridge(path: path, success: success))
}

struct WriteResultBridge: Sendable {
    let path: String
    let success: Bool
}

/// Publish action
@_cdecl("aro_action_publish")
public func aro_action_publish(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr,
          let object = objectPtr else { return nil }

    let resultDesc = toResultDescriptor(result)
    let objectDesc = toObjectDescriptor(object)

    let value = ctxHandle.context.resolveAny(objectDesc.base)

    ctxHandle.context.emit(CustomRuntimeEvent(
        type: "variable.published",
        data: "external=\(resultDesc.base),internal=\(objectDesc.base)"
    ))

    return boxResult(value ?? "")
}

/// Send action
@_cdecl("aro_action_send")
public func aro_action_send(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr,
          let object = objectPtr else { return nil }

    let resultDesc = toResultDescriptor(result)
    let objectDesc = toObjectDescriptor(object)

    let data = ctxHandle.context.resolveAny(resultDesc.base)
    let destination = objectDesc.base

    ctxHandle.context.emit(CustomRuntimeEvent(
        type: "message.sent",
        data: "destination=\(destination)"
    ))

    return boxResult(SendResultBridge(destination: destination, success: true))
}

struct SendResultBridge: Sendable {
    let destination: String
    let success: Bool
}

// MARK: - SERVER Actions

/// Start action
@_cdecl("aro_action_start")
public func aro_action_start(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr,
          let object = objectPtr else { return nil }

    let resultDesc = toResultDescriptor(result)
    let objectDesc = toObjectDescriptor(object)

    let serverType = resultDesc.base.lowercased()
    let port = Int(objectDesc.specifiers.first ?? "8080") ?? 8080

    ctxHandle.context.emit(CustomRuntimeEvent(
        type: "service.start.requested",
        data: "type=\(serverType),port=\(port)"
    ))

    return boxResult(ServerStartResultBridge(serverType: serverType, success: true, port: port))
}

struct ServerStartResultBridge: Sendable {
    let serverType: String
    let success: Bool
    let port: Int
}

/// Listen action
@_cdecl("aro_action_listen")
public func aro_action_listen(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let object = objectPtr else { return nil }

    let objectDesc = toObjectDescriptor(object)

    let listenType = objectDesc.base.lowercased()
    let target = objectDesc.specifiers.first ?? "*"

    ctxHandle.context.emit(CustomRuntimeEvent(
        type: "listen.started",
        data: "type=\(listenType),target=\(target)"
    ))

    return boxResult(ListenResultBridge(type: listenType, target: target))
}

struct ListenResultBridge: Sendable {
    let type: String
    let target: String
}

/// Route action
@_cdecl("aro_action_route")
public func aro_action_route(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr,
          let object = objectPtr else { return nil }

    let resultDesc = toResultDescriptor(result)
    let objectDesc = toObjectDescriptor(object)

    ctxHandle.context.emit(CustomRuntimeEvent(
        type: "route.requested",
        data: "router=\(objectDesc.base)"
    ))

    return boxResult(RouteResultBridge(router: objectDesc.base, success: true))
}

struct RouteResultBridge: Sendable {
    let router: String
    let success: Bool
}

#if !os(Windows)
/// Global storage for active file watchers
nonisolated(unsafe) private var activeWatchers: [UnsafeMutableRawPointer] = []
private let activeWatcherLock = NSLock()

/// Watch action - sets up FSEvents-based file monitoring
@_cdecl("aro_action_watch")
public func aro_action_watch(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr) else { return nil }

    // Get path from literal value first (from "with" clause), then fallback
    let path: String
    if let literalPath: String = ctxHandle.context.resolve("_literal_") {
        path = literalPath
    } else if let result = resultPtr {
        let resultDesc = toResultDescriptor(result)
        if let resolvedPath: String = ctxHandle.context.resolve(resultDesc.base) {
            path = resolvedPath
        } else {
            path = resultDesc.specifiers.first ?? "."
        }
    } else {
        path = "."
    }

    // Create and start file watcher using FSEvents
    guard let watcher = aro_file_watcher_create(path) else {
        print("[FileMonitor] Error: Failed to create watcher for path: \(path)")
        return boxResult(WatchResultBridge(path: path, success: false))
    }

    let startResult = aro_file_watcher_start(watcher)
    if startResult != 0 {
        aro_file_watcher_destroy(watcher)
        return boxResult(WatchResultBridge(path: path, success: false))
    }

    // Store watcher for cleanup
    activeWatcherLock.lock()
    activeWatchers.append(watcher)
    activeWatcherLock.unlock()

    ctxHandle.context.emit(CustomRuntimeEvent(
        type: "file.watch.started",
        data: "path=\(path)"
    ))

    return boxResult(WatchResultBridge(path: path, success: true))
}

/// Stop all active file watchers (called during shutdown)
public func stopAllFileWatchers() {
    activeWatcherLock.lock()
    let watchers = activeWatchers
    activeWatchers.removeAll()
    activeWatcherLock.unlock()

    for watcher in watchers {
        aro_file_watcher_stop(watcher)
        aro_file_watcher_destroy(watcher)
    }
}
#else
// Windows stub - file watching not supported
@_cdecl("aro_action_watch")
public func aro_action_watch(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    print("[FileMonitor] Warning: File watching is not supported on Windows")
    return boxResult(WatchResultBridge(path: ".", success: false))
}

public func stopAllFileWatchers() {
    // No-op on Windows
}
#endif

struct WatchResultBridge: Sendable {
    let path: String
    let success: Bool
}

/// Stop action
@_cdecl("aro_action_stop")
public func aro_action_stop(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr else { return nil }

    let resultDesc = toResultDescriptor(result)
    let serviceName = resultDesc.base

    ctxHandle.context.emit(CustomRuntimeEvent(
        type: "service.stop.requested",
        data: "service=\(serviceName)"
    ))

    return boxResult(true)
}

/// Keepalive action - blocks until SIGINT/SIGTERM
@_cdecl("aro_action_keepalive")
public func aro_action_keepalive(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr) else { return nil }

    // Set up signal handling
    KeepaliveSignalHandler.shared.setup()

    // Enter wait state
    ctxHandle.context.enterWaitState()

    // Emit event to signal we're waiting
    ctxHandle.context.emit(CustomRuntimeEvent(
        type: "wait.state.entered",
        data: ""
    ))

    // Block until shutdown is signaled (synchronously for native code)
    // Use a simple polling approach with sleep
    while !ShutdownCoordinator.shared.isShuttingDownNow {
        Thread.sleep(forTimeInterval: 0.1)
    }

    return boxResult(WaitResultBridge(completed: true, reason: "shutdown"))
}

struct WaitResultBridge: Sendable {
    let completed: Bool
    let reason: String
}
