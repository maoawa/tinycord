//
//  CachedAsyncImage.swift
//  TinyCord Watch App
//

import SwiftUI
import UIKit
import ImageIO

public struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    let content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase

    public init(
        url: URL?,
        @ViewBuilder content: @escaping (AsyncImagePhase) -> Content
    ) {
        self.url = url
        self.content = content

        // Synchronous memory cache lookup so cached images render on frame 1 without flashing
        if let url, let cached = MediaCacheService.shared.imageFromMemory(for: url) {
            _phase = State(initialValue: .success(Image(uiImage: cached)))
        } else {
            _phase = State(initialValue: .empty)
        }
    }

    public var body: some View {
        content(phase)
            .task(id: url) {
                await loadImage()
            }
    }

    private func loadImage() async {
        guard let url else {
            phase = .empty
            return
        }

        // Check memory again
        if let cached = MediaCacheService.shared.imageFromMemory(for: url) {
            phase = .success(Image(uiImage: cached))
            return
        }

        phase = .empty

        if let image = await MediaCacheService.shared.loadImage(from: url) {
            phase = .success(Image(uiImage: image))
        } else {
            phase = .failure(URLError(.cannotDecodeContentData))
        }
    }
}

// MARK: - GIF Support

public struct GIFFrame: Sendable {
    public let image: UIImage
    public let duration: TimeInterval
}

public enum GIFDecoder {
    public static func isGIF(data: Data) -> Bool {
        guard data.count >= 3 else { return false }
        let prefix = String(decoding: data.prefix(3), as: UTF8.self)
        return prefix == "GIF"
    }

    public static func decode(data: Data) -> [GIFFrame] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return [] }

        var frames: [GIFFrame] = []
        frames.reserveCapacity(count)

        for i in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            let uiImage = UIImage(cgImage: cgImage)

            var duration: TimeInterval = 0.1
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any],
               let gifProps = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                if let unclamped = gifProps[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber,
                   unclamped.doubleValue > 0.01 {
                    duration = unclamped.doubleValue
                } else if let delay = gifProps[kCGImagePropertyGIFDelayTime] as? NSNumber,
                          delay.doubleValue > 0.01 {
                    duration = delay.doubleValue
                }
            }

            // Standard web browsers clamp delay < 0.02 to 0.10
            if duration < 0.02 {
                duration = 0.1
            }

            frames.append(GIFFrame(image: uiImage, duration: duration))
        }

        return frames
    }
}

public struct CachedGIFImageView: View {
    let url: URL?
    var targetSize: CGSize? = nil
    var contentMode: ContentMode = .fill
    var cornerRadius: CGFloat = 8

    @State private var frames: [GIFFrame] = []
    @State private var staticImage: UIImage?
    @State private var currentFrameIndex = 0
    @State private var isLoading = true
    @State private var isError = false
    @State private var timerTask: Task<Void, Never>?

    public init(
        url: URL?,
        targetSize: CGSize? = nil,
        contentMode: ContentMode = .fill,
        cornerRadius: CGFloat = 8
    ) {
        self.url = url
        self.targetSize = targetSize
        self.contentMode = contentMode
        self.cornerRadius = cornerRadius

        // Synchronous memory cache check
        if let url {
            if let cachedData = MediaCacheService.shared.dataFromMemory(for: url),
               GIFDecoder.isGIF(data: cachedData) {
                let decoded = GIFDecoder.decode(data: cachedData)
                _frames = State(initialValue: decoded)
                _isLoading = State(initialValue: false)
            } else if let cachedImg = MediaCacheService.shared.imageFromMemory(for: url) {
                _staticImage = State(initialValue: cachedImg)
                _isLoading = State(initialValue: false)
            }
        }
    }

    public var body: some View {
        ZStack {
            if !frames.isEmpty {
                // Animated GIF
                let frame = frames[min(currentFrameIndex, frames.count - 1)]
                Image(uiImage: frame.image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .frame(width: targetSize?.width, height: targetSize?.height)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else if let staticImage {
                // Static image
                Image(uiImage: staticImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .frame(width: targetSize?.width, height: targetSize?.height)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else if isLoading {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: targetSize?.width ?? 120, height: targetSize?.height ?? 80)
                    ProgressView()
                        .scaleEffect(0.7)
                }
            } else if isError {
                HStack(spacing: 4) {
                    Image(systemName: "photo.badge.exclamationmark")
                    Text("Media failed")
                        .font(.system(size: 9))
                }
                .padding(6)
                .frame(width: targetSize?.width ?? 120, height: min(targetSize?.height ?? 60, 60))
                .background(Color.red.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .task(id: url) {
            await loadMedia()
        }
        .onAppear {
            startAnimationIfNeeded()
        }
        .onDisappear {
            stopAnimation()
        }
    }

    private func loadMedia() async {
        guard let url else {
            isLoading = false
            return
        }

        // If already populated from sync cache init
        if !frames.isEmpty || staticImage != nil {
            isLoading = false
            startAnimationIfNeeded()
            return
        }

        isLoading = true
        isError = false

        guard let data = await MediaCacheService.shared.loadData(from: url) else {
            isLoading = false
            isError = true
            return
        }

        if GIFDecoder.isGIF(data: data) {
            let decoded = GIFDecoder.decode(data: data)
            if !decoded.isEmpty {
                self.frames = decoded
                self.isLoading = false
                self.startAnimationIfNeeded()
                return
            }
        }

        // Fallback to static UIImage
        if let img = UIImage(data: data) {
            self.staticImage = img
            self.isLoading = false
        } else {
            self.isLoading = false
            self.isError = true
        }
    }

    private func startAnimationIfNeeded() {
        guard frames.count > 1 else { return }
        stopAnimation()

        timerTask = Task { @MainActor in
            while !Task.isCancelled {
                let duration = frames[min(currentFrameIndex, frames.count - 1)].duration
                let nanoseconds = UInt64(duration * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { break }
                currentFrameIndex = (currentFrameIndex + 1) % frames.count
            }
        }
    }

    private func stopAnimation() {
        timerTask?.cancel()
        timerTask = nil
    }
}
