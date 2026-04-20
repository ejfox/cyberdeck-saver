import Foundation

/// Grid math for panel placement. Pure value type — easy to unit test later.
struct PanelLayout {
    let cols: Int
    let rows: Int
    let gridCols: Int
    let gridRows: Int

    /// Column/row width in grid cells, inset by 1 cell of gutter per side.
    func rect(forIndex i: Int) -> (origin: (col: Int, row: Int), size: (cols: Int, rows: Int)) {
        let cellCol = gridCols / cols
        let cellRow = gridRows / rows
        let c = i % cols
        let r = i / cols
        return (
            origin: (c * cellCol + 1, r * cellRow + 1),
            size:   (cellCol - 2, cellRow - 1)
        )
    }

    static func forPanelCount(_ count: Int, gridCols: Int, gridRows: Int) -> PanelLayout {
        // Widescreen-friendly: pick more columns for higher panel counts so
        // each panel stays readable (at least ~7 character rows tall).
        // 25 is the scrapbook-enabled default (5×5).
        let cols: Int
        switch count {
        case 0...4:   cols = 2
        case 5...9:   cols = 3
        case 10...16: cols = 4
        case 17...20: cols = 5
        case 21...25: cols = 5
        case 26...30: cols = 6
        default:      cols = 7
        }
        let rows = (count + cols - 1) / cols
        return PanelLayout(cols: cols, rows: rows, gridCols: gridCols, gridRows: gridRows)
    }
}
