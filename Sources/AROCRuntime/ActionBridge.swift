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

    // Get source value - check _literal_ first (from "with" clause),
    // then expression, then fall back to object base variable
    let sourceData: any Sendable
    if let literal = ctxHandle.context.resolveAny("_literal_") {
        sourceData = literal
    } else if let expr = ctxHandle.context.resolveAny("_expression_") {
        sourceData = expr
    } else if let value = ctxHandle.context.resolveAny(objectDesc.base) {
        sourceData = value
    } else {
        sourceData = ""
    }

    // Bind the actual value directly to result variable
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

    var data: [String: AnySendable] = [:]

    // Check for expression from "with" clause (e.g., with { user: <user>, ... })
    if let expr = ctxHandle.context.resolveAny("_expression_") {
        if let dict = expr as? [String: any Sendable] {
            for (key, value) in dict {
                flattenValue(value, into: &data, prefix: key, context: ctxHandle.context)
            }
        }
    }

    // Check for object literal from "with" clause
    if let literal = ctxHandle.context.resolveAny("_literal_") {
        if let dict = literal as? [String: any Sendable] {
            for (key, value) in dict {
                flattenValue(value, into: &data, prefix: key, context: ctxHandle.context)
            }
        }
    }

    // Include object.base value if resolvable
    if let value = ctxHandle.context.resolveAny(objectDesc.base) {
        flattenValue(value, into: &data, prefix: objectDesc.base, context: ctxHandle.context)
    }

    // Include object specifiers as data references
    for specifier in objectDesc.specifiers {
        if let value = ctxHandle.context.resolveAny(specifier) {
            flattenValue(value, into: &data, prefix: specifier, context: ctxHandle.context)
        }
    }

    let response = Response(
        status: resultDesc.base,
        reason: objectDesc.base,
        data: data
    )

    ctxHandle.context.setResponse(response)

    // Format and print the response like the interpreter does
    print(response.toFormattedString())

    return boxResult(response)
}

/// Flatten a value into the data dictionary using dot notation for nested objects
private func flattenValue(
    _ value: any Sendable,
    into data: inout [String: AnySendable],
    prefix: String,
    context: RuntimeContext
) {
    switch value {
    case let str as String:
        // Check if it's a variable reference
        if let resolved = context.resolveAny(str) {
            flattenValue(resolved, into: &data, prefix: prefix, context: context)
        } else {
            data[prefix] = AnySendable(str)
        }
    case let int as Int:
        data[prefix] = AnySendable(int)
    case let double as Double:
        data[prefix] = AnySendable(double)
    case let bool as Bool:
        data[prefix] = AnySendable(bool)
    case let dict as [String: any Sendable]:
        // Recursively flatten nested dictionaries with dot notation
        for (key, nestedValue) in dict {
            let nestedPrefix = "\(prefix).\(key)"
            flattenValue(nestedValue, into: &data, prefix: nestedPrefix, context: context)
        }
    case let array as [any Sendable]:
        // Arrays become comma-separated values
        let items = array.map { formatArrayItem($0, context: context) }
        data[prefix] = AnySendable(items.joined(separator: ", "))
    default:
        data[prefix] = AnySendable(String(describing: value))
    }
}

/// Format an array item as a string
private func formatArrayItem(_ value: any Sendable, context: RuntimeContext) -> String {
    switch value {
    case let str as String:
        if let resolved = context.resolveAny(str) {
            return formatArrayItem(resolved, context: context)
        }
        return str
    case let int as Int:
        return String(int)
    case let double as Double:
        return String(double)
    case let bool as Bool:
        return bool ? "true" : "false"
    default:
        return String(describing: value)
    }
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

    // Get message to log
    // Priority: 1. with clause literal, 2. expression, 3. result variable, 4. result name
    let message: String
    if let literal = ctxHandle.context.resolveAny("_literal_") {
        // Message from "with" clause (string literal)
        message = String(describing: literal)
    } else if let expr = ctxHandle.context.resolveAny("_expression_") {
        // Message from "with" clause (expression)
        message = String(describing: expr)
    } else if let value: String = ctxHandle.context.resolve(resultDesc.base) {
        // Message from variable
        message = value
    } else if let value = ctxHandle.context.resolveAny(resultDesc.base) {
        // Message from any variable type
        message = String(describing: value)
    } else {
        // Fallback to result name
        message = resultDesc.fullName
    }

    print("[\(ctxHandle.context.featureSetName)] \(message)")
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
    let objectBase = objectDesc.base.lowercased()

    // If object is "contract", read port from OpenAPI spec (pass 0 to indicate this)
    let port: Int
    if objectBase == "contract" {
        port = 0  // Signal to read from OpenAPI spec
    } else {
        port = Int(objectDesc.specifiers.first ?? "9000") ?? 9000
    }

    var success = false

    switch serverType {
    case "socket-server", "socketserver":
        #if !os(Windows)
        // Actually start the native socket server
        let result = aro_native_socket_server_start(Int32(port))
        success = result == 0
        #endif

    case "http-server", "httpserver", "server":
        #if !os(Windows)
        // Start native HTTP server with OpenAPI routing
        let result = aro_native_http_server_start_with_openapi(Int32(port), contextPtr)
        success = result == 0
        #else
        ctxHandle.context.emit(CustomRuntimeEvent(
            type: "http.server.start.requested",
            data: "port=\(port)"
        ))
        success = true
        #endif

    default:
        ctxHandle.context.emit(CustomRuntimeEvent(
            type: "service.start.requested",
            data: "type=\(serverType),port=\(port)"
        ))
        success = true
    }

    return boxResult(ServerStartResultBridge(serverType: serverType, success: success, port: port))
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

// MARK: - External Service Action

/// Call action - invoke a method on an external service
@_cdecl("aro_action_call")
public func aro_action_call(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr,
          let object = objectPtr else { return nil }

    let resultDesc = toResultDescriptor(result)
    let objectDesc = toObjectDescriptor(object)

    // Parse service and method from object
    // Format: <service: method>
    let serviceName: String
    let methodName: String

    if !objectDesc.specifiers.isEmpty {
        serviceName = objectDesc.base
        methodName = objectDesc.specifiers[0]
    } else {
        // Try to split on hyphen
        let parts = objectDesc.base.split(separator: "-", maxSplits: 1)
        if parts.count == 2 {
            serviceName = String(parts[0])
            methodName = String(parts[1])
        } else {
            print("[ARO] Call error: Invalid service:method format")
            return boxResult(CallResultBridge(success: false, error: "Invalid format"))
        }
    }

    // Get arguments from literal or expression value
    // Object literals are bound as _expression_ (parsed by expression evaluator)
    var args: [String: any Sendable] = [:]
    if let exprArgs = ctxHandle.context.resolveAny("_expression_") as? [String: any Sendable] {
        args = exprArgs
    } else if let literalArgs = ctxHandle.context.resolveAny("_literal_") as? [String: any Sendable] {
        args = literalArgs
    }

    // Call the service synchronously using a semaphore
    // (Native code needs synchronous execution)
    let resultHolder = ServiceCallResultHolder()
    let semaphore = DispatchSemaphore(value: 0)

    // Copy values for Sendable closure
    let svcName = serviceName
    let mtdName = methodName
    let callArgs = args

    Task { @Sendable in
        do {
            let result = try await ExternalServiceRegistry.shared.call(svcName, method: mtdName, args: callArgs)
            resultHolder.setResult(result)
        } catch {
            resultHolder.setError(error)
        }
        semaphore.signal()
    }

    semaphore.wait()

    if let error = resultHolder.error {
        print("[ARO] Call error: \(error)")
        return boxResult(CallResultBridge(success: false, error: error.localizedDescription))
    }

    // Bind result
    if let callResult = resultHolder.result {
        ctxHandle.context.bind(resultDesc.base, value: callResult)
        return boxResult(callResult)
    }

    return boxResult(CallResultBridge(success: true, error: nil))
}

struct CallResultBridge: Sendable {
    let success: Bool
    let error: String?
}

/// Thread-safe holder for service call results
final class ServiceCallResultHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _result: (any Sendable)?
    private var _error: Error?

    var result: (any Sendable)? {
        lock.lock()
        defer { lock.unlock() }
        return _result
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return _error
    }

    func setResult(_ value: any Sendable) {
        lock.lock()
        defer { lock.unlock() }
        _result = value
    }

    func setError(_ err: Error) {
        lock.lock()
        defer { lock.unlock() }
        _error = err
    }
}

// MARK: - Data Pipeline Actions (ARO-0018)

/// Filter action - filters a collection using a where clause
@_cdecl("aro_action_filter")
public func aro_action_filter(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr,
          let object = objectPtr else { return nil }

    let resultDesc = toResultDescriptor(result)
    let objectDesc = toObjectDescriptor(object)

    // Get source collection
    guard let source = ctxHandle.context.resolveAny(objectDesc.base),
          let array = source as? [any Sendable] else {
        ctxHandle.context.bind(resultDesc.base, value: [] as [any Sendable])
        return boxResult([] as [any Sendable])
    }

    // Get where clause from context bindings
    guard let field = ctxHandle.context.resolveAny("_where_field_") as? String,
          let op = ctxHandle.context.resolveAny("_where_op_") as? String,
          let expectedValue = ctxHandle.context.resolveAny("_where_value_") else {
        // No filter - return all
        ctxHandle.context.bind(resultDesc.base, value: array)
        return boxResult(array)
    }

    let filtered = array.filter { item in
        guard let dict = item as? [String: any Sendable],
              let actualValue = dict[field] else {
            return false
        }
        return matchesPredicate(actual: actualValue, op: op, expected: expectedValue)
    }

    ctxHandle.context.bind(resultDesc.base, value: filtered)
    return boxResult(filtered)
}

/// Helper function for filter predicate matching
private func matchesPredicate(actual: Any, op: String, expected: any Sendable) -> Bool {
    let actualStr = String(describing: actual)
    let expectedStr = String(describing: expected)

    switch op.lowercased() {
    case "is", "==", "equals":
        return actualStr == expectedStr

    case "is not", "is-not", "!=", "not-equals":
        return actualStr != expectedStr

    case ">", "gt":
        if let actualNum = asDouble(actual), let expectedNum = asDouble(expected) {
            return actualNum > expectedNum
        }
        return actualStr > expectedStr

    case ">=", "gte":
        if let actualNum = asDouble(actual), let expectedNum = asDouble(expected) {
            return actualNum >= expectedNum
        }
        return actualStr >= expectedStr

    case "<", "lt":
        if let actualNum = asDouble(actual), let expectedNum = asDouble(expected) {
            return actualNum < expectedNum
        }
        return actualStr < expectedStr

    case "<=", "lte":
        if let actualNum = asDouble(actual), let expectedNum = asDouble(expected) {
            return actualNum <= expectedNum
        }
        return actualStr <= expectedStr

    case "contains":
        return actualStr.contains(expectedStr)

    default:
        return actualStr == expectedStr
    }
}

/// Reduce action - aggregates a collection with sum/count/avg/min/max
@_cdecl("aro_action_reduce")
public func aro_action_reduce(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr,
          let object = objectPtr else { return nil }

    let resultDesc = toResultDescriptor(result)
    let objectDesc = toObjectDescriptor(object)

    // Get source collection
    guard let source = ctxHandle.context.resolveAny(objectDesc.base) else {
        ctxHandle.context.bind(resultDesc.base, value: 0)
        return boxResult(0)
    }

    // Get aggregation function from context
    let aggregateFunc = (ctxHandle.context.resolveAny("_aggregation_type_") as? String)?.lowercased() ?? "count"
    let field = ctxHandle.context.resolveAny("_aggregation_field_") as? String

    // Handle array aggregation
    guard let array = source as? [any Sendable] else {
        let result: any Sendable = aggregateFunc == "count" ? 1 : source
        ctxHandle.context.bind(resultDesc.base, value: result)
        return boxResult(result)
    }

    // Extract numeric values from array
    let values: [Double] = array.compactMap { item -> Double? in
        if let field = field, let dict = item as? [String: any Sendable] {
            return asDouble(dict[field])
        }
        return asDouble(item)
    }

    // Apply aggregation function
    let aggregatedResult: any Sendable
    switch aggregateFunc {
    case "count":
        aggregatedResult = array.count

    case "sum":
        aggregatedResult = values.reduce(0, +)

    case "avg", "average":
        aggregatedResult = values.isEmpty ? 0.0 : values.reduce(0, +) / Double(values.count)

    case "min":
        aggregatedResult = values.min() ?? 0.0

    case "max":
        aggregatedResult = values.max() ?? 0.0

    case "first":
        aggregatedResult = array.first ?? ([] as [any Sendable])

    case "last":
        aggregatedResult = array.last ?? ([] as [any Sendable])

    default:
        aggregatedResult = array.count
    }

    ctxHandle.context.bind(resultDesc.base, value: aggregatedResult)
    return boxResult(aggregatedResult)
}

/// Map action - transforms a collection
@_cdecl("aro_action_map")
public func aro_action_map(
    _ contextPtr: UnsafeMutableRawPointer?,
    _ resultPtr: UnsafeRawPointer?,
    _ objectPtr: UnsafeRawPointer?
) -> UnsafeMutableRawPointer? {
    guard let ctxHandle = getContext(contextPtr),
          let result = resultPtr,
          let object = objectPtr else { return nil }

    let resultDesc = toResultDescriptor(result)
    let objectDesc = toObjectDescriptor(object)

    // Get source collection
    guard let source = ctxHandle.context.resolveAny(objectDesc.base) else {
        ctxHandle.context.bind(resultDesc.base, value: [] as [any Sendable])
        return boxResult([] as [any Sendable])
    }

    // Known type specifiers that should not be treated as field names
    let typeSpecifiers: Set<String> = [
        "List", "Array", "Set",
        "Integer", "Int", "Float", "Double", "Number",
        "String", "Boolean", "Bool",
        "Object", "Dictionary", "Map"
    ]

    // Find field specifier (skip known type specifiers)
    let fieldSpecifier = resultDesc.specifiers.first { !typeSpecifiers.contains($0) }

    // Handle array mapping
    if let array = source as? [any Sendable] {
        if let field = fieldSpecifier {
            // Extract specific field from each item
            let mapped = array.compactMap { item -> (any Sendable)? in
                if let dict = item as? [String: any Sendable] {
                    return dict[field]
                }
                return nil
            }
            ctxHandle.context.bind(resultDesc.base, value: mapped)
            return boxResult(mapped)
        }

        // Pass through the entire array
        ctxHandle.context.bind(resultDesc.base, value: array)
        return boxResult(array)
    }

    // Handle dictionary - extract field
    if let dict = source as? [String: any Sendable] {
        if let field = fieldSpecifier, let value = dict[field] {
            ctxHandle.context.bind(resultDesc.base, value: value)
            return boxResult(value)
        }
        ctxHandle.context.bind(resultDesc.base, value: dict)
        return boxResult(dict)
    }

    ctxHandle.context.bind(resultDesc.base, value: source)
    return boxResult(source)
}

/// Helper function for numeric conversion
private func asDouble(_ value: Any?) -> Double? {
    guard let value = value else { return nil }
    if let d = value as? Double { return d }
    if let i = value as? Int { return Double(i) }
    if let f = value as? Float { return Double(f) }
    if let s = value as? String { return Double(s) }
    return nil
}
