// swiftlint:disable missing_docs redundant_discardable_let
import SwiftUI

/// Shows privacy policy and legal links.
struct LegalPrefsView: View {
    @ObservedObject var legalPrefsStore: LegalPrefsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Privacy & Legal")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                linkRow(label: "Privacy Policy",
                        url: "https://github.com/eoncode/runner-bar/blob/main/PRIVACY.md")
                linkRow(label: "Terms of Use",
                        url: "https://github.com/eoncode/runner-bar/blob/main/TERMS.md")
                linkRow(label: "Open Source Licenses",
                        url: "https://github.com/eoncode/runner-bar/blob/main/LICENSES.md")
            }
            Spacer()
        }
        .padding(20)
        .frame(width: 320, alignment: .topLeading)
    }

    private func linkRow(label: String, url: String) -> some View {
        Button(action: {
            if let dest = URL(string: url) { NSWorkspace.shared.open(dest) }
        }) {
            HStack {
                Text(label).font(.system(size: 12))
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption2).foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
// swiftlint:enable missing_docs redundant_discardable_let
