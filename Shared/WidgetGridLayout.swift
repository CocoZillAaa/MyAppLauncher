import SwiftUI
import WidgetKit

/// Layout values shared by the desktop preview and the WidgetKit extension.
struct WidgetGridPlan {
    let columns: Int
    let rows: Int
    let visibleItemCount: Int

    static func resolve(
        family: WidgetFamily,
        itemCount: Int,
        labelsVisible: Bool,
        settings: WidgetGridSettings,
        availableSize: CGSize? = nil
    ) -> WidgetGridPlan {
        let metrics = WidgetGridMetrics(family: family)
        // Automatic layouts reserve more room per icon in crowded families.
        // Manual layouts keep the full WidgetKit grid capacity.
        let capacity = settings.mode == .automatic
            ? metrics.maximumAutomaticItems
            : metrics.maximumColumns * metrics.maximumRows
        let visibleCount = min(max(itemCount, 0), capacity)
        guard visibleCount > 0 else {
            return WidgetGridPlan(columns: 1, rows: 0, visibleItemCount: 0)
        }

        let columns: Int
        switch settings.mode {
        case .automatic:
            columns = balancedColumns(
                itemCount: visibleCount,
                familyMetrics: metrics,
                labelsVisible: labelsVisible,
                aspectRatio: availableSize.flatMap { $0.height > 0 ? Double($0.width / $0.height) : nil }
            )
        case .manual:
            columns = min(max(settings.manualColumnCount, 1), metrics.maximumColumns)
        }

        let displayedCount = min(visibleCount, columns * metrics.maximumRows)
        return WidgetGridPlan(
            columns: columns,
            rows: Int(ceil(Double(displayedCount) / Double(columns))),
            visibleItemCount: displayedCount
        )
    }

    private static func balancedColumns(
        itemCount: Int,
        familyMetrics: WidgetGridMetrics,
        labelsVisible: Bool,
        aspectRatio measuredAspectRatio: Double?
    ) -> Int {
        let widgetAspect = measuredAspectRatio ?? familyMetrics.aspectRatio
        // Icons read best when each grid cell is close to square. Labels make a
        // slightly wider cell useful, so the target shifts a little by setting.
        let targetCellAspect = labelsVisible ? 1.12 : 1.0
        var bestColumns = 1
        var bestScore = Double.infinity

        for columns in 1...familyMetrics.maximumColumns {
            let rows = Int(ceil(Double(itemCount) / Double(columns)))
            guard rows > 0, rows <= familyMetrics.maximumRows else { continue }

            let cellAspect = widgetAspect * Double(rows) / Double(columns)
            let aspectCost = abs(log(max(cellAspect, 0.01) / targetCellAspect))
            let emptyFraction = Double(columns * rows - itemCount) / Double(columns * rows)
            let shortLastRow = itemCount % columns == 0 ? 0.0 : Double(columns - itemCount % columns) / Double(columns)

            // Empty cells and a short final row matter more than a small
            // difference in cell proportions. This picks 4×2 for eight items
            // in Medium while retaining dense, balanced layouts elsewhere.
            let score = aspectCost * 0.42 + emptyFraction * 0.72 + shortLastRow * 0.12
            if score < bestScore - 0.0001 || (abs(score - bestScore) <= 0.0001 && columns > bestColumns) {
                bestScore = score
                bestColumns = columns
            }
        }
        return bestColumns
    }
}

struct WidgetGridMetrics {
    let maximumColumns: Int
    let maximumRows: Int
    let maximumAutomaticItems: Int
    let aspectRatio: Double

    init(family: WidgetFamily) {
        switch family {
        case .systemSmall:
            maximumColumns = 3
            maximumRows = 2
            maximumAutomaticItems = 4
            aspectRatio = 1.0
        case .systemMedium:
            maximumColumns = 5
            maximumRows = 2
            maximumAutomaticItems = 10
            aspectRatio = 2.4
        case .systemLarge:
            maximumColumns = 6
            maximumRows = 4
            maximumAutomaticItems = 16
            aspectRatio = 1.0
        case .systemExtraLarge:
            maximumColumns = 8
            maximumRows = 4
            maximumAutomaticItems = 18
            aspectRatio = 1.6
        case .systemExtraLargePortrait:
            maximumColumns = 4
            maximumRows = 8
            maximumAutomaticItems = 18
            aspectRatio = 225.0 / 460.0
        default:
            maximumColumns = 4
            maximumRows = 4
            maximumAutomaticItems = 16
            aspectRatio = 1.0
        }
    }
}

struct WidgetDisplayMetrics {
    let iconSize: CGFloat
    let itemSpacing: CGFloat
    let rowSpacing: CGFloat
    let columnSpacing: CGFloat
    let padding: CGFloat
    let labelFontSize: CGFloat

    init(
        family: WidgetFamily,
        density: WidgetDisplaySettings.Density,
        columns: Int,
        rows: Int,
        itemCount: Int,
        labelsVisible: Bool,
        availableSize: CGSize
    ) {
        let densityValues: (fill: CGFloat, item: CGFloat, row: CGFloat, column: CGFloat, padding: CGFloat, label: CGFloat)
        switch density {
        case .compact:
            densityValues = (0.82, 2, 3, 3, 3, 8)
        case .balanced:
            densityValues = (0.88, 3, 5, 5, 4, 9)
        case .spacious:
            densityValues = (0.96, 4, 7, 7, 5, 10)
        }

        itemSpacing = densityValues.item
        rowSpacing = densityValues.row
        columnSpacing = densityValues.column
        padding = densityValues.padding
        labelFontSize = densityValues.label

        let familyMaximum: CGFloat
        switch family {
        case .systemSmall:
            familyMaximum = 102
        case .systemMedium:
            familyMaximum = 80
        case .systemLarge:
            familyMaximum = 88
        case .systemExtraLarge:
            familyMaximum = 96
        case .systemExtraLargePortrait:
            familyMaximum = 96
        default:
            familyMaximum = 80
        }

        let safeColumns = max(columns, 1)
        let safeRows = max(rows, 1)
        let innerWidth = max(0, availableSize.width - padding * 2)
        let innerHeight = max(0, availableSize.height - padding * 2)
        let cellWidth = max(0, (innerWidth - CGFloat(safeColumns - 1) * columnSpacing) / CGFloat(safeColumns))
        let cellHeight = max(0, (innerHeight - CGFloat(safeRows - 1) * rowSpacing) / CGFloat(safeRows))
        let labelHeight = labelsVisible ? labelFontSize + itemSpacing + 3 : 0
        let iconRoom = max(0, min(cellWidth, cellHeight - labelHeight))

        let occupiedCells = max(1, safeColumns * safeRows)
        let sparseScale = min(1.04, max(1.0, sqrt(CGFloat(occupiedCells) / CGFloat(max(itemCount, 1)))))
        let fill = min(0.96, densityValues.fill * sparseScale)
        // Fill the usable cell area while leaving a small visual gap around
        // each icon; the per-family ceiling keeps sparse grids in proportion.
        let requestedSize = min(iconRoom * fill, familyMaximum)
        let lowerBound = min(28, iconRoom)
        iconSize = min(iconRoom, max(lowerBound, requestedSize))
    }
}
