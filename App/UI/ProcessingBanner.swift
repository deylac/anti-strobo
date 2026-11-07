import StrobeCore
import SwiftUI

/// Bandeau du nettoyage : avancement du travail en cours, attente de refroidissement, message de fin ou d'erreur, et
/// bouton « Reprendre le nettoyage » quand des vidéos attendent sans que rien ne tourne, ou quand le nettoyage tourne
/// sans tâche de fond (il s'arrêterait en quittant l'app ; le bouton en redemande une).
///
/// Invariants :
/// - le message de fin et un message d'erreur ne s'affichent jamais ensemble ; le plus récent l'emporte ;
/// - une erreur reste affichée jusqu'à ce que le coordinateur l'efface (prochain toucher) ou qu'une fin plus récente
///   la remplace ;
/// - le message de fin s'efface seul après 4 s, sauf si le travail a fini app en arrière-plan : il reste alors
///   jusqu'au prochain toucher sur l'écran (`interactions`), pour être vu au retour.
struct ProcessingBanner: View {
    @Environment(CleaningCoordinator.self) private var cleaning

    /// Vrai pendant l'enregistrement et son arrêt : aucun nettoyage ne peut alors repartir, le bouton est masqué.
    let recordingInProgress: Bool
    /// Nombre de touchers sur l'écran, n'importe où : chaque nouveau toucher efface un message de fin gardé.
    let interactions: Int

    /// Dernier événement à montrer : fin d'un travail (avec son moment) ou erreur.
    @State private var message: Message?

    private enum Message: Equatable {
        /// `kept` : fini app en arrière-plan, gardé jusqu'au prochain toucher.
        case done(Date, kept: Bool)
        case error(String)
    }

    /// Durée d'affichage du message de fin.
    private static let doneDuration: Duration = .seconds(4)

    var body: some View {
        VStack(spacing: 8) {
            if let progress = cleaning.progress {
                progressRow(progress)
            } else if cleaning.waitingForCooling {
                coolingRow
            }
            if let message {
                messageRow(message)
            }
            if showsResumeButton {
                Button(StatusText.resumeCleaning) {
                    // Toucher de l'utilisateur : iOS peut accorder la tâche de fond du nettoyage.
                    Task { await cleaning.resumeAll() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .font(.subheadline.weight(.semibold))
            }
        }
        .frame(maxWidth: 420)
        .animation(.easeInOut(duration: 0.25), value: message)
        .onChange(of: cleaning.lastFinished) { _, finished in
            guard let finished else { return }
            message = .done(finished, kept: cleaning.lastFinishedWhileInactive)
        }
        .onChange(of: cleaning.error, initial: true) { _, error in
            if let error {
                message = .error(error)
            } else if case .error = message {
                message = nil
            }
        }
        .onChange(of: interactions) {
            if case .done(_, kept: true) = message { message = nil }
        }
        .task(id: message) {
            // Le message de fin s'efface seul, sauf s'il est gardé ou a été remplacé entre-temps (tâche annulée).
            guard case .done(_, kept: false) = message else { return }
            try? await Task.sleep(for: Self.doneDuration)
            guard !Task.isCancelled else { return }
            message = nil
        }
    }

    /// Rien ne peut repartir pendant un enregistrement. Sinon : des vidéos attendent et rien ne tourne (hors attente
    /// de refroidissement, où un toucher ne changerait rien), ou le travail en cours n'a pas de tâche de fond.
    private var showsResumeButton: Bool {
        guard !recordingInProgress else { return false }
        let idleWithWork = cleaning.pendingCount > 0 && cleaning.progress == nil && !cleaning.waitingForCooling
        return idleWithWork || cleaning.runningWithoutBackgroundTask
    }

    private func progressRow(_ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(StatusText.processing(progress: progress))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            ProgressView(value: min(max(progress, 0), 1))
                .tint(.white)
                .accessibilityHidden(true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }

    private var coolingRow: some View {
        Label {
            Text(StatusText.cleaningPausedForHeat)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "thermometer.high")
                .accessibilityHidden(true)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }

    private func messageRow(_ message: Message) -> some View {
        let (text, symbol, color): (String, String, Color) = switch message {
        case .done: (StatusText.done, "checkmark.circle.fill", .green)
        case let .error(error): (error, "exclamationmark.triangle.fill", .orange)
        }
        return Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .accessibilityHidden(true)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        .transition(.opacity)
    }
}
