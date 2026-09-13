//
//  AttachmentView.swift
//  TinyCord Watch App
//

import SwiftUI

struct AttachmentView: View {
    let attachment: DiscordAttachment
    @ObservedObject var endpointConfig = EndpointConfig.shared
    @State private var isFullScreenPresented = false

    var body: some View {
        let resolved = attachment.resolvedURL(cdnBase: endpointConfig.cdnBaseURL)
        let dims: CGSize? = {
            if let w = attachment.width, let h = attachment.height, w > 0, h > 0 {
                return CGSize(width: CGFloat(w), height: CGFloat(h))
            }
            return nil
        }()

        if attachment.isImage, let imageURL = resolved {
            CachedGIFImageView(
                url: imageURL,
                dynamicBubbleSizing: true,
                initialDimensions: dims,
                contentMode: .fill,
                cornerRadius: 8,
                onImageTap: {
                    isFullScreenPresented = true
                }
            )
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
