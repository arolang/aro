# ARO-0055: Lexer Reserved Words Optimization

* Proposal: ARO-0055
* Author: ARO Language Team
* Status: **Implemented**
* Related Issues: GitLab #96

## Abstract

Optimize the Lexer's identifier scanning by merging keywords, articles, and prepositions into a single unified lookup table, reducing identifier tokenization from 2-3 hash lookups to a single lookup.

## Motivation

The current `scanIdentifierOrKeyword()` method performs sequential dictionary lookups:

```swift
// Current implementation (lines 582-600)
if let keyword = Self.keywords[lowerLexeme] {
    addToken(keyword, lexeme: lexeme, start: start)
    return
}

if let article = Article(rawValue: lowerLexeme) {
    addToken(.article(article), lexeme: lexeme, start: start)
    return
}

if let preposition = Preposition(rawValue: lowerLexeme) {
    addToken(.preposition(preposition), lexeme: lexeme, start: start)
    return
}

addToken(.identifier(lexeme), lexeme: lexeme, start: start)
```

**Performance Impact:**
- Keywords: 1 dictionary lookup
- Articles: 1 dictionary lookup + enum initialization
- Prepositions: 1 dictionary lookup + enum initialization
- Identifiers: Up to 3 failed lookups before classification

With ~40% of tokens being identifiers, this creates significant overhead.

## Proposed Solution

### Unified Reserved Word Enum

Create a single `ReservedWord` enum that encompasses all reserved words:

```swift
private enum ReservedWord {
    case keyword(TokenKind)
    case article(Article)
    case preposition(Preposition)
}

private static let reservedWords: [String: ReservedWord] = [
    // Keywords
    "publish": .keyword(.publish),
    "require": .keyword(.require),
    // ... all keywords

    // Articles
    "a": .article(.a),
    "an": .article(.an),
    "the": .article(.the),

    // Prepositions
    "from": .preposition(.from),
    "for": .preposition(.for),
    // ... all prepositions
]
```

### Optimized Lookup

```swift
if let reserved = Self.reservedWords[lowerLexeme] {
    switch reserved {
    case .keyword(let kind):
        addToken(kind, lexeme: lexeme, start: start)
    case .article(let article):
        addToken(.article(article), lexeme: lexeme, start: start)
    case .preposition(let preposition):
        addToken(.preposition(preposition), lexeme: lexeme, start: start)
    }
} else {
    addToken(.identifier(lexeme), lexeme: lexeme, start: start)
}
```

## Performance Analysis

| Token Type | Current | Optimized | Improvement |
|------------|---------|-----------|-------------|
| Keywords | 1 lookup | 1 lookup | Same |
| Articles | 2 lookups | 1 lookup | 2x faster |
| Prepositions | 3 lookups | 1 lookup | 3x faster |
| Identifiers | 3 failed lookups | 1 failed lookup | 3x faster |

**Expected Impact:**
For a typical ARO program with 40% identifiers, 10% prepositions, 5% articles, and 45% other tokens:
- **Overall lexer speedup**: ~15-25% faster

## Implementation Changes

### Files Modified
- `Sources/AROParser/Lexer.swift`:
  - Add `ReservedWord` enum
  - Replace `keywords` dict with `reservedWords` dict
  - Update `scanIdentifierOrKeyword()` method

### Backward Compatibility
- ✅ Zero impact on public API
- ✅ Token stream remains identical
- ✅ No changes to Token.swift enums

## Testing Strategy

1. **Correctness**: All existing tests must pass
2. **Performance**: Benchmark lexer on large files (10K+ lines)
3. **Coverage**: Ensure all reserved words are in the new dictionary

## Alternatives Considered

### 1. Perfect Hashing
Use a minimal perfect hash function for reserved words.

**Rejected**: Complexity not justified. Simple dictionary lookup is fast enough.

### 2. Trie Data Structure
Build a trie for all reserved words.

**Rejected**: Overkill for ~80 reserved words. Dictionary lookup is O(1) average case.

### 3. Keep Separate Lookups, Cache Results
Add LRU cache for identifier classifications.

**Rejected**: Cache management overhead likely negates benefits. Single lookup is simpler.

## Conclusion

Merging reserved words into a single lookup table provides measurable performance improvement with minimal code changes and zero behavioral impact. The optimization is straightforward, maintainable, and aligns with modern lexer design patterns.
