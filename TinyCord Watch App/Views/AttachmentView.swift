//
//  AttachmentView.swift
//  TinyCord Watch App
//

import SwiftUI

struct AttachmentView: View {
    let attachment: DiscordAttachment
    @ObservedObject var endpointConfig = EndpointConfig.shared
    @State private var isFullScreenPresented = false

    /// Computes proportional width & height while capping extreme ratios (e.g. 1:10 or 10:1)
    private var previewSize: CGSize {
        let maxDim: CGFloat = 140 // Maximum dimension for watch bubble
        let minDim: CGFloat = 55  // Minimum dimension so it stays legible

        let rawWidth = CGFloat(attachment.width ?? 140)
        let rawHeight = CGFloat(attachment.height ?? 105)

        // Calculate aspect ratio (width / height)
        let rawRatio = rawHeight > 0 ? (rawWidth / rawHeight) : 1.33

        // Clamp ratio between 1:2.5 (portrait) and 2.5:1 (landscape)
        let clampedRatio = min(max(rawRatio, 1.0 / 2.5), 2.5)

        let targetWidth: CGFloat
        let targetHeight: CGFloat

        if clampedRatio >= 1.0 {
            // Landscape or square
            targetWidth = maxDim
            targetHeight = max(minDim, min(maxDim, maxDim / clampedRatio))
        } else {
            // Portrait
            targetHeight = maxDim
            targetWidth = max(minDim, min(maxDim, maxDim * clampedRatio))
        }

        return CGSize(width: targetWidth, height: targetHeight)
    }

    var body: some View {
        let resolved = attachment.resolvedURL(cdnBase: endpointConfig.cdnBaseURL)
        let size = previewSize

        if attachment.isImage, let imageURL = resolved {
            Button {
                isFullScreenPresented = true
            } label: {
                CachedGIFImageView(url: imageURL, targetSize: size, contentMode: .fill, cornerRadius: 8)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $isFullScreenPresented) {
                PhotoDetailView(imageURL: imageURL)
            }
        } else {
            // Non-image attachment pill
            HStack(spacing: 6) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.purple)

                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.filename)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text(formatFileSize(attachment.size))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .background(Color.gray.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func formatFileSize(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return "\(bytes / 1024) KB"
        } else {
            let mb = Double(bytes) / (1024.0 * 1024.0)
            return String(format: "%.1f MB", mb)
        }
    }
}
