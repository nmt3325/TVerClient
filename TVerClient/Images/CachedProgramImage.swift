import SwiftUI
import UIKit

/// A reusable thumbnail view backed by `ProgramImagePipeline`.
struct CachedProgramImage<Placeholder: View>: View {
    let url: URL?
    let contentMode: ContentMode
    let accessibilityLabel: String?
    private let pipeline: ProgramImagePipeline
    private let placeholder: () -> Placeholder

    @StateObject private var loader = CachedProgramImageLoader()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        url: URL?,
        pipeline: ProgramImagePipeline = .shared,
        contentMode: ContentMode = .fill,
        accessibilityLabel: String? = nil,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.pipeline = pipeline
        self.contentMode = contentMode
        self.accessibilityLabel = accessibilityLabel
        self.placeholder = placeholder
    }

    var body: some View {
        // 下敷きは常に置いたままにして、実画像をその上に重ねる。差し替えでは
        // なく重ね合わせなので、切り替わりの瞬間に何も無いコマが挟まらない。
        ZStack {
            backdrop

            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .accessibilityLabel(accessibilityLabel ?? "番組画像")
            }
        }
        .animation(fadeInAnimation, value: loader.image != nil)
        .onAppear {
            loader.load(url, using: pipeline)
        }
        .onChange(of: url) { newURL in
            loader.load(newURL, using: pipeline)
        }
        .onDisappear {
            loader.cancel()
        }
    }

    /// 取得できなかったことを黙って隠さない。読み込み中は呼び出し側の
    /// プレースホルダ、失敗後は共通の「画像なし」表示に切り替える。
    @ViewBuilder
    private var backdrop: some View {
        if loader.didFail {
            MediaThumbnailUnavailable()
        } else {
            placeholder()
        }
    }

    /// キャッシュから即返ってきた画像までフェードさせるとスクロール中に
    /// 全行がちらつくので、その場合はアニメーションを付けない。
    private var fadeInAnimation: Animation? {
        if reduceMotion || loader.wasServedFromCache { return nil }
        return .easeOut(duration: DS.Motion.fadeInDuration)
    }
}

extension CachedProgramImage where Placeholder == Color {
    init(
        url: URL?,
        pipeline: ProgramImagePipeline = .shared,
        contentMode: ContentMode = .fill,
        accessibilityLabel: String? = nil,
        placeholderColor: Color = Color(uiColor: .secondarySystemBackground)
    ) {
        self.init(
            url: url,
            pipeline: pipeline,
            contentMode: contentMode,
            accessibilityLabel: accessibilityLabel
        ) {
            placeholderColor
        }
    }
}

/// SwiftUI invokes this loader on the main thread; the pipeline callback explicitly hops there.
private final class CachedProgramImageLoader: ObservableObject, @unchecked Sendable {
    @Published private(set) var image: UIImage?
    /// 失敗したまま黙って空白にしないための状態。
    @Published private(set) var didFail = false
    /// メモリキャッシュから同期的に得られた画像かどうか。
    private(set) var wasServedFromCache = false

    private var request: ProgramImageRequest?
    private var representedURL: URL?

    func load(_ url: URL?, using pipeline: ProgramImagePipeline) {
        if representedURL == url, image != nil || request != nil {
            return
        }

        cancel()
        // 同じ URL を読み直すときは表示中の画像を残す。消してから読み直すと
        // 再表示のたびにプレースホルダが一瞬挟まる。
        if representedURL != url {
            image = nil
        }
        representedURL = url
        didFail = false
        wasServedFromCache = false

        guard let url else { return }
        if let cachedImage = pipeline.cachedImage(for: url) {
            wasServedFromCache = true
            image = cachedImage
            return
        }

        request = pipeline.loadImage(from: url) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.representedURL == url else { return }
                self.request = nil
                switch result {
                case let .success(image):
                    self.image = image
                    self.didFail = false
                case .failure:
                    self.didFail = true
                }
            }
        }
    }

    func cancel() {
        request?.cancel()
        request = nil
    }

    deinit {
        request?.cancel()
    }
}
