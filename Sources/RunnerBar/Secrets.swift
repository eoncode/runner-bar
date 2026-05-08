// MARK: - Secrets
//
// ⚠️  DO NOT EDIT BY HAND.
// This file is overwritten by build.sh before every release build using
// RUNNERBAR_CLIENT_ID and RUNNERBAR_CLIENT_SECRET environment variables.
// Placeholder values below keep `swift build` green in development without
// real credentials in source control.
//
// To build a release binary locally:
//   RUNNERBAR_CLIENT_ID=xxx RUNNERBAR_CLIENT_SECRET=yyy ./build.sh

enum Secrets {
    /// GitHub OAuth App client ID. Replaced at build time by build.sh.
    static let clientID: String = "PLACEHOLDER_CLIENT_ID"
    /// GitHub OAuth App client secret. Replaced at build time by build.sh.
    static let clientSecret: String = "PLACEHOLDER_CLIENT_SECRET"
}
