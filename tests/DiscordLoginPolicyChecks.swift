import Foundation

@main
struct DiscordLoginPolicyChecks {
    static func main() throws {
        for value in ["https://discord.com/login", "https://discord.com:443/login?redirect_to=%2Fchannels%2F%40me"] {
            precondition(DiscordLoginPolicy.isDiscordOrigin(URL(string: value)), value)
        }
        for value in ["http://discord.com/login", "https://discord.com.example.org/login",
                      "https://example.org/discord.com", "https://discord.com:8443/login",
                      "https://user:password@discord.com/login", "https://discord.com@evil.example/login",
                      "https://canary.discord.com/login", "file:///login.html", "about:blank"] {
            precondition(!DiscordLoginPolicy.isDiscordOrigin(URL(string: value)), value)
        }
        precondition(!DiscordLoginPolicy.isDiscordOrigin(nil))
        try DiscordLoginPolicy.formSupportScript.write(toFile: CommandLine.arguments[1],
                                                       atomically: true, encoding: .utf8)
        print("PASS: login origin policy")
    }
}
