import Foundation

#if DEBUG
enum PreviewFixture {
    static let schedule: [ProgramDay] = [
        ProgramDay(
            date: Date(),
            programs: [
                TVerProgram(
                    id: "preview-news",
                    seriesID: "preview-series-1",
                    title: "春の街を歩く 特別編",
                    seriesTitle: "週末トラベルノート",
                    description: "知られざる街の魅力を訪ねます。",
                    broadcastLabel: "3月10日(月) 放送分",
                    availableUntil: "3月17日(月) 23:59",
                    thumbnailURL: URL(string: "https://placehold.co/640x360/2783DE/FFFFFF.png?text=Weekend+Travel")
                ),
                TVerProgram(
                    id: "preview-drama",
                    seriesID: "preview-series-2",
                    title: "第8話 それぞれの選択",
                    seriesTitle: "青い約束",
                    description: "運命が大きく動き始める第8話。",
                    broadcastLabel: "3月9日(日) 放送分",
                    availableUntil: "3月16日(日) 21:59",
                    thumbnailURL: URL(string: "https://placehold.co/640x360/F0EFED/2C2C2B.png?text=Blue+Promise")
                )
            ]
        ),
        ProgramDay(
            date: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date(),
            programs: [
                TVerProgram(
                    id: "preview-variety",
                    seriesID: "preview-series-3",
                    title: "人気店の舞台裏に密着",
                    seriesTitle: "発見！アイデア図鑑",
                    description: "暮らしを変えるアイデアを紹介します。",
                    broadcastLabel: "3月8日(土) 放送分",
                    availableUntil: nil,
                    thumbnailURL: nil
                )
            ]
        )
    ]
}
#endif
