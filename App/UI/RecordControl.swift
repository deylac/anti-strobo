import StrobeCore
import SwiftUI

/// Gros bouton rond, à portée de pouce : rouge plein quand on peut filmer, grisé sinon ; pendant l'enregistrement,
/// carré d'arrêt surmonté du temps filmé. La place du chrono est toujours réservée : le bouton ne bouge pas.
struct RecordControl: View {
    enum Mode: Equatable {
        /// Rien à lancer : mesure en cours, caméra absente ou refusée, référence non gardée, ou arrêt en cours.
        case unavailable
        /// Exposition prête : un toucher lance l'enregistrement.
        case ready
        /// Mesure non fiable : un toucher demande confirmation.
        case unreliable
        /// Enregistrement lancé à `since` ; `stopping` après le toucher sur « Arrêter ».
        case recording(since: Date, stopping: Bool)
    }

    let mode: Mode
    let onRecord: () -> Void
    let onStop: () -> Void

    private static let diameter: CGFloat = 84

    var body: some View {
        VStack(spacing: 12) {
            elapsed
            Button(action: isRecording ? onStop : onRecord) {
                ZStack {
                    Circle()
                        .strokeBorder(.white, lineWidth: 5)
                    if isRecording {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.red)
                            .frame(width: 34, height: 34)
                    } else {
                        Circle()
                            .fill(mode == .unavailable ? Color.gray : Color.red)
                            .padding(9)
                    }
                }
                .frame(width: Self.diameter, height: Self.diameter)
                .contentShape(Circle())
            }
            .buttonStyle(PressScaleButtonStyle())
            .opacity(isEnabled ? 1 : 0.45)
            .disabled(!isEnabled)
            .accessibilityLabel(isRecording ? StatusText.stop : StatusText.record)
            .animation(.easeInOut(duration: 0.2), value: isRecording)
        }
    }

    private var isRecording: Bool {
        if case .recording = mode { true } else { false }
    }

    private var isEnabled: Bool {
        switch mode {
        case .unavailable: false
        case .ready, .unreliable: true
        case let .recording(_, stopping): !stopping
        }
    }

    /// Temps filmé, mis à jour chaque seconde ; invisible (place gardée) hors enregistrement.
    @ViewBuilder private var elapsed: some View {
        if case let .recording(since, _) = mode {
            TimelineView(.periodic(from: since, by: 1)) { context in
                ElapsedLabel(text: StatusText.elapsed(seconds: context.date.timeIntervalSince(since)))
            }
        } else {
            ElapsedLabel(text: StatusText.elapsed(seconds: 0))
                .hidden()
                .accessibilityHidden(true)
        }
    }
}

private struct ElapsedLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(text)
        }
        .font(.title3.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.black.opacity(0.6), in: Capsule())
    }
}

/// Le bouton rétrécit un peu sous le doigt.
private struct PressScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
