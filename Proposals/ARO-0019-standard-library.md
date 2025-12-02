# ARO-0019: Standard Library

* Proposal: ARO-0019
* Author: ARO Language Team
* Status: **Draft**
* Requires: ARO-0001, ARO-0006

## Abstract

This proposal defines the ARO Standard Library, providing common types, functions, and utilities available in all ARO programs.

## Motivation

A standard library provides:

1. **Consistency**: Common patterns across projects
2. **Productivity**: Ready-to-use utilities
3. **Quality**: Well-tested implementations
4. **Portability**: Works across platforms

---

### 1. Core Types

#### 1.1 Primitive Types

```
// Numeric
type Int;          // 64-bit signed integer
type Int8;         // 8-bit signed
type Int16;        // 16-bit signed
type Int32;        // 32-bit signed
type Int64;        // 64-bit signed
type UInt;         // 64-bit unsigned
type Float;        // 64-bit floating point
type Float32;      // 32-bit floating point
type Decimal;      // Arbitrary precision decimal

// Text
type String;       // UTF-8 string
type Character;    // Single Unicode scalar

// Boolean
type Bool;         // true or false

// Special
type Void;         // No value
type Never;        // Never returns
type Any;          // Any type (escape hatch)
```

#### 1.2 Optional Type

```
type Optional<T> {
    case some(value: T);
    case none;
    
    func map<U>(transform: (T) -> U) -> Optional<U>;
    func flatMap<U>(transform: (T) -> Optional<U>) -> Optional<U>;
    func filter(predicate: (T) -> Bool) -> Optional<T>;
    func getOrElse(default: T) -> T;
    func getOrThrow(error: Error) -> T;
    
    property isSome: Bool;
    property isNone: Bool;
}

// Syntax sugar
type T? = Optional<T>;
```

#### 1.3 Result Type

```
type Result<T, E: Error> {
    case success(value: T);
    case failure(error: E);
    
    func map<U>(transform: (T) -> U) -> Result<U, E>;
    func mapError<F: Error>(transform: (E) -> F) -> Result<T, F>;
    func flatMap<U>(transform: (T) -> Result<U, E>) -> Result<U, E>;
    func getOrThrow() -> T;
    func getOrElse(default: T) -> T;
    
    property isSuccess: Bool;
    property isFailure: Bool;
}
```

---

### 2. Collections

#### 2.1 List

```
type List<T> {
    // Creation
    static func empty() -> List<T>;
    static func of(items: T...) -> List<T>;
    static func repeat(item: T, count: Int) -> List<T>;
    
    // Access
    func get(index: Int) -> T?;
    subscript(index: Int) -> T;
    property first: T?;
    property last: T?;
    property count: Int;
    property isEmpty: Bool;
    
    // Modification (returns new list)
    func append(item: T) -> List<T>;
    func prepend(item: T) -> List<T>;
    func insert(item: T, at: Int) -> List<T>;
    func remove(at: Int) -> List<T>;
    func update(at: Int, with: T) -> List<T>;
    func concat(other: List<T>) -> List<T>;
    
    // Transformation
    func map<U>(transform: (T) -> U) -> List<U>;
    func flatMap<U>(transform: (T) -> List<U>) -> List<U>;
    func filter(predicate: (T) -> Bool) -> List<T>;
    func reduce<U>(initial: U, combine: (U, T) -> U) -> U;
    func sorted(by: (T, T) -> Bool) -> List<T>;
    func reversed() -> List<T>;
    func distinct() -> List<T>;
    
    // Search
    func find(predicate: (T) -> Bool) -> T?;
    func findIndex(predicate: (T) -> Bool) -> Int?;
    func contains(predicate: (T) -> Bool) -> Bool;
    func all(predicate: (T) -> Bool) -> Bool;
    func any(predicate: (T) -> Bool) -> Bool;
    func none(predicate: (T) -> Bool) -> Bool;
    
    // Slicing
    func take(count: Int) -> List<T>;
    func drop(count: Int) -> List<T>;
    func slice(from: Int, to: Int) -> List<T>;
    func takeWhile(predicate: (T) -> Bool) -> List<T>;
    func dropWhile(predicate: (T) -> Bool) -> List<T>;
    
    // Grouping
    func grouped(by: Int) -> List<List<T>>;
    func partition(predicate: (T) -> Bool) -> (List<T>, List<T>);
    func groupBy<K>(keySelector: (T) -> K) -> Map<K, List<T>>;
    
    // Aggregation
    func sum() -> T where T: Numeric;
    func average() -> Float where T: Numeric;
    func min() -> T? where T: Comparable;
    func max() -> T? where T: Comparable;
    
    // Joining
    func joined(separator: String) -> String where T == String;
    func zip<U>(with: List<U>) -> List<(T, U)>;
}
```

#### 2.2 Set

```
type Set<T: Hashable> {
    static func empty() -> Set<T>;
    static func of(items: T...) -> Set<T>;
    
    func contains(item: T) -> Bool;
    func insert(item: T) -> Set<T>;
    func remove(item: T) -> Set<T>;
    
    func union(other: Set<T>) -> Set<T>;
    func intersection(other: Set<T>) -> Set<T>;
    func difference(other: Set<T>) -> Set<T>;
    func symmetricDifference(other: Set<T>) -> Set<T>;
    
    func isSubset(of: Set<T>) -> Bool;
    func isSuperset(of: Set<T>) -> Bool;
    func isDisjoint(with: Set<T>) -> Bool;
    
    property count: Int;
    property isEmpty: Bool;
    func toList() -> List<T>;
}
```

#### 2.3 Map

```
type Map<K: Hashable, V> {
    static func empty() -> Map<K, V>;
    static func of(pairs: (K, V)...) -> Map<K, V>;
    
    func get(key: K) -> V?;
    subscript(key: K) -> V?;
    func contains(key: K) -> Bool;
    
    func set(key: K, value: V) -> Map<K, V>;
    func remove(key: K) -> Map<K, V>;
    func update(key: K, transform: (V?) -> V) -> Map<K, V>;
    
    func merge(other: Map<K, V>, resolve: (V, V) -> V) -> Map<K, V>;
    
    func mapValues<U>(transform: (V) -> U) -> Map<K, U>;
    func filter(predicate: (K, V) -> Bool) -> Map<K, V>;
    
    property keys: Set<K>;
    property values: List<V>;
    property entries: List<(K, V)>;
    property count: Int;
    property isEmpty: Bool;
}
```

---

### 3. String Operations

```
extend String {
    // Properties
    property length: Int;
    property isEmpty: Bool;
    property isBlank: Bool;
    
    // Access
    subscript(index: Int) -> Character;
    subscript(range: Range<Int>) -> String;
    
    // Case
    func toLowerCase() -> String;
    func toUpperCase() -> String;
    func capitalize() -> String;
    func titleCase() -> String;
    
    // Trimming
    func trim() -> String;
    func trimStart() -> String;
    func trimEnd() -> String;
    func trim(characters: String) -> String;
    
    // Search
    func contains(substring: String) -> Bool;
    func startsWith(prefix: String) -> Bool;
    func endsWith(suffix: String) -> Bool;
    func indexOf(substring: String) -> Int?;
    func lastIndexOf(substring: String) -> Int?;
    func matches(pattern: String) -> Bool;
    
    // Transformation
    func replace(old: String, with: String) -> String;
    func replaceAll(pattern: String, with: String) -> String;
    func split(separator: String) -> List<String>;
    func split(pattern: String, limit: Int?) -> List<String>;
    func join(parts: List<String>) -> String;
    
    // Padding
    func padStart(length: Int, with: Character) -> String;
    func padEnd(length: Int, with: Character) -> String;
    
    // Slicing
    func substring(from: Int, to: Int?) -> String;
    func take(count: Int) -> String;
    func drop(count: Int) -> String;
    
    // Conversion
    func toInt() -> Int?;
    func toFloat() -> Float?;
    func toData(encoding: Encoding) -> Data;
    
    // Formatting
    static func format(template: String, args: Any...) -> String;
}
```

---

### 4. Date and Time

```
type DateTime {
    // Construction
    static func now() -> DateTime;
    static func today() -> DateTime;
    static func parse(string: String, format: String?) -> DateTime?;
    static func fromTimestamp(seconds: Int) -> DateTime;
    static func of(year: Int, month: Int, day: Int, 
                   hour: Int, minute: Int, second: Int) -> DateTime;
    
    // Properties
    property year: Int;
    property month: Int;
    property day: Int;
    property hour: Int;
    property minute: Int;
    property second: Int;
    property millisecond: Int;
    property dayOfWeek: DayOfWeek;
    property dayOfYear: Int;
    property weekOfYear: Int;
    property timestamp: Int;
    
    // Arithmetic
    func plus(duration: Duration) -> DateTime;
    func minus(duration: Duration) -> DateTime;
    func minus(other: DateTime) -> Duration;
    
    // Comparison
    func isBefore(other: DateTime) -> Bool;
    func isAfter(other: DateTime) -> Bool;
    func isBetween(start: DateTime, end: DateTime) -> Bool;
    
    // Formatting
    func format(pattern: String) -> String;
    func toISO8601() -> String;
    
    // Manipulation
    func startOfDay() -> DateTime;
    func endOfDay() -> DateTime;
    func startOfWeek() -> DateTime;
    func startOfMonth() -> DateTime;
    func startOfYear() -> DateTime;
    
    func withYear(year: Int) -> DateTime;
    func withMonth(month: Int) -> DateTime;
    func withDay(day: Int) -> DateTime;
}

type Duration {
    static func milliseconds(n: Int) -> Duration;
    static func seconds(n: Int) -> Duration;
    static func minutes(n: Int) -> Duration;
    static func hours(n: Int) -> Duration;
    static func days(n: Int) -> Duration;
    static func weeks(n: Int) -> Duration;
    
    property totalMilliseconds: Int;
    property totalSeconds: Int;
    property totalMinutes: Int;
    property totalHours: Int;
    property totalDays: Int;
    
    func plus(other: Duration) -> Duration;
    func minus(other: Duration) -> Duration;
    func multiply(factor: Int) -> Duration;
}

// Extension syntax
extension Int {
    property milliseconds: Duration { Duration.milliseconds(self) }
    property seconds: Duration { Duration.seconds(self) }
    property minutes: Duration { Duration.minutes(self) }
    property hours: Duration { Duration.hours(self) }
    property days: Duration { Duration.days(self) }
}
```

---

### 5. Math Functions

```
module Math {
    // Constants
    const PI: Float = 3.14159265358979323846;
    const E: Float = 2.71828182845904523536;
    
    // Basic
    func abs<T: Numeric>(x: T) -> T;
    func min<T: Comparable>(a: T, b: T) -> T;
    func max<T: Comparable>(a: T, b: T) -> T;
    func clamp<T: Comparable>(value: T, min: T, max: T) -> T;
    
    // Rounding
    func floor(x: Float) -> Int;
    func ceil(x: Float) -> Int;
    func round(x: Float) -> Int;
    func truncate(x: Float) -> Int;
    
    // Powers and Roots
    func pow(base: Float, exponent: Float) -> Float;
    func sqrt(x: Float) -> Float;
    func cbrt(x: Float) -> Float;
    func exp(x: Float) -> Float;
    func log(x: Float) -> Float;
    func log10(x: Float) -> Float;
    func log2(x: Float) -> Float;
    
    // Trigonometry
    func sin(x: Float) -> Float;
    func cos(x: Float) -> Float;
    func tan(x: Float) -> Float;
    func asin(x: Float) -> Float;
    func acos(x: Float) -> Float;
    func atan(x: Float) -> Float;
    func atan2(y: Float, x: Float) -> Float;
    
    // Random
    func random() -> Float;  // 0.0 to 1.0
    func randomInt(min: Int, max: Int) -> Int;
    func randomElement<T>(from: List<T>) -> T?;
    func shuffle<T>(list: List<T>) -> List<T>;
}
```

---

### 6. JSON

```
module JSON {
    func parse(string: String) -> Result<Any, JSONError>;
    func stringify(value: Any, pretty: Bool) -> String;
    
    func encode<T: Encodable>(value: T) -> Result<String, JSONError>;
    func decode<T: Decodable>(string: String) -> Result<T, JSONError>;
}

protocol Encodable {
    func toJSON() -> Any;
}

protocol Decodable {
    static func fromJSON(json: Any) -> Result<Self, JSONError>;
}

protocol Codable: Encodable, Decodable {}
```

---

### 7. Regular Expressions

```
type Regex {
    static func compile(pattern: String, flags: RegexFlags?) -> Result<Regex, RegexError>;
    
    func test(input: String) -> Bool;
    func match(input: String) -> RegexMatch?;
    func matchAll(input: String) -> List<RegexMatch>;
    func replace(input: String, replacement: String) -> String;
    func replaceAll(input: String, replacement: String) -> String;
    func split(input: String) -> List<String>;
}

type RegexMatch {
    property fullMatch: String;
    property groups: List<String?>;
    property namedGroups: Map<String, String>;
    property index: Int;
}

type RegexFlags {
    static let caseInsensitive: RegexFlags;
    static let multiline: RegexFlags;
    static let dotMatchesNewlines: RegexFlags;
}
```

---

### 8. UUID and Identifiers

```
type UUID {
    static func random() -> UUID;
    static func parse(string: String) -> UUID?;
    static func nil() -> UUID;
    
    func toString() -> String;
    
    property version: Int;
    property variant: Int;
}

module Identifiers {
    func uuid() -> String;
    func nanoid(size: Int) -> String;
    func cuid() -> String;
    func ulid() -> String;
    func snowflake() -> String;
}
```

---

### 9. Crypto

```
module Crypto {
    // Hashing
    func md5(data: Data) -> String;
    func sha1(data: Data) -> String;
    func sha256(data: Data) -> String;
    func sha512(data: Data) -> String;
    
    // HMAC
    func hmacSHA256(data: Data, key: Data) -> Data;
    func hmacSHA512(data: Data, key: Data) -> Data;
    
    // Password hashing
    func bcrypt(password: String, rounds: Int) -> String;
    func bcryptVerify(password: String, hash: String) -> Bool;
    func argon2(password: String, salt: Data) -> String;
    
    // Encryption
    func encryptAES(data: Data, key: Data, iv: Data) -> Data;
    func decryptAES(data: Data, key: Data, iv: Data) -> Data;
    
    // Random
    func randomBytes(count: Int) -> Data;
    func randomHex(length: Int) -> String;
    func randomBase64(length: Int) -> String;
}
```

---

### 10. HTTP Client

```
module HTTP {
    func get(url: String, options: RequestOptions?) -> async Result<Response, HTTPError>;
    func post(url: String, body: Any?, options: RequestOptions?) -> async Result<Response, HTTPError>;
    func put(url: String, body: Any?, options: RequestOptions?) -> async Result<Response, HTTPError>;
    func patch(url: String, body: Any?, options: RequestOptions?) -> async Result<Response, HTTPError>;
    func delete(url: String, options: RequestOptions?) -> async Result<Response, HTTPError>;
    
    type RequestOptions {
        headers: Map<String, String>?;
        timeout: Duration?;
        followRedirects: Bool?;
        auth: Authentication?;
    }
    
    type Response {
        status: Int;
        headers: Map<String, String>;
        body: Data;
        
        func json<T: Decodable>() -> Result<T, JSONError>;
        func text() -> String;
    }
}
```

---

### 11. Logging

```
module Log {
    func trace(message: String, context: Map<String, Any>?);
    func debug(message: String, context: Map<String, Any>?);
    func info(message: String, context: Map<String, Any>?);
    func warn(message: String, context: Map<String, Any>?);
    func error(message: String, error: Error?, context: Map<String, Any>?);
    func fatal(message: String, error: Error?, context: Map<String, Any>?);
    
    func setLevel(level: LogLevel);
    func addHandler(handler: LogHandler);
}

enum LogLevel {
    trace, debug, info, warn, error, fatal
}

protocol LogHandler {
    func handle(entry: LogEntry);
}
```

---

### 12. Environment

```
module Env {
    func get(key: String) -> String?;
    func getOrDefault(key: String, default: String) -> String;
    func getOrThrow(key: String) -> String;
    func set(key: String, value: String);
    func all() -> Map<String, String>;
    
    property isDevelopment: Bool;
    property isProduction: Bool;
    property isTest: Bool;
}
```

---

### 13. Complete Module Summary

```
// Core types (always available)
Bool, Int, Float, String, List<T>, Set<T>, Map<K,V>, Optional<T>, Result<T,E>

// Modules (import to use)
import aro.math;        // Math functions
import aro.time;        // DateTime, Duration
import aro.json;        // JSON parsing
import aro.regex;       // Regular expressions
import aro.uuid;        // UUID generation
import aro.crypto;      // Cryptographic functions
import aro.http;        // HTTP client
import aro.log;         // Logging
import aro.env;         // Environment variables
import aro.io;          // File I/O
import aro.net;         // Networking
import aro.text;        // Text utilities
import aro.async;       // Async utilities
import aro.validation;  // Validation helpers
```

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification |
