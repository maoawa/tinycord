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
            .visibleMediaTask(url: url) {
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

        let image = await MediaCacheService.shared.loadImage(from: url)
        guard !Task.isCancelled else { return }
        if let image {
            phase = .success(Image(uiImage: image))
        } else {
            phase = .failure(URLError(.cannotDecodeContentData))
        }
    }
}

// MARK: - Animated Image Support (GIF, WebP, APNG)

public struct GIFFrame: Sendable {
    public let image: UIImage
    public let duration: TimeInterval
}

public enum GIFDecoder {
    public static func isAnimated(data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

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
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any] {
                if let gifProps = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                    if let unclamped = gifProps[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber,
                       unclamped.doubleValue > 0.01 {
                        duration = unclamped.doubleValue
                    } else if let delay = gifProps[kCGImagePropertyGIFDelayTime] as? NSNumber,
                              delay.doubleValue > 0.01 {
                        duration = delay.doubleValue
                    }
                } else if let webpProps = properties[kCGImagePropertyWebPDictionary] as? [CFString: Any] {
                    if let unclamped = webpProps[kCGImagePropertyWebPUnclampedDelayTime] as? NSNumber,
                       unclamped.doubleValue > 0.01 {
                        duration = unclamped.doubleValue
                    } else if let delay = webpProps[kCGImagePropertyWebPDelayTime] as? NSNumber,
                              delay.doubleValue > 0.01 {
                        duration = delay.doubleValue
                    }
                } else if let pngProps = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
                    if let unclamped = pngProps[kCGImagePropertyAPNGUnclampedDelayTime] as? NSNumber,
                       unclamped.doubleValue > 0.01 {
                        duration = unclamped.doubleValue
                    } else if let delay = pngProps[kCGImagePropertyAPNGDelayTime] as? NSNumber,
                              delay.doubleValue > 0.01 {
                        duration = delay.doubleValue
                    }
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

// MARK: - Media Bubble Sizing

public enum MediaBubbleSizer {
    public static let defaultMaxDim: CGFloat = 140
    public static let defaultMinDim: CGFloat = 55
    public static let defaultMaxRatio: CGFloat = 2.5

    /// Computes proportional width & height while capping extreme ratios (e.g. 1:2.5 to 2.5:1)
    public static func bubbleSize(
        width: CGFloat?,
        height: CGFloat?,
        fallbackWidth: CGFloat = 140,
        fallbackHeight: CGFloat = 105,
        maxDim: CGFloat = defaultMaxDim,
        minDim: CGFloat = defaultMinDim,
        maxRatio: CGFloat = defaultMaxRatio
    ) -> CGSize {
        let rawW = (width != nil && width! > 0) ? width! : fallbackWidth
        let rawH = (height != nil && height! > 0) ? height! : fallbackHeight

        let rawRatio = (rawH > 0) ? (rawW / rawH) : 1.33
        let clampedRatio = min(max(rawRatio, 1.0 / maxRatio), maxRatio)

        let targetWidth: CGFloat
        let targetHeight: CGFloat

        if clampedRatio >= 1.0 {
            // Landscape or square: width is maxDim, height scales proportionally
            targetWidth = maxDim
            targetHeight = max(minDim, min(maxDim, maxDim / clampedRatio))
        } else {
            // Portrait: height is maxDim, width scales proportionally
            targetHeight = maxDim
            targetWidth = max(minDim, min(maxDim, maxDim * clampedRatio))
        }

        return CGSize(width: targetWidth, height: targetHeight)
    }
}

public struct CachedGIFImageView: View {
    let url: URL?
    var targetSize: CGSize? = nil
    var dynamicBubbleSizing: Bool = false
    var initialDimensions: CGSize? = nil
    var maxDim: CGFloat = MediaBubbleSizer.defaultMaxDim
    var minDim: CGFloat = MediaBubbleSizer.defaultMinDim
    var maxRatio: CGFloat = MediaBubbleSizer.defaultMaxRatio
    var contentMode: ContentMode = .fill
    var cornerRadius: CGFloat = 8
    var onImageTap: (() -> Void)? = nil

    @State private var frames: [GIFFrame] = []
    @State private var staticImage: UIImage?
    @State private var currentFrameIndex = 0
    @State private var isLoading = true
    @State private var isError = false
    @State private var loadFailure: MediaLoadFailure?
    @State private var isShowingDiagnosticSheet = false
    @State private var timerTask: Task<Void, Never>?
    @State private var retryID = UUID()

    public init(
        url: URL?,
        targetSize: CGSize? = nil,
        dynamicBubbleSizing: Bool = false,
        initialDimensions: CGSize? = nil,
        maxDim: CGFloat = MediaBubbleSizer.defaultMaxDim,
        minDim: CGFloat = MediaBubbleSizer.defaultMinDim,
        maxRatio: CGFloat = MediaBubbleSizer.defaultMaxRatio,
        contentMode: ContentMode = .fill,
        cornerRadius: CGFloat = 8,
        onImageTap: (() -> Void)? = nil
    ) {
        self.url = url
        self.targetSize = targetSize
        self.dynamicBubbleSizing = dynamicBubbleSizing
        self.initialDimensions = initialDimensions
        self.maxDim = maxDim
        self.minDim = minDim
        self.maxRatio = maxRatio
        self.contentMode = contentMode
        self.cornerRadius = cornerRadius
        self.onImageTap = onImageTap

        // Decode only after this media reaches the visible download queue.
    }

    private var effectiveSize: CGSize? {
        if let targetSize {
            return targetSize
        }
        if dynamicBubbleSizing {
            // Once media is decoded, use intrinsic dimensions
            if let first = frames.first {
                return MediaBubbleSizer.bubbleSize(
                    width: first.image.size.width,
                    height: first.image.size.height,
                    maxDim: maxDim,
                    minDim: minDim,
                    maxRatio: maxRatio
                )
            }
            if let staticImage {
                return MediaBubbleSizer.bubbleSize(
                    width: staticImage.size.width,
                    height: staticImage.size.height,
                    maxDim: maxDim,
                    minDim: minDim,
                    maxRatio: maxRatio
                )
            }
            // Before decoded: use initial metadata dimensions if provided
            if let initialDimensions {
                return MediaBubbleSizer.bubbleSize(
                    width: initialDimensions.width,
                    height: initialDimensions.height,
                    maxDim: maxDim,
                    minDim: minDim,
                    maxRatio: maxRatio
                )
            }
            // Fallback placeholder
            return CGSize(width: maxDim, height: 105)
        }
        return nil
    }

    public var body: some View {
        ZStack {
            if !frames.isEmpty {
                // Animated GIF
                let frame = frames[min(currentFrameIndex, frames.count - 1)]
                imageView(Image(uiImage: frame.image))
            } else if let staticImage {
                // Static image
                imageView(Image(uiImage: staticImage))
            } else if isLoading {
                let size = effectiveSize ?? CGSize(width: 120, height: 80)
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: size.width, height: size.height)
                    ProgressView()
                        .scaleEffect(0.7)
                }
            } else if isError {
                let width = effectiveSize?.width ?? 135
                Button {
                    isShowingDiagnosticSheet = true
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                            Text("Media failed")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.red)
                            Spacer(minLength: 0)
                            Image(systemName: "info.circle")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        if let desc = loadFailure?.errorDescription {
                            Text(desc)
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.tail)
                        }
                    }
                    .padding(6)
                    .frame(width: width)
                    .background(Color.red.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $isShowingDiagnosticSheet) {
                    MediaDiagnosticSheet(failure: loadFailure, originalURL: url) {
                        if let url {
                            MediaCacheService.shared.evictCache(for: url)
                        }
                        retryID = UUID()
                    }
                }
            }
        }
        .visibleMediaTask(url: url) {
            await loadMedia()
        }
        .id(retryID)
        .onAppear {
            startAnimationIfNeeded()
        }
        .onDisappear {
            stopAnimation()
        }
    }

    @ViewBuilder
    private func imageView(_ img: Image) -> some View {
        let size = effectiveSize
        let content = img
            .resizable()
            .aspectRatio(contentMode: contentMode)
            .frame(width: size?.width, height: size?.height)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

        if let onImageTap {
            Button(action: onImageTap) {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private func loadMedia() async {
        guard let url else {
            isLoading = false
            return
        }

        // Reuse decoded media when the view task restarts.
        if !frames.isEmpty || staticImage != nil {
            isLoading = false
            startAnimationIfNeeded()
            return
        }

        isLoading = true
        isError = false
        loadFailure = nil

        let result = await MediaCacheService.shared.fetchMedia(from: url)
        guard !Task.isCancelled else { return }
        switch result {
        case .failure(let failure):
            print("[TinyCord Media] Failed to load \(url): \(failure.errorDescription)")
            self.isLoading = false
            self.isError = true
            self.loadFailure = failure
            return

        case .success(let data, let resolvedURL):
            if GIFDecoder.isAnimated(data: data) {
                let decoded = GIFDecoder.decode(data: data)
                if !decoded.isEmpty {
                    self.frames = decoded
                    self.isLoading = false
                    self.startAnimationIfNeeded()
                    return
                }
            }

            // Fallback to static image (supports WebP, PNG, JPEG)
            if let img = UIImage(data: data) {
                self.staticImage = img
                self.isLoading = false
            } else if let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                self.staticImage = UIImage(cgImage: cgImage)
                self.isLoading = false
            } else {
                let snippet = String(data: data.prefix(150), encoding: .utf8)
                let decodeFail = MediaLoadFailure(
                    url: url,
                    resolvedURL: resolvedURL,
                    httpStatusCode: 200,
                    mimeType: nil,
                    dataLength: data.count,
                    errorDescription: "Image decoder failed (\(data.count) bytes)",
                    dataSnippet: snippet
                )
                print("[TinyCord Media] Decoder failed for \(url) (\(data.count) bytes)")
                self.isLoading = false
                self.isError = true
                self.loadFailure = decodeFail
            }
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

// MARK: - Media Diagnostic Sheet

public struct MediaDiagnosticSheet: View {
    public let failure: MediaLoadFailure?
    public let originalURL: URL?
    public let onRetry: () -> Void
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.system(size: 13))
                    Text("Media Diagnostics")
                        .font(.system(size: 12, weight: .bold))
                }
                .padding(.bottom, 2)

                // Error reason
                VStack(alignment: .leading, spacing: 2) {
                    Text("ERROR")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(failure?.errorDescription ?? "Unknown load error")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.red)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // HTTP & Details
                if let status = failure?.httpStatusCode {
                    HStack {
                        Text("HTTP Status:")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(status)")
                            .font(.system(size: 9, weight: .bold))
                    }
                }

                if let length = failure?.dataLength {
                    HStack {
                        Text("Payload Size:")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(length) bytes (\(String(format: "%.1f", Double(length)/1024.0)) KB)")
                            .font(.system(size: 9))
                    }
                }

                if let mime = failure?.mimeType {
                    HStack {
                        Text("MIME Type:")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(mime)
                            .font(.system(size: 9))
                            .lineLimit(1)
                    }
                }

                // Original URL
                if let u = originalURL ?? failure?.url {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("REQUESTED URL")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(u.absoluteString)
                            .font(.system(size: 8, design: .monospaced))
                            .lineLimit(3)
                            .truncationMode(.middle)
                    }
                }

                // Resolved direct URL
                if let r = failure?.resolvedURL, r != (originalURL ?? failure?.url) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("RESOLVED DIRECT URL")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(r.absoluteString)
                            .font(.system(size: 8, design: .monospaced))
                            .lineLimit(3)
                            .truncationMode(.middle)
                    }
                }

                // Snippet of payload if text
                if let snippet = failure?.dataSnippet, !snippet.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("RESPONSE PREVIEW")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(snippet.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 7, design: .monospaced))
                            .padding(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .lineLimit(4)
                    }
                }

                // Action Buttons
                VStack(spacing: 6) {
                    Button {
                        onRetry()
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Retry Download")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)

                    Button("Dismiss") {
                        dismiss()
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 4)
        }
    }
}
