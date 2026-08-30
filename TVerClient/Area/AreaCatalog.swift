import Foundation

/// 地方ブロック。エリアピッカーのセクション分けに使う。
enum TVerBroadcastRegion: String, CaseIterable, Codable, Hashable, Sendable {
    case hokkaido
    case tohoku
    case kanto
    case chubu
    case kinki
    case chugoku
    case shikoku
    case kyushu

    var name: String {
        switch self {
        case .hokkaido: return "北海道"
        case .tohoku: return "東北"
        case .kanto: return "関東"
        case .chubu: return "中部"
        case .kinki: return "近畿"
        case .chugoku: return "中国"
        case .shikoku: return "四国"
        case .kyushu: return "九州・沖縄"
        }
    }
}

/// カタログ 1 件ぶんの都道府県。
struct TVerAreaEntry: Identifiable, Hashable, Sendable {
    let code: String
    let name: String
    let region: TVerBroadcastRegion

    var id: String { code }
    var area: TVerArea { TVerArea(code: code, name: name) }
}

/// エリアピッカーの 1 セクション。
struct TVerAreaGroup: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let areas: [TVerArea]
}

/// 放送エリア（都道府県）のカタログ。
///
/// コードは JIS X 0401（ISO 3166-2:JP と同じ都道府県番号）の 2 桁ゼロ埋め。
/// TVer のプラットフォーム API にはエリア指定パラメータもエリア一覧エンドポイントも
/// 存在せず（area / areaCode / areaId を付けても callLiveChannel は常に在京 5 局を返し、
/// callArea 系はすべて 404）、コード体系はクライアント側で決めるしかない。
/// 日本の他データセットと突き合わせられる JIS を採用している。
enum TVerAreaCatalog {
    static let entries: [TVerAreaEntry] = [
        TVerAreaEntry(code: "01", name: "北海道", region: .hokkaido),
        TVerAreaEntry(code: "02", name: "青森", region: .tohoku),
        TVerAreaEntry(code: "03", name: "岩手", region: .tohoku),
        TVerAreaEntry(code: "04", name: "宮城", region: .tohoku),
        TVerAreaEntry(code: "05", name: "秋田", region: .tohoku),
        TVerAreaEntry(code: "06", name: "山形", region: .tohoku),
        TVerAreaEntry(code: "07", name: "福島", region: .tohoku),
        TVerAreaEntry(code: "08", name: "茨城", region: .kanto),
        TVerAreaEntry(code: "09", name: "栃木", region: .kanto),
        TVerAreaEntry(code: "10", name: "群馬", region: .kanto),
        TVerAreaEntry(code: "11", name: "埼玉", region: .kanto),
        TVerAreaEntry(code: "12", name: "千葉", region: .kanto),
        TVerAreaEntry(code: "13", name: "東京", region: .kanto),
        TVerAreaEntry(code: "14", name: "神奈川", region: .kanto),
        TVerAreaEntry(code: "15", name: "新潟", region: .chubu),
        TVerAreaEntry(code: "16", name: "富山", region: .chubu),
        TVerAreaEntry(code: "17", name: "石川", region: .chubu),
        TVerAreaEntry(code: "18", name: "福井", region: .chubu),
        TVerAreaEntry(code: "19", name: "山梨", region: .chubu),
        TVerAreaEntry(code: "20", name: "長野", region: .chubu),
        TVerAreaEntry(code: "21", name: "岐阜", region: .chubu),
        TVerAreaEntry(code: "22", name: "静岡", region: .chubu),
        TVerAreaEntry(code: "23", name: "愛知", region: .chubu),
        TVerAreaEntry(code: "24", name: "三重", region: .kinki),
        TVerAreaEntry(code: "25", name: "滋賀", region: .kinki),
        TVerAreaEntry(code: "26", name: "京都", region: .kinki),
        TVerAreaEntry(code: "27", name: "大阪", region: .kinki),
        TVerAreaEntry(code: "28", name: "兵庫", region: .kinki),
        TVerAreaEntry(code: "29", name: "奈良", region: .kinki),
        TVerAreaEntry(code: "30", name: "和歌山", region: .kinki),
        TVerAreaEntry(code: "31", name: "鳥取", region: .chugoku),
        TVerAreaEntry(code: "32", name: "島根", region: .chugoku),
        TVerAreaEntry(code: "33", name: "岡山", region: .chugoku),
        TVerAreaEntry(code: "34", name: "広島", region: .chugoku),
        TVerAreaEntry(code: "35", name: "山口", region: .chugoku),
        TVerAreaEntry(code: "36", name: "徳島", region: .shikoku),
        TVerAreaEntry(code: "37", name: "香川", region: .shikoku),
        TVerAreaEntry(code: "38", name: "愛媛", region: .shikoku),
        TVerAreaEntry(code: "39", name: "高知", region: .shikoku),
        TVerAreaEntry(code: "40", name: "福岡", region: .kyushu),
        TVerAreaEntry(code: "41", name: "佐賀", region: .kyushu),
        TVerAreaEntry(code: "42", name: "長崎", region: .kyushu),
        TVerAreaEntry(code: "43", name: "熊本", region: .kyushu),
        TVerAreaEntry(code: "44", name: "大分", region: .kyushu),
        TVerAreaEntry(code: "45", name: "宮崎", region: .kyushu),
        TVerAreaEntry(code: "46", name: "鹿児島", region: .kyushu),
        TVerAreaEntry(code: "47", name: "沖縄", region: .kyushu),
    ]

    static let areas: [TVerArea] = entries.map(\.area)

    /// 起動時の既定エリア。JIS では東京は 13。
    ///
    /// 契約側の `TVerArea.tokyo` はコード 23（JIS では愛知）なので、フォールバックには
    /// こちらを使う。契約ファイルは編集できないため、修正提案としてレポートに残している。
    static let defaultArea = TVerArea(code: "13", name: "東京")

    static let unknownRegionName = "その他"

    private static let lookup: [String: TVerAreaEntry] = Dictionary(
        entries.map { ($0.code, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    static func entry(forCode code: String) -> TVerAreaEntry? { lookup[code] }

    static func area(forCode code: String) -> TVerArea? { entry(forCode: code)?.area }

    static func region(forCode code: String) -> TVerBroadcastRegion? { entry(forCode: code)?.region }

    static func regionName(forCode code: String) -> String {
        region(forCode: code)?.name ?? unknownRegionName
    }

    /// 渡されたエリア一覧を地方ブロックごとにまとめる。カタログ外のコードは末尾の
    /// 「その他」に寄せて、ピッカーから消えないようにする。
    static func groups(of areas: [TVerArea]) -> [TVerAreaGroup] {
        var buckets: [TVerBroadcastRegion: [TVerArea]] = [:]
        var unknown: [TVerArea] = []
        for area in areas {
            if let region = region(forCode: area.code) {
                buckets[region, default: []].append(area)
            } else {
                unknown.append(area)
            }
        }
        var groups = TVerBroadcastRegion.allCases.compactMap { region -> TVerAreaGroup? in
            guard let list = buckets[region], !list.isEmpty else { return nil }
            return TVerAreaGroup(id: region.rawValue, name: region.name, areas: list)
        }
        if !unknown.isEmpty {
            groups.append(TVerAreaGroup(id: "unknown", name: unknownRegionName, areas: unknown))
        }
        return groups
    }
}

extension TVerArea {
    /// ピッカーに出す 47 都道府県。
    static let builtIn: [TVerArea] = TVerAreaCatalog.areas

    /// 保存値が無い / 壊れているときに選ぶエリア。
    static var defaultArea: TVerArea { TVerAreaCatalog.defaultArea }

    var region: TVerBroadcastRegion? { TVerAreaCatalog.region(forCode: code) }

    var regionName: String { TVerAreaCatalog.regionName(forCode: code) }
}

/// 「このエリアで実際に何が見られるのか」を、再生を試す前に伝えるための文言。
///
/// リアルタイム配信は 2022-04-11 以降エリアフリーで、全国どこでも在京 5 局の同一配信。
/// 再生可否はエリア選択ではなく視聴者の IP が日本国内かどうかで決まり、国外 IP からは
/// 再生 API が 403 を返す（番組表とチャンネル一覧は国外からでも取得できる）。
enum TVerAreaAvailability {
    static let nationwideNotice =
        "リアルタイム配信は全国共通です。在京5局（日テレ・テレビ朝日・TBS・テレ東・フジテレビ）の同じ配信が流れます。"
    static let areaSwitchNotice = "エリアを切り替えてもチャンネルと番組表は変わりません。"
    static let domesticOnlyNotice =
        "再生できるのは日本国内の回線からのみです。国外からは番組表は見られても再生は許可されません。"

    static func headline(for area: TVerArea) -> String {
        "\(area.name)エリアで視聴できるチャンネル"
    }

    static func detail(for area: TVerArea) -> String {
        let local: String
        if TVerAreaCatalog.region(forCode: area.code) == .kanto {
            local = "\(area.name)の地上波とほぼ同じ内容です。"
        } else {
            local = "\(area.regionName)の系列局が放送している番組とは内容が異なります。"
        }
        return nationwideNotice + local + areaSwitchNotice + domesticOnlyNotice
    }

    /// 行に出す再生不可の理由。再生できる行では nil。
    static func rowCaution(for channel: TVerLiveChannel) -> String? {
        channel.isPlayable ? nil : "\(channel.state.label)のため再生できません"
    }
}
