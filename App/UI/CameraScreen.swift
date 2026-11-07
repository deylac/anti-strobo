import Combine
import StrobeCore
import SwiftUI

/// L'écran unique de l'app : aperçu plein cadre, badge de la mesure de la lumière, état du téléphone (temps
/// restant, batterie, chauffe), gros bouton d'enregistrement et bandeau du nettoyage.
///
/// Branchements, dans cet ordre :
/// - « Filmer » : `setRecordingActive(true)` (arrête tout nettoyage) avant `startRecording()` ; si la caméra a
///   ignoré la demande, `setRecordingActive(false)`.
/// - « Arrêter » : `stopRecording()`, puis `setRecordingActive(false)`, puis le fichier part au nettoyage, dans la
///   tâche du toucher (iOS n'accorde la tâche de fond qu'à la suite d'une action de l'utilisateur).
/// - Coupure non demandée (`onRecordingInterrupted`) : même chose, sans toucher (iOS peut alors refuser la tâche de
///   fond ; le nettoyage tourne au premier plan ou sur « Reprendre le nettoyage »).
/// - Fin d'enregistrement sans fichier (rien n'est rendu) : le nettoyage est rendu possible au retour de
///   `isRecording` à faux, hors arrêt demandé.
///
/// Invariants :
/// - le nettoyage n'est jamais rendu possible (`setRecordingActive(false)`) pendant un enregistrement. Le bouton
///   reste donc inactif du toucher sur « Arrêter » jusqu'à ce `setRecordingActive(false)`, et une coupure ne le fait
///   que si aucun nouvel enregistrement n'a commencé entre-temps ;
/// - l'écran ne se verrouille pas seul pendant un enregistrement (on filme « à l'aveugle »), et seulement pendant :
///   hors enregistrement, le verrouillage automatique d'iOS s'applique (chaleur, batterie, poche).
struct CameraScreen: View {
    @Environment(CleaningCoordinator.self) private var cleaning
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var camera = CameraController()
    /// Vrai du toucher sur « Arrêter » jusqu'à ce que le nettoyage soit de nouveau permis.
    @State private var isStopping = false
    @State private var confirmingUnreliableRecording = false
    /// Espace libre pour les enregistrements, relu toutes les 5 s, au début et à la fin de chaque enregistrement,
    /// et quand des originaux en attente changent (copies locales supprimées après leur rangement).
    @State private var freeBytes: Int64?
    /// Niveau de la batterie (0…1), -1 s'il est inconnu.
    @State private var batteryLevel: Float = -1
    @State private var thermalState = ProcessInfo.processInfo.thermalState
    /// Nombre de touchers sur l'écran, n'importe où (un message de fin gardé s'efface au suivant).
    @State private var interactions = 0

    /// Intervalle de relecture de l'espace libre.
    private static let freeSpaceRefreshInterval: Duration = .seconds(5)
    /// Sous ce niveau, la batterie s'affiche en orange.
    private static let lowBatteryLevel: Float = 0.2

    /// iPhone couché : l'interface passe en colonnes, le bouton sur le bord droit.
    private var isLandscape: Bool { verticalSizeClass == .compact }

    var body: some View {
        ZStack {
            PreviewView(camera: camera)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                // Pendant l'enregistrement, l'exposition est figée : toucher l'aperçu ne fait rien et n'en a pas l'air.
                .onTapGesture { camera.remeasure() }
                .allowsHitTesting(!camera.isRecording)
                .accessibilityHidden(true)

            controls
        }
        // Debout, dans la bande du haut à droite de l'encoche (barre d'état masquée) ; couché, dans le coin haut
        // droit, loin du badge (en haut à gauche) et du bouton (milieu du bord droit).
        .overlay(alignment: .topTrailing) {
            BuildLabel()
                .padding(.trailing, 28)
                .padding(.top, isLandscape ? 10 : 18)
                .ignoresSafeArea(edges: isLandscape ? [] : .top)
        }
        .background(Color.black)
        // Tout l'écran compte un toucher, même là où rien ne réagit, sans gêner les boutons ni l'aperçu.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { interactions += 1 })
        .statusBarHidden()
        .task {
            sendInterruptedRecordingsToCleaning()
            await camera.start()
        }
        .task {
            while !Task.isCancelled {
                await refreshFreeBytes()
                try? await Task.sleep(for: Self.freeSpaceRefreshInterval)
            }
        }
        .onChange(of: camera.isRecording) { _, recording in
            // Un enregistrement coupé sans fichier (coupure avant la première image, enregistreur impossible à
            // créer…) ne passe ni par « Arrêter » ni par `onRecordingInterrupted` : sans ceci, le nettoyage resterait
            // arrêté pour toujours. `isRecording` ne revient à faux qu'une fois l'enregistreur détaché (plus aucune
            // image écrite). Pendant un arrêt demandé, c'est la tâche du toucher qui s'en charge, dans l'ordre voulu.
            if !recording, !isStopping {
                cleaning.setRecordingActive(false)
            }
            keepsScreenAwake()
            Task { await refreshFreeBytes() }
        }
        .onChange(of: cleaning.progress != nil) {
            keepsScreenAwake()
        }
        .onChange(of: cleaning.pendingCleanedBytes) {
            Task { await refreshFreeBytes() }
        }
        .onAppear {
            keepsScreenAwake()
            UIDevice.current.isBatteryMonitoringEnabled = true
            batteryLevel = UIDevice.current.batteryLevel
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            batteryLevel = UIDevice.current.batteryLevel
        }
        .onReceive(
            // Cette notification arrive sur n'importe quelle file.
            NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
                .receive(on: DispatchQueue.main)
        ) { _ in
            thermalState = ProcessInfo.processInfo.thermalState
        }
    }

    // MARK: - Disposition

    /// Debout : informations en haut, bandeau du nettoyage puis bouton en bas. Couché : informations et bandeau à
    /// gauche, bouton au milieu du bord droit. Mêmes vues dans les deux cas (`AnyLayout`) : tourner l'iPhone ne
    /// remet pas leur état à zéro.
    private var controls: some View {
        let layout = isLandscape ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(spacing: 16))
        return layout {
            VStack(alignment: isLandscape ? .leading : .center, spacing: 10) {
                VStack(alignment: isLandscape ? .leading : .center, spacing: 8) {
                    MeasurementBadge(
                        content: badge,
                        alignment: isLandscape ? .leading : .center,
                        canRemeasure: camera.canRemeasure,
                        remeasure: camera.remeasure
                    )
                    StatusRow(remaining: remainingText, battery: batteryText, lowBattery: isBatteryLow)
                    if let thermal = StatusText.thermal(thermalState) {
                        ThermalWarning(text: thermal)
                    }
                }
                // Un toucher sur ces informations passe à l'aperçu (« Touche l'écran pour réessayer »).
                .allowsHitTesting(false)

                Spacer(minLength: 0)
                ProcessingBanner(recordingInProgress: recordingInProgress, interactions: interactions)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isLandscape ? .topLeading : .top)

            RecordControl(mode: recordMode, onRecord: recordTapped, onStop: stopTapped)
                .confirmationDialog(
                    StatusText.unreliableReferenceConfirm,
                    isPresented: $confirmingUnreliableRecording,
                    titleVisibility: .visible
                ) {
                    Button(StatusText.record) { startRecording() }
                    Button(StatusText.cancel, role: .cancel) {}
                }
        }
        .padding(16)
    }

    // MARK: - États affichés

    /// Enregistrement en cours ou en train de s'arrêter : le nettoyage reste bloqué (`setRecordingActive(true)`)
    /// jusqu'à la fin de l'arrêt, donc rien ne doit proposer de le relancer.
    private var recordingInProgress: Bool { camera.isRecording || isStopping }

    /// Texte et ton du badge du haut, par ordre de priorité : accès refusé, caméra arrêtée, caméra en pause (plutôt
    /// qu'un compte à rebours figé), référence non gardée, puis l'état de la mesure.
    private var badge: MeasurementBadge.Content {
        if camera.cameraDenied { return .init(text: StatusText.cameraDenied, tone: .warning) }
        if camera.sessionFailed { return .init(text: StatusText.cameraStopped, tone: .warning) }
        if camera.isPaused { return .init(text: StatusText.cameraPaused, tone: .paused) }
        if camera.referenceLockFailed { return .init(text: StatusText.referenceLockFailed, tone: .warning) }
        let text = StatusText.measurement(camera.measurement)
        return switch camera.measurement {
        case let .measuring(progress, _): .init(text: text, tone: .measuring(progress: progress))
        case .ready: .init(text: text, tone: .ready)
        case .failed: .init(text: text, tone: .warning)
        }
    }

    private var recordMode: RecordControl.Mode {
        if camera.isRecording {
            // `recordingStartedAt` est posé en même temps que `isRecording`.
            return .recording(since: camera.recordingStartedAt ?? .now, stopping: isStopping)
        }
        // `startRecording()` ignorerait la demande : le bouton n'en a pas l'air.
        guard !isStopping, camera.cameraAvailable, !camera.referenceLockFailed else { return .unavailable }
        return switch camera.measurement {
        case .measuring: .unavailable
        case .ready: .ready
        case .failed: .unreliable
        }
    }

    /// Temps d'enregistrement encore possible : débit nominal avant l'enregistrement, mesuré pendant, plus celui
    /// de la copie nettoyée à la cadence de capture. La place des copies nettoyées encore dues (enregistrement en
    /// cours et originaux en attente) est réservée. Rien tant que le débit ou la cadence (caméra pas encore
    /// configurée, ou absente) ou l'espace libre sont inconnus.
    private var remainingText: String? {
        guard let freeBytes, camera.bytesPerSecond > 0, camera.captureFPS > 0 else { return nil }
        let seconds = StorageEstimator.remainingRecordingSeconds(
            freeBytes: freeBytes,
            bytesPerSecond: camera.bytesPerSecond,
            fps: camera.captureFPS,
            recordedBytes: camera.recordedBytes,
            owedCleanedBytes: cleaning.pendingCleanedBytes
        )
        return StatusText.remaining(seconds: seconds)
    }

    private var batteryText: String? { StatusText.battery(level: batteryLevel) }

    private var isBatteryLow: Bool { batteryLevel >= 0 && batteryLevel <= Self.lowBatteryLevel }

    // MARK: - Actions

    private func recordTapped() {
        if case .failed = camera.measurement {
            confirmingUnreliableRecording = true
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        // Le nettoyage s'arrête avant que la caméra n'écrive la première image.
        cleaning.setRecordingActive(true)
        camera.startRecording()
        if !camera.isRecording {
            // Demande ignorée (mesure relancée, référence non gardée…) : le nettoyage redevient possible.
            cleaning.setRecordingActive(false)
        }
    }

    /// Un enregistrement coupé sans « Arrêter » part au nettoyage comme les autres.
    private func sendInterruptedRecordingsToCleaning() {
        // `camera` en référence faible : la fermeture est gardée par `camera` lui-même.
        camera.onRecordingInterrupted = { [weak camera, cleaning] url in
            Task {
                // Un nouvel enregistrement a pu commencer entre la coupure et ici : le nettoyage reste alors arrêté
                // (le travail est quand même créé, le prochain « Arrêter » le reprendra).
                if !(camera?.isRecording ?? false) { cleaning.setRecordingActive(false) }
                await cleaning.enqueue(original: url)
            }
        }
    }

    private func stopTapped() {
        guard !isStopping else { return }
        isStopping = true
        Task {
            let url = await camera.stopRecording()
            cleaning.setRecordingActive(false)
            isStopping = false
            if let url {
                await cleaning.enqueue(original: url)
            }
        }
    }

    /// Écran allumé pendant l'enregistrement et pendant un nettoyage : verrouillé, l'iPhone qui ne prête pas le GPU
    /// aux tâches de fond rendait les images recréées en noir (essai sur iPhone du 7 novembre à 15 h, verrouillage
    /// automatique 30 s après l'arrêt).
    private func keepsScreenAwake() {
        UIApplication.shared.isIdleTimerDisabled = camera.isRecording || cleaning.progress != nil
    }

    private func refreshFreeBytes() async {
        // Une lecture ratée garde la dernière valeur connue.
        if let bytes = await CameraController.availableRecordingBytes() {
            freeBytes = bytes
        }
    }
}

// MARK: - État du téléphone

/// Temps d'enregistrement restant et batterie ; rien tant que ni l'un ni l'autre n'est connu.
private struct StatusRow: View {
    let remaining: String?
    let battery: String?
    let lowBattery: Bool

    var body: some View {
        if remaining != nil || battery != nil {
            HStack(spacing: 14) {
                if let remaining {
                    Text(remaining)
                }
                if let battery {
                    Text(battery)
                        .foregroundStyle(lowBattery ? .orange : .white)
                }
            }
            .font(.footnote.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.5), in: Capsule())
        }
    }
}

/// L'iPhone chauffe : il peut couper la caméra.
private struct ThermalWarning: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "thermometer.high")
                .accessibilityHidden(true)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.black)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.orange, in: Capsule())
    }
}

#Preview {
    CameraScreen()
        .environment(CleaningCoordinator())
}
