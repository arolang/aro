// ============================================================
// Exports.swift
// AROLSP - Public API Exports
// ============================================================

#if !os(Windows)
// Re-export key types for external use
@_exported import AROParser

// The main entry point for the LSP server
public typealias LanguageServer = AROLanguageServer
#endif
