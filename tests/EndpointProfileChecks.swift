// Compile this against each app's EndpointProfile.swift to verify sync compatibility.
import Foundation

@main
struct EndpointProfileChecks {
    static func main() throws {
        let legacy = Data(#"{"id":"custom","name":"Proxy","apiBaseURL":"https://api.example.com","cdnBaseURL":"https://cdn.example.com","gatewayURL":"wss://gateway.example.com","isOfficial":false}"#.utf8)
        var profile = try JSONDecoder().decode(EndpointProfile.self, from: legacy)
        precondition(!profile.presenceEnabled && profile.presenceServerURL.isEmpty)
        precondition(profile.id == "custom" && profile.gatewayURL == "wss://gateway.example.com")
        profile.presenceEnabled = true
        profile.presenceServerURL = "https://companion.example.com"
        let encoded = try JSONEncoder().encode(profile)
        let restored = try JSONDecoder().decode(EndpointProfile.self, from: encoded)
        precondition(restored == profile)
        for valid in ["https://companion.example.com", "https://companion.example.com/", "https://companion.example.com:8443"] {
            precondition(EndpointProfile.validatedPresenceURL(valid) != nil, valid)
        }
        for invalid in ["http://companion.example.com", "wss://companion.example.com", "companion.example.com",
                        "https://user:secret@companion.example.com", "https://companion.example.com/api",
                        "https://companion.example.com?token=secret", "https://companion.example.com#fragment",
                        "https://companion.example.com:0", "https://companion.example.com:65536", "https://"] {
            precondition(EndpointProfile.validatedPresenceURL(invalid) == nil, invalid)
        }
        let main = EndpointProfile.validatedGatewayURL(" wss://gateway.example.com/proxy?v=9&encoding=etf&compress=zlib-stream&route=voice ")!
        let parts = URLComponents(url: main, resolvingAgainstBaseURL: false)!
        precondition(parts.path == "/proxy")
        precondition(parts.queryItems?.contains(URLQueryItem(name: "v", value: "10")) == true)
        precondition(parts.queryItems?.contains(URLQueryItem(name: "encoding", value: "json")) == true)
        precondition(parts.queryItems?.contains(URLQueryItem(name: "route", value: "voice")) == true)
        precondition(parts.queryItems?.contains(where: { $0.name == "compress" }) == false)
        for invalid in ["ws://gateway.example.com", "https://gateway.example.com", "wss://user:pass@gateway.example.com", "wss://gateway.example.com#fragment", "wss://gateway.example.com:0", "wss://gateway.example.com:65536", "wss://"] {
            precondition(EndpointProfile.validatedGatewayURL(invalid) == nil)
        }
        profile.gatewayURL = ""
        precondition(profile.callGatewayURL == EndpointProfile.official.callGatewayURL)
        print("Profile migration, Gateway/Companion round-trip and HTTPS/WSS validation passed.")
    }
}
