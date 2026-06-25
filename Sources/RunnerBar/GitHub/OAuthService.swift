// OAuthService.swift
// RunnerBar
//
// ⚠️ TOMBSTONE — this file has been removed.
//
// `OAuthService` now lives in `RunnerBarCore`:
//   Sources/RunnerBarCore/GitHub/OAuthService.swift
//
// `signIn()` has been replaced by `makeSignInURL() -> URL?`.
// Call sites that previously called `oauthService.signIn()` should now do:
//
//   if let url = oauthService.makeSignInURL() {
//       NSWorkspace.shared.open(url)
//   }
//
// See: https://github.com/eoncode/runner-bar/issues/1619
