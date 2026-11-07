import SwiftUI

/// Version de l'app et commit compilé, discrets dans un coin de l'écran : on sait toujours quelle version tourne sur
/// l'iPhone, même quand le numéro de version ne change pas d'un essai à l'autre.
struct BuildLabel: View {
    var body: some View {
        Text(verbatim: Self.text)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
            .shadow(color: .black.opacity(0.6), radius: 2)
            .allowsHitTesting(false)
    }

    /// « v0.2.0 · 2bc2751 » : `CFBundleShortVersionString`, puis le commit que le script de compilation écrit dans
    /// `AntiStroboBuild` (project.yml), suivi de « + » si des changements n'étaient pas encore enregistrés dans git.
    static let text: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        guard let build = info?["AntiStroboBuild"] as? String, !build.isEmpty else { return "v\(version)" }
        return "v\(version) · \(build)"
    }()
}
