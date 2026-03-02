//
//  DirtyRegion.swift
//  ARORuntime
//
//  Terminal UI dirty region tracking
//  Part of ARO-0053: Terminal Shadow Buffer Optimization
//

import Foundation

/// Represents a rectangular region of the terminal screen that needs to be redrawn
/// Used by ShadowBuffer to track which cells changed and need rendering
public struct DirtyRegion: Hashable, Sendable {
    /// Starting row (0-based, inclusive)
    public let startRow: Int

    /// Ending row (0-based, inclusive)
    public let endRow: Int

    /// Starting column (0-based, inclusive)
    public let startCol: Int

    /// Ending column (0-based, inclusive)
    public let endCol: Int

    /// Creates a dirty region covering the specified rectangle
    public init(startRow: Int, endRow: Int, startCol: Int, endCol: Int) {
        // Ensure start <= end for both dimensions
        self.startRow = min(startRow, endRow)
        self.endRow = max(startRow, endRow)
        self.startCol = min(startCol, endCol)
        self.endCol = max(startCol, endCol)
    }

    /// Creates a dirty region for a single cell
    public init(row: Int, col: Int) {
        self.startRow = row
        self.endRow = row
        self.startCol = col
        self.endCol = col
    }

    /// Number of rows in this region
    public var rowCount: Int {
        return endRow - startRow + 1
    }

    /// Number of columns in this region
    public var colCount: Int {
        return endCol - startCol + 1
    }

    /// Total number of cells in this region
    public var cellCount: Int {
        return rowCount * colCount
    }

    /// Checks if this region contains the specified cell
    public func contains(row: Int, col: Int) -> Bool {
        return row >= startRow && row <= endRow &&
               col >= startCol && col <= endCol
    }

    /// Checks if this region overlaps with another region
    public func overlaps(with other: DirtyRegion) -> Bool {
        return !(endRow < other.startRow ||
                 startRow > other.endRow ||
                 endCol < other.startCol ||
                 startCol > other.endCol)
    }

    /// Merges this region with another, returning the bounding rectangle
    public func merged(with other: DirtyRegion) -> DirtyRegion {
        return DirtyRegion(
            startRow: min(self.startRow, other.startRow),
            endRow: max(self.endRow, other.endRow),
            startCol: min(self.startCol, other.startCol),
            endCol: max(self.endCol, other.endCol)
        )
    }
}
