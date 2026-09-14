import Foundation

// Run with scripts/test-server-address.sh; no device or signing profile required.
@main
struct ServerAddressTests {
    static func main() throws {
        let accepted: [(String, String)] = [
            ("freereps.example.com", "https://freereps.example.com:443"),
            (" freereps.example.com/\n", "https://freereps.example.com:443"),
            ("https://freereps.example.com/", "https://freereps.example.com"),
            ("https://freereps.example.com:8443///", "https://freereps.example.com:8443"),
            ("http://127.0.0.1:8080/", "http://127.0.0.1:8080"),
            ("[::1]:8080/", "https://[::1]:8080"),
        ]
        for (input, expected) in accepted {
            let actual = try FreeRepsConfig(host: input, port: 443).validatedBaseURL().absoluteString
            precondition(actual == expected, "Expected \(expected), got \(actual)")
        }
        let rejected = ["", " ", "https://", "bad host", "https://host/api", "host?token=secret",
                        "host#fragment", "user:password@host", "ftp://host", "host:0", "host:65536",
                        "host\\other", "https:///", "https://host/path/"]
        for input in rejected {
            do {
                _ = try FreeRepsConfig(host: input, port: 443).validatedBaseURL()
                preconditionFailure("Accepted invalid input: \(input)")
            } catch is FreeRepsConfigError {
                // A useful validation error, never a forced-unwrap crash.
            }
        }
        let local = try FreeRepsConfig(host: "localhost", port: 8080, useHTTPS: false).validatedBaseURL()
        precondition(local.absoluteString == "http://localhost:8080")
        let test = try FreeRepsConfig(host: "production.example", port: 443, testMode: true,
                                     testHost: "https://test.example/", testPort: 8443).validatedBaseURL()
        precondition(test.absoluteString == "https://test.example")
        do {
            _ = try FreeRepsConfig(host: "localhost", port: 0).validatedBaseURL()
            preconditionFailure("Accepted port zero")
        } catch is FreeRepsConfigError {}
        print("Server address tests passed (23 cases)")
    }
}
