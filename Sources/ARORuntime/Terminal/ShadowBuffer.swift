//
//  ShadowBuffer.swift
//  ARORuntime
//
//  Terminal UI double buffering with dirty region tracking
//  Part of ARO-0053: Terminal Shadow Buffer Optimization
//

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Shadow buffer for optimized terminal rendering
/// Maintains current and previous screen state to minimize terminal I/O
/// NOTE: Not Sendable - must only be used within TerminalService actor's isolation
public final class ShadowBuffer {
    // MARK: - Properties

    /// Current screen buffer
    private var buffer: [[ScreenCell]]

    /// Previous screen buffer (for diffing)
    private var previousBuffer: [[ScreenCell]]

    /// Regions that need rendering
    private var dirtyRegions: Set<DirtyRegion>

    /// Terminal dimensions
    private let rows: Int
    private let cols: Int

    /// Terminal state tracking (avoids redundant ANSI codes)
    private var terminalState: TerminalState

    /// Batch rendering settings
    private let maxBatchSize = 64
    private var pendingUpdates: [(row: Int, col: Int, cell: ScreenCell)]

    // MARK: - Initialization

    /// Creates a shadow buffer with specified dimensions
    public init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols

        // Initialize buffers with empty cells
        let emptyCell = ScreenCell()
        self.buffer = Array(
            repeating: Array(repeating: emptyCell, count: cols),
            count: rows
        )
        self.previousBuffer = self.buffer

        self.dirtyRegions = []
        self.terminalState = TerminalState()
        self.pendingUpdates = []

        // Pre-allocate capacity for common batch sizes
        pendingUpdates.reserveCapacity(maxBatchSize)
    }

    /// Convenience initializer with current terminal size
    public convenience init() {
        let size = CapabilityDetector.detect()
        self.init(rows: size.rows, cols: size.columns)
    }

    // MARK: - Cell Manipulation

    /// Sets a single cell with styling
    public func setCell(
        row: Int, col: Int,
        char: Character,
        fgColor: TerminalColor? = nil,
        bgColor: TerminalColor? = nil,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strikethrough: Bool = false
    ) {
        guard isValid(row: row, col: col) else { return }

        let newCell = ScreenCell(
            char: char,
            fgColor: fgColor,
            bgColor: bgColor,
            bold: bold,
            italic: italic,
            underline: underline,
            strikethrough: strikethrough
        )

        // Only update if changed (key optimization)
        if buffer[row][col] != newCell {
            buffer[row][col] = newCell
            addDirtyRegion(row: row, col: col)
        }
    }

    /// Sets text across multiple cells
    public func setText(
        row: Int, col: Int,
        text: String,
        fgColor: TerminalColor? = nil,
        bgColor: TerminalColor? = nil,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strikethrough: Bool = false
    ) {
        guard row >= 0 && row < rows else { return }

        var currentCol = col
        var hasChanges = false
        let startCol = max(0, col)

        for char in text {
            guard currentCol < cols else { break }
            if currentCol >= 0 {
                let newCell = ScreenCell(
                    char: char,
                    fgColor: fgColor,
                    bgColor: bgColor,
                    bold: bold,
                    italic: italic,
                    underline: underline,
                    strikethrough: strikethrough
                )

                if buffer[row][currentCol] != newCell {
                    buffer[row][currentCol] = newCell
                    hasChanges = true
                }
            }
            currentCol += 1
        }

        if hasChanges {
            let endCol = min(cols - 1, col + text.count - 1)
            dirtyRegions.insert(DirtyRegion(
                startRow: row, endRow: row,
                startCol: startCol, endCol: max(startCol, endCol)
            ))
        }
    }

    /// Fills a rectangular region
    public func fillRect(
        startRow: Int, startCol: Int,
        endRow: Int, endCol: Int,
        char: Character = " ",
        fgColor: TerminalColor? = nil,
        bgColor: TerminalColor? = nil,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strikethrough: Bool = false
    ) {
        let sRow = max(0, min(startRow, endRow))
        let eRow = min(rows - 1, max(startRow, endRow))
        let sCol = max(0, min(startCol, endCol))
        let eCol = min(cols - 1, max(startCol, endCol))

        guard sRow <= eRow && sCol <= eCol else { return }

        let fillCell = ScreenCell(
            char: char,
            fgColor: fgColor,
            bgColor: bgColor,
            bold: bold,
            italic: italic,
            underline: underline,
            strikethrough: strikethrough
        )

        for row in sRow...eRow {
            for col in sCol...eCol {
                buffer[row][col] = fillCell
            }
        }

        dirtyRegions.insert(DirtyRegion(
            startRow: sRow, endRow: eRow,
            startCol: sCol, endCol: eCol
        ))
    }

    /// Draws a horizontal line
    public func drawHorizontalLine(
        row: Int, startCol: Int, endCol: Int,
        char: Character,
        fgColor: TerminalColor? = nil,
        bgColor: TerminalColor? = nil,
        bold: Bool = false
    ) {
        guard row >= 0 && row < rows else { return }

        let sCol = max(0, min(startCol, endCol))
        let eCol = min(cols - 1, max(startCol, endCol))

        guard sCol <= eCol else { return }

        let lineCell = ScreenCell(char: char, fgColor: fgColor, bgColor: bgColor, bold: bold)

        for col in sCol...eCol {
            buffer[row][col] = lineCell
        }

        dirtyRegions.insert(DirtyRegion(
            startRow: row, endRow: row,
            startCol: sCol, endCol: eCol
        ))
    }

    /// Draws a vertical line
    public func drawVerticalLine(
        col: Int, startRow: Int, endRow: Int,
        char: Character,
        fgColor: TerminalColor? = nil,
        bgColor: TerminalColor? = nil,
        bold: Bool = false
    ) {
        guard col >= 0 && col < cols else { return }

        let sRow = max(0, min(startRow, endRow))
        let eRow = min(rows - 1, max(startRow, endRow))

        guard sRow <= eRow else { return }

        let lineCell = ScreenCell(char: char, fgColor: fgColor, bgColor: bgColor, bold: bold)

        for row in sRow...eRow {
            buffer[row][col] = lineCell
        }

        dirtyRegions.insert(DirtyRegion(
            startRow: sRow, endRow: eRow,
            startCol: col, endCol: col
        ))
    }

    // MARK: - Rendering

    /// Renders only dirty regions to the terminal (key optimization)
    public func render() {
        guard !dirtyRegions.isEmpty else { return }

        pendingUpdates.removeAll(keepingCapacity: true)

        // Collect all changed cells in dirty regions
        for region in dirtyRegions {
            for row in region.startRow...region.endRow {
                for col in region.startCol...region.endCol {
                    guard isValid(row: row, col: col) else { continue }

                    let currentCell = buffer[row][col]
                    let previousCell = previousBuffer[row][col]

                    // Only render if cell actually changed
                    if currentCell != previousCell {
                        pendingUpdates.append((row: row, col: col, cell: currentCell))

                        // Batch rendering when we have enough updates
                        if pendingUpdates.count >= maxBatchSize {
                            flushPendingUpdates()
                        }
                    }
                }
            }
        }

        // Flush remaining updates
        if !pendingUpdates.isEmpty {
            flushPendingUpdates()
        }

        // Copy dirty regions to previous buffer
        for region in dirtyRegions {
            for row in region.startRow...region.endRow {
                for col in region.startCol...region.endCol {
                    guard isValid(row: row, col: col) else { continue }
                    previousBuffer[row][col] = buffer[row][col]
                }
            }
        }

        // Clear dirty regions
        dirtyRegions.removeAll()

        // Reset terminal state and flush output
        ANSIRenderer.resetStyles()
        terminalState.reset()
        flushOutput()
    }

    /// Flushes pending updates with optimized cursor movement
    private func flushPendingUpdates() {
        // Sort by row, then column for sequential cursor movement (major optimization)
        pendingUpdates.sort { first, second in
            if first.row != second.row {
                return first.row < second.row
            }
            return first.col < second.col
        }

        var lastRow = -1
        var lastCol = -1

        for update in pendingUpdates {
            // Skip cursor movement for sequential writes (major optimization)
            if update.row != lastRow || update.col != lastCol + 1 {
                print(ANSIRenderer.moveCursor(row: update.row + 1, column: update.col + 1), terminator: "")
            }

            // Only emit ANSI codes if state changed (major optimization)
            terminalState.updateIfNeeded(
                fgColor: update.cell.fgColor,
                bgColor: update.cell.bgColor,
                bold: update.cell.bold,
                italic: update.cell.italic,
                underline: update.cell.underline,
                strikethrough: update.cell.strikethrough
            )

            print(update.cell.char, terminator: "")

            lastRow = update.row
            lastCol = update.col
        }

        pendingUpdates.removeAll(keepingCapacity: true)
    }

    // MARK: - Screen Management

    /// Clears the entire buffer
    public func clear() {
        let emptyCell = ScreenCell()
        for row in 0..<rows {
            for col in 0..<cols {
                buffer[row][col] = emptyCell
            }
        }
        dirtyRegions.removeAll()
        dirtyRegions.insert(DirtyRegion(
            startRow: 0, endRow: rows - 1,
            startCol: 0, endCol: cols - 1
        ))
    }

    /// Forces a full screen refresh (invalidates entire previous buffer)
    public func forceRefresh() {
        dirtyRegions.removeAll()
        dirtyRegions.insert(DirtyRegion(
            startRow: 0, endRow: rows - 1,
            startCol: 0, endCol: cols - 1
        ))

        // Clear previous buffer to force all cells to redraw
        let nullCell = ScreenCell(char: "\0")
        for row in 0..<rows {
            for col in 0..<cols {
                previousBuffer[row][col] = nullCell
            }
        }

        render()
    }

    // MARK: - Terminal Resize

    /// Checks if terminal size has changed
    public func hasTerminalSizeChanged() -> Bool {
        let currentSize = CapabilityDetector.detect()
        return currentSize.rows != self.rows || currentSize.columns != self.cols
    }

    /// Creates a new buffer with updated terminal size, preserving content
    public func resizedBuffer() -> ShadowBuffer {
        let newSize = CapabilityDetector.detect()
        return resizedBuffer(rows: newSize.rows, cols: newSize.columns)
    }

    /// Creates a new buffer with specified size, preserving content
    public func resizedBuffer(rows newRows: Int, cols newCols: Int) -> ShadowBuffer {
        let newBuffer = ShadowBuffer(rows: newRows, cols: newCols)

        // Copy existing content to new buffer (preserving what fits)
        let copyRows = min(self.rows, newRows)
        let copyCols = min(self.cols, newCols)

        for row in 0..<copyRows {
            for col in 0..<copyCols {
                let cell = self.buffer[row][col]
                if cell.char != " " || cell.fgColor != nil || cell.bgColor != nil || cell.bold {
                    newBuffer.setCell(
                        row: row, col: col,
                        char: cell.char,
                        fgColor: cell.fgColor,
                        bgColor: cell.bgColor,
                        bold: cell.bold,
                        italic: cell.italic,
                        underline: cell.underline,
                        strikethrough: cell.strikethrough
                    )
                }
            }
        }

        return newBuffer
    }

    // MARK: - Utilities

    /// Gets terminal dimensions
    public func getDimensions() -> (rows: Int, cols: Int) {
        return (rows: rows, cols: cols)
    }

    /// Validates row/col coordinates
    @inline(__always)
    private func isValid(row: Int, col: Int) -> Bool {
        return row >= 0 && row < rows && col >= 0 && col < cols
    }

    /// Adds a dirty region (single cell)
    private func addDirtyRegion(row: Int, col: Int) {
        dirtyRegions.insert(DirtyRegion(row: row, col: col))
    }

    /// Flushes output to terminal
    /// Note: stdout is a C global that's thread-safe, but Swift 6 requires explicit marking
    private func flushOutput() {
        #if canImport(Darwin)
        nonisolated(unsafe) let stdoutPtr = Darwin.stdout
        Darwin.fflush(stdoutPtr)
        #elseif canImport(Glibc)
        nonisolated(unsafe) let stdoutPtr = Glibc.stdout
        Glibc.fflush(stdoutPtr)
        #endif
    }
}
