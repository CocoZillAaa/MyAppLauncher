import AppIntents
import CryptoKit
import Foundation
import SwiftUI
import WidgetKit

/// Pagination wraps the validated grid; it does not change its capacities or scoring.
struct WidgetPaginationPlan {
    let grid: WidgetGridPlan
    let pageCount: Int
    let pageIndex: Int
    let itemRange: Range<Int>

    init(family: WidgetFamily, itemCount: Int, labelsVisible: Bool,
         settings: WidgetGridSettings, availableSize: CGSize, requestedPage: Int) {
        grid = WidgetGridPlan.resolve(family: family, itemCount: itemCount,
                                     labelsVisible: labelsVisible, settings: settings,
                                     availableSize: availableSize)
        let count = max(0, itemCount)
        let capacity = max(1, grid.visibleItemCount)
        pageCount = max(1, count / capacity + (count % capacity == 0 ? 0 : 1))
        pageIndex = min(max(0, requestedPage), pageCount - 1)
        let start = pageIndex * capacity
        itemRange = start..<min(start + capacity, count)
    }

    func dotIndices(for width: CGFloat) -> Range<Int> {
        // Two 22-point arrow controls and two 4-point gaps share the footer.
        let limit = max(1, Int(max(0, width - 52) / 18))
        let count = min(pageCount, limit)
        let start = min(max(0, pageIndex - count / 2), pageCount - count)
        return start..<(start + count)
    }

    func navigationHeight(for width: CGFloat) -> CGFloat {
        guard pageCount > 1 else { return 0 }
        return dotIndices(for: width).count < pageCount ? 34 : 22
    }
}

enum WidgetPageDirection {
    case previous, next

    var symbol: String { self == .previous ? "chevron.left" : "chevron.right" }
    var label: String { self == .previous ? "Page précédente" : "Page suivante" }
}

struct WidgetPageDots<Control: View, ArrowControl: View>: View {
    let plan: WidgetPaginationPlan
    let width: CGFloat
    @ViewBuilder var control: (Int) -> Control
    @ViewBuilder var arrowControl: (Int, WidgetPageDirection, Bool) -> ArrowControl

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                arrowControl(max(0, plan.pageIndex - 1), .previous, plan.pageIndex > 0)
                HStack(spacing: 0) {
                    ForEach(plan.dotIndices(for: width), id: \.self) { index in
                        control(index)
                    }
                }
                arrowControl(min(plan.pageCount - 1, plan.pageIndex + 1), .next,
                             plan.pageIndex < plan.pageCount - 1)
            }
            if plan.dotIndices(for: width).count < plan.pageCount {
                Text("\(plan.pageIndex + 1)/\(plan.pageCount)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: plan.navigationHeight(for: width))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pages du widget")
    }
}

struct WidgetPageArrow: View {
    let direction: WidgetPageDirection
    let isEnabled: Bool

    var body: some View {
        Image(systemName: direction.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary.opacity(isEnabled ? 0.85 : 0.25))
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
    }
}

struct WidgetPageDot: View {
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(.primary.opacity(isSelected ? 0.95 : 0.35))
            .frame(width: isSelected ? 7 : 5, height: isSelected ? 7 : 5)
            .frame(width: 18, height: 22)
            .contentShape(Rectangle())
    }
}

enum WidgetPageStateStore {
    private struct State: Codable {
        let pageIndex: Int
        let revision: String
    }

    private struct Revision: Encodable {
        let itemIDs: [String]
        let grid: WidgetGridSettings
        let display: WidgetDisplaySettings
    }

    static let families: [WidgetFamily] = [
        .systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .systemExtraLargePortrait
    ]

    static func revision(itemIDs: [String], grid: WidgetGridSettings,
                         display: WidgetDisplaySettings) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(Revision(itemIDs: itemIDs, grid: grid, display: display))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func pages(revision: String) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for family in families {
            guard let url = fileURL(familyRawValue: family.rawValue),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let state = try JSONDecoder().decode(State.self, from: BoundedLocalFile.read(url, maximumBytes: 4096))
                if state.revision == revision { result[family.rawValue] = max(0, state.pageIndex) }
            } catch {
                SharedConfiguration.logger.error("Widget page state unreadable; using first page: \(String(reflecting: error), privacy: .private)")
            }
        }
        return result
    }

    static func save(pageIndex: Int, familyRawValue: Int, revision: String) throws {
        guard (0...100_000).contains(pageIndex), revision.count == 64,
              let url = fileURL(familyRawValue: familyRawValue) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let data = try JSONEncoder().encode(State(pageIndex: pageIndex, revision: revision))
        try data.write(to: url, options: .atomic)
        SharedConfiguration.logger.notice("Widget page selected: family=\(familyRawValue), page=\(pageIndex + 1)")
    }

    private static func fileURL(familyRawValue: Int) -> URL? {
        guard families.contains(where: { $0.rawValue == familyRawValue }) else { return nil }
        return SharedConfiguration.containerURL?.appendingPathComponent("WidgetPagination-\(familyRawValue).json")
    }
}

struct ChangeWidgetPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Afficher une page du widget"
    static let openAppWhenRun = false

    @Parameter(title: "Format") var familyRawValue: Int
    @Parameter(title: "Page") var pageIndex: Int
    @Parameter(title: "Contenu") var revision: String

    init() {}

    init(familyRawValue: Int, pageIndex: Int, revision: String) {
        self.familyRawValue = familyRawValue
        self.pageIndex = pageIndex
        self.revision = revision
    }

    func perform() async throws -> some IntentResult {
        try WidgetPageStateStore.save(pageIndex: pageIndex, familyRawValue: familyRawValue, revision: revision)
        WidgetCenter.shared.reloadTimelines(ofKind: "MyAppLauncherWidget")
        return .result()
    }
}
