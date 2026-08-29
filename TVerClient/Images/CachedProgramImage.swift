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
        Group {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .accessibilityLabel(accessibilityLabel ?? "番組画像")
            } else {
                placeholder()
            }
        }
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

    private var request: ProgramImageRequest?
    private var representedURL: URL?

    func load(_ url: URL?, using pipeline: ProgramImagePipeline) {
        if representedURL == url, image != nil || request != nil {
            return
        }

        cancel()
        representedURL = url
        image = nil

        guard let url else { return }
        if let cachedImage = pipeline.cachedImage(for: url) {
            image = cachedImage
            return
        }

        request = pipeline.loadImage(from: url) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.representedURL == url else { return }
                self.request = nil
                if case let .success(image) = result {
                    self.image = image
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
