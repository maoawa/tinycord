import Foundation

@main
struct StickerChecks {
    static func main() throws {
        func sticker(_ format: Int) throws -> DiscordStickerItem {
            try JSONDecoder().decode(DiscordStickerItem.self, from: Data("{\"id\":\"12345678901234567\",\"name\":\"Test\",\"format_type\":\(format)}".utf8))
        }
        let lottie = try sticker(3)
        precondition(lottie.stickerURL(cdnBase: "https://cdn.example.com")?.pathExtension == "json")
        precondition(lottie.displayURL(cdnBase: "https://cdn.example.com", companionURL: nil) == nil)
        precondition(lottie.displayURL(cdnBase: "https://cdn.example.com", companionURL: "http://companion.example.com") == nil)
        precondition(lottie.displayURL(cdnBase: "https://cdn.example.com", companionURL: "https://companion.example.com")?.absoluteString
                     == "https://companion.example.com/v1/stickers/12345678901234567.png")
        for (format, ext) in [(1, "png"), (2, "png"), (4, "gif")] {
            let item = try sticker(format)
            precondition(item.displayURL(cdnBase: "https://cdn.example.com", companionURL: nil)?.pathExtension == ext)
        }
        print("Sticker format and Companion URL checks passed.")
    }
}
