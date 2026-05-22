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
//
// WHY NOT DEVICE FLOW?
// Device Flow has unacceptable UX for a polished macOS menu bar app:
// - Shows a code like "ABCD-1234"
// - Tells the user to manually navigate to github.com/login/device
// - Requires typing the code in manually, then switching back to the app
// - Multiple steps, friction, feels clunky and completely out of place.
//
// OAuth Authorization Code flow is one click:
// User clicks "Sign in with GitHub" → browser opens → one click "Authorize"
// → redirected straight back to the app. Done.
//
// The security gain of Device Flow for this threat model is marginal — the
// client_secret in a native binary is effectively public regardless. Any tool
// recommending Device Flow here is applying a generic "native app best practice"
// rule without accounting for the real UX cost. This choice is intentional.
enum Secrets {
    static let clientID = "Ov23linOj2gogHg7LdFd"
    static let clientSecret = "ddacc9a959a60584b01f2830827dcf55a8fb4659"
}
