import SwiftUI

/// Badge du haut, bien visible : compte à rebours de la mesure (neutre), caméra en pause (neutre), « Exposition
/// prête » (vert), échec ou problème de caméra (orange). Pour VoiceOver, c'est aussi le bouton qui relance la mesure (à l'écran, c'est un
/// toucher sur l'aperçu).
struct MeasurementBadge: View {
    struct Content {
        var text: String
        var tone: Tone
    }

    enum Tone {
        case measuring(progress: Double)
        /// Caméra interrompue : rien ne se mesure, l'état reprendra seul.
        case paused
        case ready
        case warning
    }

    let content: Content
    /// Position du badge dans sa largeur maximale : centré debout, à gauche couché (aligné sur le reste).
    let alignment: HorizontalAlignment
    let canRemeasure: Bool
    let remeasure: () -> Void

    var body: some View {
        label
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(canRemeasure ? .isButton : [])
            .accessibilityAction {
                if canRemeasure { remeasure() }
            }
    }

    private var label: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            Text(content.text)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.headline)
        .monospacedDigit()
        .foregroundStyle(foreground)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        // Rectangle arrondi plutôt que capsule : les messages d'échec tiennent sur plusieurs lignes.
        .background(background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .frame(maxWidth: 440, alignment: Alignment(horizontal: alignment, vertical: .center))
        .animation(.easeInOut(duration: 0.2), value: content.text)
    }

    @ViewBuilder private var icon: some View {
        switch content.tone {
        case let .measuring(progress):
            ZStack {
                Circle().stroke(.white.opacity(0.3), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(1.5)
        case .paused:
            Image(systemName: "pause.circle.fill")
        case .ready:
            Image(systemName: "checkmark.circle.fill")
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
        }
    }

    private var foreground: Color {
        switch content.tone {
        case .measuring, .paused: .white
        case .ready, .warning: .black
        }
    }

    private var background: Color {
        switch content.tone {
        case .measuring, .paused: .black.opacity(0.6)
        case .ready: .green
        case .warning: .orange
        }
    }
}
