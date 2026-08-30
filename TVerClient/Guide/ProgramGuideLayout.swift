import CoreGraphics
import Foundation

/// 番組表の1枠をどこにどれだけの大きさで置くか。
struct GuideSlotFrame: Equatable, Identifiable, Sendable {
    let program: TVerLiveProgram
    let y: CGFloat
    let height: CGFloat

    var id: String { program.id }
    var maxY: CGFloat { y + height }
}

/// 1チャンネル分の列。
struct GuideColumnLayout: Equatable, Identifiable, Sendable {
    let channel: TVerLiveChannel
    let frames: [GuideSlotFrame]

    var id: String { channel.id }
}

/// いま見えている範囲。スクロールのたびに全セルを作り直さないよう、
/// 粗い刻みに丸めてから渡す。
struct GuideVisibleWindow: Equatable, Sendable {
    let columns: Range<Int>
    let minY: CGFloat
    let maxY: CGFloat

    /// 全体を描く。プレビューや初回描画の保険。
    static let unbounded = GuideVisibleWindow(
        columns: 0 ..< Int.max,
        minY: -.greatestFiniteMagnitude,
        maxY: .greatestFiniteMagnitude
    )

    func contains(column: Int) -> Bool {
        columns.contains(column)
    }

    func intersects(y: CGFloat, maxY otherMaxY: CGFloat) -> Bool {
        otherMaxY >= minY && y <= maxY
    }
}

/// 番組表のレイアウト計算。
///
/// 以前は描画時に `max(最小高さ, 実時間)` でセルを伸ばすだけだったため、
/// 伸びた分が次の枠に重なり、後から描かれる次の枠がタップを全部吸っていた。
/// 既定倍率だと 23.6 分未満の番組（深夜のミニ番組やニュース）が事実上押せない。
///
/// ここでは先に列全体の位置を確定させ、重なりを残さない。短い枠は
/// ①番組間の隔間 ②隔隔で足りなければ隣の長い枠（44pt を割らない範囲）
/// の順に場所をもらって 44pt まで育てる。列全体を下に押し下げないので、
/// 時刻目盛りとのずれは短い枠の周りだけに留まる。
enum ProgramGuideLayout {
    /// 全チャンネル分の列を組み立てる。
    static func columns(
        for guide: [TVerGuideChannel],
        on selectedDate: Date,
        pointsPerMinute: CGFloat
    ) -> [GuideColumnLayout] {
        guide.map { item in
            GuideColumnLayout(
                channel: item.channel,
                frames: frames(
                    for: item.programs,
                    on: selectedDate,
                    pointsPerMinute: pointsPerMinute
                )
            )
        }
    }

    /// 1列分の枠。重なりなし、できる限り最小タップ領域以上。
    static func frames(
        for programs: [TVerLiveProgram],
        on selectedDate: Date,
        pointsPerMinute: CGFloat,
        minimumHeight: CGFloat? = nil
    ) -> [GuideSlotFrame] {
        let zoom = GuideZoom.clamp(pointsPerMinute)
        let slots = GuideBroadcastAxis.programs(programs, on: selectedDate)
        guard !slots.isEmpty else { return [] }

        let floorHeight = minimumHeight ?? ProgramGuideMetrics.minimumHeight(pointsPerMinute: zoom)
        let dayHeight = ProgramGuideMetrics.dayHeight(pointsPerMinute: zoom)
        let epsilon: CGFloat = 0.01

        var tops: [CGFloat] = []
        var bottoms: [CGFloat] = []
        tops.reserveCapacity(slots.count)
        bottoms.reserveCapacity(slots.count)

        // まずは実時間どおりに並べる。元データが重なっていたら後の枠を下にさげる。
        var lowerBound: CGFloat = 0
        for program in slots {
            let naturalTop = GuideBroadcastAxis.yPosition(
                for: program.startAt,
                on: selectedDate,
                pointsPerMinute: zoom
            )
            let naturalBottom = GuideBroadcastAxis.yPosition(
                for: program.endAt,
                on: selectedDate,
                pointsPerMinute: zoom
            )
            let top = min(max(naturalTop, lowerBound), dayHeight)
            let bottom = min(max(naturalBottom, top), dayHeight)
            tops.append(top)
            bottoms.append(bottom)
            lowerBound = bottom
        }

        for index in slots.indices {
            var deficit = floorHeight - (bottoms[index] - tops[index])
            guard deficit > epsilon else { continue }

            // ① 下の隔間を使う。
            let nextTop = index + 1 < slots.count ? tops[index + 1] : dayHeight
            let gapBelow = max(0, nextTop - bottoms[index])
            let fromGapBelow = min(deficit, gapBelow)
            bottoms[index] += fromGapBelow
            deficit -= fromGapBelow

            // ② 次の枠から借りる。次の枠も最小高さを割らない分だけ。
            if deficit > epsilon, index + 1 < slots.count {
                let room = max(0, (bottoms[index + 1] - tops[index + 1]) - floorHeight)
                let borrowed = min(deficit, room)
                bottoms[index] += borrowed
                tops[index + 1] = bottoms[index]
                deficit -= borrowed
            }

            // ③ 上の隔間を使う。
            if deficit > epsilon {
                let previousBottom = index > 0 ? bottoms[index - 1] : 0
                let gapAbove = max(0, tops[index] - previousBottom)
                let fromGapAbove = min(deficit, gapAbove)
                tops[index] -= fromGapAbove
                deficit -= fromGapAbove
            }

            // ④ 前の枠から借りる。
            if deficit > epsilon, index > 0 {
                let room = max(0, (bottoms[index - 1] - tops[index - 1]) - floorHeight)
                let borrowed = min(deficit, room)
                tops[index] -= borrowed
                bottoms[index - 1] = tops[index]
            }
        }

        return slots.indices.map { index in
            GuideSlotFrame(
                program: slots[index],
                y: tops[index],
                height: max(0, bottoms[index] - tops[index])
            )
        }
    }

    /// 見えている範囲。縦は `verticalBucket` 単位、横は列単位に丸めるので、
    /// 指を動かしている間に何度も作り直さない。
    static func visibleWindow(
        contentOffset: CGPoint,
        viewportSize: CGSize,
        columnCount: Int,
        verticalBucket: CGFloat = 240
    ) -> GuideVisibleWindow {
        guard columnCount > 0, viewportSize.height > 0 else { return .unbounded }
        let bucket = max(1, verticalBucket)
        let top = (contentOffset.y / bucket).rounded(.down) * bucket
        let bottom = ((contentOffset.y + viewportSize.height) / bucket).rounded(.up) * bucket

        let width = ProgramGuideMetrics.stationWidth
        let firstColumn = max(0, Int((contentOffset.x / width).rounded(.down)) - 1)
        let visibleColumns = max(1, Int((max(0, viewportSize.width) / width).rounded(.up)))
        let lastColumn = min(columnCount, firstColumn + visibleColumns + 2)
        guard firstColumn < lastColumn else { return .unbounded }

        return GuideVisibleWindow(
            columns: firstColumn ..< lastColumn,
            minY: top - bucket,
            maxY: bottom + bucket
        )
    }
}
