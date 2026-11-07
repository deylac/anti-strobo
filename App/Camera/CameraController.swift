import AVFoundation
import Observation
import os
import StrobeCore
import UIKit

private let log = Logger(subsystem: "app.camantistrobo.ios", category: "Camera")

/// Pilote la caméra arrière : format 120 i/s, mesure de l'exposition de référence sans tenir compte des
/// flashs (à 60 puis 30 i/s si la scène est trop sombre et que le rythme du strobe le permet), verrouillage de
/// cette exposition et de la balance des blancs, puis enregistrement de l'original.
///
/// Répartition du travail :
/// - acteur principal (ici) : l'état publié pour l'écran, et l'orchestration ;
/// - file de session (`CaptureDeviceControl`, configuration par `SessionConfigurator`) : la session et
///   tout réglage de l'appareil ;
/// - file de capture (`FrameProcessor`) : chaque image (mesure, écriture) et chaque tampon audio, et la décision
///   de changer de cadence à la fin d'une mesure.
///
/// Changement de cadence : une mesure trop sombre qui finit en demandant une cadence plus basse passe par ici
/// (file de capture → acteur principal, `lowerCadence(to:generation:)`), qui lance la mesure suivante de la série
/// (nouveau numéro) ; la file de session change la cadence puis rend la nouvelle configuration
/// (`cadenceApplied`), avant de démarrer le mesureur.
///
/// Invariants :
/// - pendant l'enregistrement, aucun réglage d'exposition ni de balance des blancs n'atteint l'appareil : la
///   file de session les refuse du lancement de l'enregistrement jusqu'à la dernière image écrite ;
/// - on n'enregistre qu'avec une référence verrouillée et vérifiée : la fin de mesure (`ready` ou
///   `failed`) n'est publiée qu'après le verrouillage ; s'il est refusé, `referenceLockFailed` bloque
///   l'enregistrement jusqu'à une nouvelle mesure. Une interruption ou une erreur de session rend la
///   mesure caduque, et elle reprend avec la session ;
/// - la cadence ne change que pendant la mesure, jamais pendant l'enregistrement (même garde de la file de
///   session que l'exposition), et seulement vers le bas : au plus `maxCadenceSwitches` fois par série de
///   mesures. Une nouvelle série (`remeasure()`, reprise après une interruption ou une erreur) repart de la
///   cadence de départ ;
/// - quand la mesure est publiée terminée, `configuration` (cadence, débit) est celle de l'appareil : la file de
///   session rend la configuration avant de démarrer le mesureur, et ces deux résultats arrivent ici par la même
///   file série (`DispatchQueue.main`), dans cet ordre ;
/// - chaque fichier enregistré est rendu une seule fois : par `stopRecording()` ou par
///   `onRecordingInterrupted` ;
/// - le début et la fin d'un enregistrement atteignent la file de capture par le même chemin (file de session,
///   puis file de capture, deux files série) : la fin n'est jamais traitée avant son début, donc aucun
///   enregistreur ne peut continuer d'écrire après `isRecording` revenu à faux (voir
///   `CaptureDeviceControl.endRecording(of:)`).
@MainActor
@Observable
final class CameraController {
    /// État de la mesure de référence ; publié au plus ~10 fois par seconde, et à chaque changement d'état.
    /// Une référence que la caméra n'a pas gardée est publiée comme un échec (voir `referenceLockFailed`).
    private(set) var measurement: MeasurementState = CameraController.initialMeasurement
    /// Vrai quand la caméra a refusé de garder la référence (exposition manuelle ou balance des blancs),
    /// même après un nouvel essai. `measurement` est alors un échec, mais l'enregistrement reste bloqué
    /// (contrairement aux autres échecs) : il faut remesurer. L'écran doit dire pourquoi, le texte d'échec
    /// de `measurement` ne correspondant pas à ce cas.
    private(set) var referenceLockFailed = false
    private(set) var isRecording = false
    /// Moment où l'enregistrement en cours a été lancé.
    private(set) var recordingStartedAt: Date?
    /// Débit de l'original, en octets par seconde : nominal hors enregistrement ; pendant l'enregistrement,
    /// mesuré chaque seconde d'après la taille du fichier (nominal tant que le fichier a moins d'une seconde).
    private(set) var bytesPerSecond: Double = 0
    /// Cadence de capture de `bytesPerSecond` (celle de l'enregistrement en cours pendant un enregistrement) :
    /// le débit de la copie nettoyée en dépend. 0 tant que la caméra n'est pas configurée.
    private(set) var captureFPS: Double = 0
    /// Taille du fichier en cours d'enregistrement, en octets, relue chaque seconde ; 0 hors enregistrement.
    private(set) var recordedBytes: Int64 = 0
    /// Vrai seulement quand la session tourne (elle s'arrête par exemple sur une erreur). Reste faux sans
    /// caméra (simulateur) ou sans autorisation.
    private(set) var cameraAvailable = false
    /// Vrai si l'accès à la caméra est refusé (ou interdit par le contrôle parental).
    private(set) var cameraDenied = false
    /// Vrai quand la caméra ne peut pas (ou plus) tourner : configuration impossible, démarrage refusé, ou
    /// relances épuisées après une erreur. Il faut relancer l'app. Repasse à faux si la session redémarre.
    private(set) var sessionFailed = false
    /// Vrai pendant une interruption de la session (appel, autre app qui prend la caméra, passage en
    /// arrière-plan) : plus aucune image n'arrive.
    private(set) var isInterrupted = false
    /// Vrai dès que la session a tourné une fois.
    private var hasRun = false

    /// Caméra en pause : interrompue, ou arrêtée après avoir tourné (en attendant une relance), sans échec
    /// définitif. Aucune image, donc aucune mesure qui avance.
    var isPaused: Bool {
        !sessionFailed && (isInterrupted || (hasRun && !cameraAvailable))
    }

    let session = AVCaptureSession()

    /// Appelé quand un enregistrement est coupé sans que l'utilisateur l'ait arrêté (interruption, erreur de
    /// la session, chauffe, échec d'écriture), avec le fichier déjà terminé : il passe au nettoyage comme un
    /// enregistrement normal.
    @ObservationIgnored var onRecordingInterrupted: ((URL) -> Void)?

    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var control: CaptureDeviceControl?
    @ObservationIgnored private var processor: FrameProcessor?
    @ObservationIgnored private var configuration: CaptureConfiguration?
    @ObservationIgnored private var videoDevice: AVCaptureDevice?
    /// Numéro de la mesure en cours : un état publié par une mesure remplacée depuis est ignoré.
    @ObservationIgnored private var measurementGeneration = 0
    /// Changements de cadence faits dans la série de mesures en cours.
    @ObservationIgnored private var cadenceSwitches = 0
    /// Vrai entre la demande d'arrêt (ou la coupure) et la dernière image écrite.
    @ObservationIgnored private var isStopping = false
    /// Une reprise de session a demandé une nouvelle mesure pendant un arrêt : elle part à la fin de l'arrêt.
    @ObservationIgnored private var measureAfterStop = false
    /// Vrai après une relance pour une erreur autre qu'une réinitialisation des services média, jusqu'à ce
    /// que des images arrivent de nouveau : on ne relance qu'une fois.
    @ObservationIgnored private var hasRetriedAfterRuntimeError = false
    @ObservationIgnored private var currentRecordingURL: URL?
    @ObservationIgnored private var byteRateTask: Task<Void, Never>?
    @ObservationIgnored private weak var previewLayer: AVCaptureVideoPreviewLayer?
    @ObservationIgnored private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var previewRotationObservation: NSKeyValueObservation?
    @ObservationIgnored private var pressureObservation: NSKeyValueObservation?
    @ObservationIgnored private var notificationTokens: [any NSObjectProtocol] = []

    /// Changements de cadence permis par série de mesures : 120 → 60 → 30 i/s.
    private static let maxCadenceSwitches = 2

    nonisolated private static let initialMeasurement = MeasurementState.measuring(
        progress: 0,
        secondsRemaining: max(1, Int(ExposureMeterConfig().timeoutSeconds.rounded(.up)))
    )

    init() {}

    isolated deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        byteRateTask?.cancel()
        control?.stopRunning()
    }

    /// Dossier des enregistrements originaux : `Documents/Recordings`, créé au besoin et exclu de la
    /// sauvegarde iCloud.
    nonisolated static func recordingsDirectory() throws -> URL {
        var directory = URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Des dizaines de Go qui finissent dans Photos (qui a sa propre sauvegarde) : rien à sauvegarder ici.
        // Posé à chaque appel (sans effet s'il l'est déjà), pour couvrir aussi un dossier créé avant ce
        // réglage. Un échec n'empêche pas de filmer.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return directory
    }

    /// Espace libre du volume des enregistrements, y compris ce qu'iOS peut libérer pour un usage important, ou
    /// `nil` s'il est illisible. Lu hors de l'acteur principal : la mesure peut prendre du temps.
    nonisolated static func availableRecordingBytes() async -> Int64? {
        await Task.detached(priority: .utility) {
            let values = try? URL.documentsDirectory.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            )
            return values?.volumeAvailableCapacityForImportantUsage
        }.value
    }

    // MARK: - Démarrage

    /// Demande l'accès à la caméra puis au micro, configure la caméra grand-angle arrière et lance la mesure.
    ///
    /// Sans le micro, on filme sans son. Sans caméra ou sans autorisation, `cameraAvailable` reste faux (et
    /// `cameraDenied` dit pourquoi) ; si la caméra existe mais ne peut pas tourner, `sessionFailed` devient
    /// vrai. Seul le premier appel fait quelque chose.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        guard await Self.requestAccess(for: .video) else {
            cameraDenied = true
            log.notice("Accès à la caméra refusé")
            return
        }
        let microphoneAllowed = await Self.requestAccess(for: .audio)
        if !microphoneAllowed { log.notice("Micro refusé : vidéo sans son") }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            log.notice("Pas de caméra grand-angle arrière")
            return
        }

        let control = CaptureDeviceControl(session: session, device: device)
        let processor = FrameProcessor(
            control: control,
            onMeasurement: { [weak self] state, generation, lockFailed in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.receive(state, generation: generation, lockFailed: lockFailed) }
                }
            },
            onCadenceRequest: { [weak self] cadence, generation in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.lowerCadence(to: cadence, generation: generation) }
                }
            },
            onRecordingFailure: { [weak self] url in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.recordingFailed(url) }
                }
            }
        )

        let configuration: CaptureConfiguration
        do {
            configuration = try await control.configure(processor: processor, withAudio: microphoneAllowed)
        } catch {
            log.error("Configuration de la caméra impossible : \(String(describing: error), privacy: .public)")
            sessionFailed = true
            return
        }
        log.notice("Format \(configuration.width)×\(configuration.height) à \(configuration.fps) i/s, son : \(configuration.hasAudio)")

        self.control = control
        self.processor = processor
        self.configuration = configuration
        videoDevice = device
        bytesPerSecond = configuration.nominalBytesPerSecond
        captureFPS = configuration.fps
        observeSession(device: device)
        updateRotationCoordinator()

        if apply(await control.run()) {
            beginMeasurement()
        }
    }

    private static func requestAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: mediaType)
        default: false
        }
    }

    /// Prend en compte l'état de la session après `run()` ; rend vrai si elle tourne.
    private func apply(_ state: SessionRunState) -> Bool {
        if let updated = state.configuration {
            configuration = updated
            if !isRecording { publishRate(of: updated) }
        }
        if !state.isRunning {
            log.error("La session ne tourne pas")
            sessionFailed = true
        }
        return state.isRunning
    }

    // MARK: - Mesure

    /// Vrai quand `remeasure()` relancerait la mesure : la session tourne, sans interruption ni enregistrement.
    var canRemeasure: Bool { cameraAvailable && !isInterrupted && !isRecording }

    /// Recommence la mesure de référence depuis l'exposition actuelle, à la cadence de départ. Sans effet pendant
    /// l'enregistrement ou une interruption.
    func remeasure() {
        guard canRemeasure else { return }
        beginMeasurement()
    }

    /// Nouvelle série de mesures, à la cadence de départ.
    private func beginMeasurement() {
        cadenceSwitches = 0
        startMeasurement(cadence: nil)
    }

    /// Lance une mesure de la série en cours, à `cadence` (plus basse) ou, si `nil`, à la cadence de départ.
    private func startMeasurement(cadence: Double?) {
        guard let control else { return }
        measurementGeneration += 1
        measurement = Self.initialMeasurement
        referenceLockFailed = false
        control.beginMeasurement(
            generation: measurementGeneration,
            cadence: cadence,
            mayLowerCadence: cadenceSwitches < Self.maxCadenceSwitches
        ) { [weak self] configuration in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.cadenceApplied(configuration) }
            }
        }
    }

    /// La mesure `generation` a fini trop sombre : elle est refaite à `cadence`, sans rien verrouiller ni publier
    /// de sa fin (l'écran reste sur « Mesure de la lumière… », compte à rebours relancé).
    ///
    /// Le mesureur n'en fait la demande que si la série a encore droit à un changement (`mayLowerCadence`) :
    /// ignorer une demande à jour laisserait la mesure sans fin. Seule une demande d'une mesure remplacée depuis
    /// est ignorée (la mesure qui l'a remplacée est déjà lancée).
    private func lowerCadence(to cadence: Double, generation: Int) {
        guard generation == measurementGeneration, !isRecording else { return }
        cadenceSwitches += 1
        startMeasurement(cadence: cadence)
    }

    /// La file de session a mis en place la cadence d'une nouvelle mesure : c'est désormais celle des
    /// enregistrements, et celle du débit nominal affiché.
    private func cadenceApplied(_ updated: CaptureConfiguration) {
        configuration = updated
        if !isRecording { publishRate(of: updated) }
    }

    /// Débit nominal et cadence de `configuration`, pour le temps d'enregistrement restant.
    private func publishRate(of configuration: CaptureConfiguration) {
        bytesPerSecond = configuration.nominalBytesPerSecond
        captureFPS = configuration.fps
    }

    /// La référence en cours n'est plus garantie (session interrompue ou en erreur) : l'état repasse en
    /// mesure, ce qui empêche aussi de lancer un enregistrement d'ici la nouvelle mesure.
    private func invalidateMeasurement() {
        measurementGeneration += 1
        measurement = Self.initialMeasurement
        referenceLockFailed = false
    }

    private func receive(_ state: MeasurementState, generation: Int, lockFailed: Bool) {
        // Un état d'une mesure remplacée entre-temps peut arriver après coup.
        guard generation == measurementGeneration else { return }
        // Des images arrivent : la caméra marche, une future erreur aura de nouveau droit à une relance.
        hasRetriedAfterRuntimeError = false
        referenceLockFailed = lockFailed
        measurement = lockFailed ? Self.unlockedReference(state) : state
    }

    /// Une référence que la caméra n'a pas gardée est un échec de mesure, à refaire. Faute d'un cas dédié
    /// dans `MeasurementFailure`, une référence « prête » devient `notEnoughGoodFrames` ; c'est
    /// `referenceLockFailed` qui dit la vraie raison.
    private static func unlockedReference(_ state: MeasurementState) -> MeasurementState {
        if case let .ready(reference) = state { return .failed(.notEnoughGoodFrames, best: reference) }
        return state
    }

    // MARK: - Enregistrement

    /// Lance l'enregistrement avec l'exposition de référence verrouillée.
    ///
    /// Sans effet tant que la mesure n'est pas terminée (`ready`, ou `failed` que l'écran a fait confirmer),
    /// si la référence n'a pas pu être verrouillée, pendant un enregistrement, ou si la session ne tourne
    /// pas. L'orientation du film est celle de l'iPhone à cet instant.
    func startRecording() {
        guard cameraAvailable, !isRecording, measurement.isFinal, !referenceLockFailed,
              let control, let processor, let configuration
        else { return }

        let url: URL
        do {
            url = try Self.recordingsDirectory().appending(path: "\(UUID().uuidString).mov")
        } catch {
            log.error("Dossier des enregistrements inaccessible : \(String(describing: error), privacy: .public)")
            return
        }
        let request = RecordingRequest(
            url: url,
            configuration: configuration,
            rotationAngle: rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 0
        )

        let startedAt = Date()
        isRecording = true
        recordingStartedAt = startedAt
        currentRecordingURL = url
        publishRate(of: configuration)
        recordedBytes = 0
        // L'exposition est figée sur la file de session avant que l'enregistreur ne reçoive une seule image.
        control.setRecording(true) { processor.beginRecording(request) }
        startByteRateMonitor(url: url, startedAt: startedAt)
    }

    /// Arrête l'enregistrement et rend le fichier terminé, ou `nil` s'il n'y avait rien à arrêter (déjà
    /// coupé : le fichier passe alors par `onRecordingInterrupted`) ou rien d'enregistré.
    func stopRecording() async -> URL? {
        guard isRecording, !isStopping else { return nil }
        isStopping = true
        let activity = BackgroundActivity(name: "Fin de l'enregistrement")
        defer { activity.end() }
        return await finishRecording()
    }

    /// Coupure non demandée : termine l'enregistrement en cours, s'il y en a un, et remet le fichier à
    /// `onRecordingInterrupted`, en demandant à iOS le temps de finir si l'app passe en arrière-plan.
    private func cutRecording(_ reason: String) async {
        guard isRecording, !isStopping else { return }
        isStopping = true
        log.notice("Enregistrement coupé : \(reason, privacy: .public)")
        let activity = BackgroundActivity(name: "Fin de l'enregistrement coupé")
        defer { activity.end() }
        guard let url = await finishRecording() else { return }
        onRecordingInterrupted?(url)
    }

    private func recordingFailed(_ url: URL) {
        // Un échec d'un enregistrement déjà arrêté ne concerne plus personne.
        guard url == currentRecordingURL else { return }
        Task { await cutRecording("échec d'écriture") }
    }

    /// Détache l'enregistreur de la file de capture, rouvre les réglages, puis termine le fichier.
    /// L'appelant a mis `isStopping` à vrai.
    private func finishRecording() async -> URL? {
        byteRateTask?.cancel()
        byteRateTask = nil

        // Par la file de session, comme le début : la fin ne peut pas être traitée avant lui.
        var recorder: MovieRecorder?
        if let control, let processor {
            recorder = await control.endRecording(of: processor)
        }
        // Plus aucune image n'est écrite : les réglages de l'appareil redeviennent permis (nouvelle mesure).
        control?.setRecording(false)
        isRecording = false
        isStopping = false
        recordingStartedAt = nil
        currentRecordingURL = nil
        bytesPerSecond = configuration?.nominalBytesPerSecond ?? 0
        captureFPS = configuration?.fps ?? 0
        // Le fichier part au nettoyage : sa copie à venir est comptée par `CleaningCoordinator`.
        recordedBytes = 0
        if measureAfterStop {
            measureAfterStop = false
            beginMeasurement()
        }

        guard let recorder else { return nil }
        do {
            return try await recorder.finish()
        } catch {
            log.error("Fin d'enregistrement en erreur : \(String(describing: error), privacy: .public)")
            // Fichier partiel : ses fragments complets restent lisibles, le nettoyage dira s'il est exploitable.
            return FileManager.default.fileExists(atPath: recorder.url.path) ? recorder.url : nil
        }
    }

    private func startByteRateMonitor(url: URL, startedAt: Date) {
        byteRateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.updateByteRate(url: url, startedAt: startedAt)
            }
        }
    }

    /// Taille du fichier et débit moyen depuis le début de l'enregistrement : taille du fichier / âge du fichier.
    private func updateByteRate(url: URL, startedAt: Date) {
        let nominal = configuration?.nominalBytesPerSecond ?? 0
        let age = Date().timeIntervalSince(startedAt)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        recordedBytes = size
        bytesPerSecond = age >= 1 && size > 0 ? Double(size) / age : nominal
    }

    // MARK: - Interruptions et erreurs de session

    private func observeSession(device: AVCaptureDevice) {
        let center = NotificationCenter.default
        // `cameraAvailable` suit la marche réelle de la session.
        let started = center.addObserver(
            forName: AVCaptureSession.didStartRunningNotification, object: session, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cameraAvailable = true
                self?.hasRun = true
                self?.isInterrupted = false
                self?.sessionFailed = false
            }
        }
        let stopped = center.addObserver(
            forName: AVCaptureSession.didStopRunningNotification, object: session, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameraAvailable = false }
        }
        let interrupted = center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main
        ) { [weak self] notification in
            let reason = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
            MainActor.assumeIsolated {
                self?.sessionWasInterrupted("session interrompue (raison \(reason.map(String.init) ?? "inconnue"))")
            }
        }
        let interruptionEnded = center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionInterruptionEnded() }
        }
        let runtimeError = center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
            let description = error?.localizedDescription ?? "inconnue"
            let mediaServicesWereReset = error?.code == .mediaServicesWereReset
            MainActor.assumeIsolated {
                self?.sessionRuntimeError(description, mediaServicesWereReset: mediaServicesWereReset)
            }
        }
        notificationTokens = [started, stopped, interrupted, interruptionEnded, runtimeError]

        // À ce niveau, le système va couper la caméra (puis interrompre la session) : on termine le fichier
        // sans attendre.
        pressureObservation = device.observe(\.systemPressureState, options: [.new]) { @Sendable [weak self] _, change in
            guard change.newValue?.level == .shutdown else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.cutRecording("pression système (chauffe)") }
                }
            }
        }
    }

    private func sessionWasInterrupted(_ reason: String) {
        isInterrupted = true
        invalidateMeasurement()
        Task { await cutRecording(reason) }
    }

    /// Fin d'interruption : la session reprend (relancée si besoin), puis une nouvelle mesure.
    private func sessionInterruptionEnded() {
        log.notice("Fin d'interruption : reprise et nouvelle mesure")
        isInterrupted = false
        Task { await resumeAndRemeasure() }
    }

    /// Erreur de session : l'enregistrement en cours est terminé, puis la session est relancée — toujours
    /// après une réinitialisation des services média, une seule fois pour toute autre erreur (tant que des
    /// images ne sont pas revenues) — et la mesure reprend. Relances épuisées : `sessionFailed`.
    private func sessionRuntimeError(_ description: String, mediaServicesWereReset: Bool) {
        log.error("Erreur de session : \(description, privacy: .public)")
        invalidateMeasurement()
        Task {
            await cutRecording("erreur de session (\(description))")
            guard mediaServicesWereReset || !hasRetriedAfterRuntimeError else {
                log.error("Pas de nouvelle relance automatique de la session")
                sessionFailed = true
                return
            }
            if !mediaServicesWereReset { hasRetriedAfterRuntimeError = true }
            await resumeAndRemeasure()
        }
    }

    private func resumeAndRemeasure() async {
        guard let control else { return }
        guard apply(await control.run()) else { return }
        if isRecording {
            // Un arrêt est en cours : la mesure repartira à sa fin.
            measureAfterStop = true
        } else {
            beginMeasurement()
        }
    }

    // MARK: - Orientation

    /// À appeler par la vue d'aperçu : l'aperçu suit alors l'orientation de l'interface.
    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        updateRotationCoordinator()
    }

    /// Le coordinateur donne l'angle de l'aperçu (suivi en continu) et celui de l'enregistrement (lu au
    /// lancement). Il dépend de l'appareil et de la couche d'aperçu : il est recréé quand l'un arrive.
    private func updateRotationCoordinator() {
        guard let videoDevice else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: videoDevice, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
        previewRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview, options: [.new]
        ) { @Sendable [weak self] _, change in
            guard let angle = change.newValue else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applyPreviewRotation(angle) }
            }
        }
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        guard let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }
}

private extension MeasurementState {
    var isFinal: Bool {
        if case .measuring = self { false } else { true }
    }
}

/// Demande à iOS de laisser l'app finir un fichier en arrière-plan (sinon elle peut être suspendue au
/// milieu de `finishWriting`). `end()` doit être appelé quand c'est fini ; l'expiration y mène aussi.
@MainActor
private final class BackgroundActivity {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
