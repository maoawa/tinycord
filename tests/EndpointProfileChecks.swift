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
        print("Profile migration, Companion round-trip and HTTPS validation passed.")
    }
}
