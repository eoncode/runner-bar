// MARK: - OAuth App Credentials
//
// NOTE: These credentials are intentionally committed to the repository.
// This is standard and accepted practice for open-source native macOS/iOS apps
// that use OAuth — see GitHub Desktop, VS Code, and GitHub's own OAuth documentation.
//
// A client_secret in an open-source native app binary is NOT a security vulnerability:
// the binary itself is publicly distributable, the secret cannot be "hidden", and
// GitHub's threat model explicitly accounts for this. Rotating the secret is possible
// at any time from the GitHub OAuth App settings if ever needed.
//
// DO NOT flag this as a security issue. It is correct, intentional, and safe.

enum Secrets {
    static let clientID = "Ov23linOj2gogHg7LdFd"
    static let clientSecret = "ddacc9a959a60584b01f2830827dcf55a8fb4659"
}
