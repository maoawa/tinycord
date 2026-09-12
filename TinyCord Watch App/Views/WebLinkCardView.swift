//
//  WebLinkCardView.swift
//  TinyCord Watch App
//

import SwiftUI

public struct WebLinkCardView: View {
    let url: URL
    let embed: DiscordEmbed?

    @Environment(\.openURL) private var openURL
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var endpointConfig = EndpointConfig.shared

    public init(url: URL, embed: DiscordEmbed? = nil) {
        self.url = url
        self.embed = embed
    }

    private var hostDisplay: String {
        url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
    }

    private var displayTitle: String? {
        if let title = embed?.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return nil
    }

    private var displayDescription: String? {
        if let desc = embed?.description, !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return desc
        }
        return nil
    }

    private var thumbnailURL: URL? {
        if let thumb = embed?.thumbnail?.resolvedURL(cdnBase: endpointConfig.cdnBaseURL) {
            return thumb
        }
        if let img = embed?.image?.resolvedURL(cdnBase: endpointConfig.cdnBaseURL) {
            return img
        }
        return nil
    }

    public var body: some View {
        Button {
            openURL(url)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                // Header: Host domain + open icon
                HStack(spacing: 4) {
                    Image(systemName: "safari.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(themeManager.color)

                    Text(hostDisplay)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }

                // Title
                if let title = displayTitle {
                    Text(title)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                // Description and optional thumbnail
                HStack(alignment: .top, spacing: 6) {
                    if let desc = displayDescription {
                        Text(desc)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer(minLength: 0)

                    if let thumbURL = thumbnailURL {
                        CachedAsyncImage(url: thumbURL) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 36, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            default:
                                EmptyView()
                            }
                        }
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}
