import AVFoundation
import os
import StrobeCore

private let log = Logger(subsystem: "app.camantistrobo.ios", category: "Camera")

/// La session après `CaptureDeviceControl.run()`.
struct SessionRunState: Sendable {
    let isRunning: Bool
    /// La configuration en vigueur : le format a pu être choisi de nouveau si l'appareil ne proposait plus
    /// le premier (après une réinitialisation des services média). `nil` avant `configure`.
    let configuration: CaptureConfiguration?
}

/// Seul maître de la session et des réglages de l'appareil, sur une file série dédiée (jamais le fil
/// principal) : configuration, marche et redémarrage de la session, cadence de prise de vue, exposition
/// manuelle et balance des blancs pendant la mesure, verrouillage vérifié de la référence, et blocage de tout
/// réglage pendant l'enregistrement.
///
/// Confinement : tout l'état mutable n'est lu et écrit que sur `queue`, et la session comme l'appareil ne
/// sont configurés que sur `queue` ; d'où `@unchecked Sendable`.
final class CaptureDeviceControl: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.camantistrobo.camera.session", qos: .userInitiated)
    private let session: AVCaptureSession
    private let device: AVCaptureDevice

    /// Reçoit les images, et apprend à partir de quelle image chaque exposition demandée est appliquée.
    private weak var processor: FrameProcessor?
    /// Format et cadence de départ (`SessionConfigurator.chooseFormat`), rétablis à chaque nouvelle série de
    /// mesures.
    private var baseChoice: SessionConfigurator.FormatChoice?
    /// Format et cadence en vigueur : ceux de départ, ou une cadence plus basse demandée par la mesure.
    /// Réappliqués (ou choisis de nouveau) si un redémarrage les a perdus.
    private var activeChoice: SessionConfigurator.FormatChoice?
    /// La configuration de `activeChoice`.
    private var configuration: CaptureConfiguration?
    /// Horloge de l'appareil, celle des `syncTime` rendus par `setExposureModeCustom`.
    private var deviceClock: CMClock?
    /// Vrai pendant l'enregistrement : aucun réglage d'exposition ni de balance des blancs ne passe.
    private var isRecording = false
    /// Mesure en cours : les demandes d'une mesure remplacée depuis sont ignorées.
    private var generation = 0

    init(session: AVCaptureSession, device: AVCaptureDevice) {
        self.session = session
        self.device = device
    }

    /// Configure la session (voir `SessionConfigurator`) ; `processor` reçoit ensuite images et son.
    func configure(processor: FrameProcessor, withAudio: Bool) async throws -> CaptureConfiguration {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let setup = try SessionConfigurator.configure(
                        session, device: device, delegate: processor, withAudio: withAudio
                    )
                    self.processor = processor
                    baseChoice = setup.choice
                    activeChoice = setup.choice
                    configuration = setup.configuration
                    deviceClock = setup.deviceClock
                    continuation.resume(returning: setup.configuration)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Lance la session si elle ne tourne pas, après avoir rétabli format et cadence s'ils ont été perdus
    /// (réinitialisation des services média) ; sans format utilisable, elle reste arrêtée.
    func run() async -> SessionRunState {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if !session.isRunning, restoreFormat() {
                    session.startRunning()
                }
                continuation.resume(returning: SessionRunState(isRunning: session.isRunning, configuration: configuration))
            }
        }
    }

    func stopRunning() {
        queue.async { [self] in session.stopRunning() }
    }

    /// Nouvelle mesure, à la cadence `cadence` (plus basse, demandée par la mesure précédente de la série) ou, si
    /// `nil`, à la cadence de départ (nouvelle série : premier lancement, nouvelle mesure demandée, reprise de la
    /// session). Une fois la cadence en place, la configuration en vigueur est rendue à `report`, sur la file de
    /// session, puis la mesure part de l'exposition actuelle de l'appareil, passée aussitôt en exposition
    /// manuelle ; la balance des blancs suit la scène jusqu'au verrouillage.
    ///
    /// `report` est appelé avant que le mesureur ne reçoive une image, donc avant tout `lockReference` de cette
    /// mesure : relayé par la même file que le résultat du verrouillage, il arrive avant lui.
    ///
    /// - Parameter mayLowerCadence: vrai si cette mesure peut encore demander une cadence plus basse. Faux
    ///   aussi quand la cadence demandée n'a pas pu être appliquée : la mesure se termine alors à la cadence
    ///   actuelle, sans nouvel essai.
    func beginMeasurement(
        generation: Int,
        cadence: Double?,
        mayLowerCadence: Bool,
        then report: @escaping @Sendable (CaptureConfiguration) -> Void
    ) {
        queue.async { [self] in
            // CameraController ne relance jamais de mesure pendant l'enregistrement : garde de principe. Elle
            // couvre aussi le changement de cadence, qui ne passe que par ici.
            guard !isRecording else { return }
            self.generation = generation
            let cadenceApplied = switchCadence(to: cadence)
            guard let configuration else { return }
            report(configuration)

            let measurementCadence = MeasurementCadence(
                current: configuration.fps,
                available: configuration.availableCadences,
                mayLower: mayLowerCadence && (cadenceApplied || cadence == nil)
            )
            let limits = configuration.limits
            let deviceExposure = currentExposure(within: limits)
            let meter = ExposureMeter(limits: limits, initial: deviceExposure)
            // Le mesureur est en place sur la file de capture avant la demande : l'image à partir de
            // laquelle elle s'applique lui parvient forcément après.
            processor?.startMeasuring(
                meter, generation: generation, deviceExposure: deviceExposure, cadence: measurementCadence
            )
            let applied = withDeviceLock {
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                setCustomExposure(meter.target)
            }
            // Sans réglage, aucune image ne correspondra à la cible : la mesure finira en échec.
            if !applied { log.error("Exposition de départ refusée par l'appareil") }
        }
    }

    /// Applique une nouvelle cible de mesure.
    func applyMeasuringExposure(_ exposure: Exposure, generation: Int) {
        queue.async { [self] in
            guard !isRecording, generation == self.generation else { return }
            if !withDeviceLock({ setCustomExposure(exposure) }) {
                log.error("Cible de mesure refusée par l'appareil")
            }
        }
    }

    /// Verrouille l'exposition de référence et la balance des blancs jusqu'à la prochaine mesure, vérifie
    /// que l'appareil les a gardées (un nouvel essai sinon), puis rend le résultat à `report`, sur la file
    /// de session. Rien n'est fait ni rendu pour une mesure remplacée entre-temps.
    func lockReference(_ exposure: Exposure, generation: Int, then report: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard !isRecording, generation == self.generation else { return }
            var locked = applyReferenceLock(exposure)
            if !locked {
                log.error("Verrouillage de la référence refusé : nouvel essai")
                locked = applyReferenceLock(exposure)
            }
            if locked {
                log.notice("Exposition de référence verrouillée : \(exposure.durationSeconds) s × \(exposure.iso)")
            } else {
                log.error("Verrouillage de la référence impossible")
            }
            report(locked)
        }
    }

    /// Bloque (ou rouvre) les réglages de l'appareil, puis exécute `next` sur la file de session.
    func setRecording(_ recording: Bool, then next: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            isRecording = recording
            next?()
        }
    }

    /// Détache l'enregistreur de `processor` en passant par la file de session, le même chemin que le
    /// `beginRecording` lancé par `setRecording(true)`.
    ///
    /// Invariant : la file de capture reçoit le début et la fin d'un enregistrement dans l'ordre où ils ont été
    /// demandés. Les deux passent par cette file série, qui transmet chacun à la file de capture (série elle
    /// aussi) : même quand la file de session est occupée (redémarrage, verrouillage), une fin ne peut pas être
    /// traitée avant son début. Sans cela, la fin trouverait un enregistreur pas encore créé, et le début arrivé
    /// ensuite en créerait un qui écrirait sans fin, sans que personne ne l'arrête.
    func endRecording(of processor: FrameProcessor) async -> MovieRecorder? {
        await withCheckedContinuation { continuation in
            queue.async {
                processor.detachRecorder { continuation.resume(returning: $0) }
            }
        }
    }

    // MARK: - Réglages de l'appareil

    /// Vrai si la demande a pu être faite et si, ensuite, l'exposition est bien manuelle et la balance des
    /// blancs bien verrouillée.
    private func applyReferenceLock(_ exposure: Exposure) -> Bool {
        let whiteBalanceLockable = device.isWhiteBalanceModeSupported(.locked)
        let requested = withDeviceLock {
            setCustomExposure(exposure)
            if whiteBalanceLockable {
                device.whiteBalanceMode = .locked
            }
        }
        return requested
            && device.exposureMode == .custom
            && (!whiteBalanceLockable || device.whiteBalanceMode == .locked)
    }

    /// Rétablit le format et la cadence en vigueur (sans changer de cadence : un enregistrement peut être en
    /// train de se terminer) ; si le format n'est plus proposé par l'appareil, en choisit un de nouveau avec les
    /// règles de départ, et la cadence de départ. Faux s'il n'y a pas de format utilisable ou si l'appareil
    /// refuse le réglage.
    private func restoreFormat() -> Bool {
        guard var choice = activeChoice, let configuration else { return false }
        if !device.formats.contains(choice.format) {
            do {
                choice = try SessionConfigurator.chooseFormat(of: device)
            } catch {
                log.error("Plus aucun format utilisable : \(String(describing: error), privacy: .public)")
                return false
            }
            baseChoice = choice
            activeChoice = choice
            self.configuration = SessionConfigurator.configuration(
                for: choice, hasAudio: configuration.hasAudio, of: device
            )
            log.notice("Format choisi de nouveau après la perte du précédent")
        }
        guard !SessionConfigurator.isApplied(choice, on: device) else { return true }
        log.notice("Format ou cadence perdus : réappliqués avant le redémarrage")
        return withDeviceLock { SessionConfigurator.applyFormat(choice, to: device) }
    }

    /// Passe à la cadence `fps`, ou à la cadence de départ si `nil`, à la même résolution (voir
    /// `SessionConfigurator.choice(at:from:of:)`), et met la configuration à jour. Vrai si l'appareil filme
    /// désormais à cette cadence (ou le faisait déjà) ; faux si c'est impossible, format et cadence restant alors
    /// ceux d'avant. Jamais pendant l'enregistrement : l'appelant le vérifie.
    private func switchCadence(to fps: Double?) -> Bool {
        guard let active = activeChoice, let base = baseChoice, let configuration else { return false }
        let wanted = fps ?? base.fps
        let target: SessionConfigurator.FormatChoice
        do {
            // De retour à la cadence de départ, son format tel que `chooseFormat` l'a pris, s'il est toujours
            // proposé ; sinon le plus sensible de même résolution (à égalité, le format en vigueur).
            target = fps == nil && device.formats.contains(base.format)
                ? base
                : try SessionConfigurator.choice(at: wanted, from: fps == nil ? base : active, of: device)
        } catch {
            log.error("Pas de format pour filmer à \(Int(wanted)) i/s : la cadence reste \(Int(active.fps)) i/s")
            return false
        }
        if !SessionConfigurator.isApplied(target, on: device) {
            guard withDeviceLock({ SessionConfigurator.applyCadence(target, to: device) }) else {
                log.error("Cadence \(Int(wanted)) i/s refusée par l'appareil : elle reste \(Int(active.fps)) i/s")
                return false
            }
        }
        if fps == nil { baseChoice = target }
        activeChoice = target
        guard target.fps != active.fps || target.format != active.format else { return true }
        self.configuration = SessionConfigurator.configuration(for: target, hasAudio: configuration.hasAudio, of: device)
        let sameFormat = target.format == active.format
        log.notice("Prise de vue à \(Int(target.fps)) i/s (au lieu de \(Int(active.fps)) i/s), \(sameFormat ? "même format" : "autre format", privacy: .public), ISO max \(Int(target.format.maxISO))")
        return true
    }

    /// L'exposition actuelle de l'appareil, sa durée ramenée à `limits.maxDuration` au plus, ISO inchangé
    /// (`Exposure.clampingDuration`) : après un passage à une cadence plus haute, la durée lue peut encore être
    /// celle de l'ancienne cadence, plus longue qu'une image. Si elle n'est pas encore connue, une exposition
    /// moyenne (durée maximale, ISO au milieu de la plage en échelle logarithmique).
    private func currentExposure(within limits: ExposureLimits) -> Exposure {
        let current = Exposure(durationSeconds: device.exposureDuration.seconds, iso: Double(device.iso))
        guard current.product.isFinite, current.product > 0 else {
            return Exposure(durationSeconds: limits.maxDuration, iso: (limits.minISO * limits.maxISO).squareRoot())
        }
        return current.clampingDuration(to: limits)
    }

    /// Exécute `body` avec l'appareil verrouillé ; faux (et rien fait) si le verrou est refusé.
    @discardableResult
    private func withDeviceLock(_ body: () -> Void) -> Bool {
        do {
            try device.lockForConfiguration()
        } catch {
            log.error("Appareil impossible à verrouiller : \(String(describing: error), privacy: .public)")
            return false
        }
        defer { device.unlockForConfiguration() }
        body()
        return true
    }

    /// Exposition manuelle, bornée au format actif (hors bornes, AVFoundation lèverait une exception).
    /// Quand l'appareil l'applique, la file de capture reçoit l'exposition demandée, telle quelle, avec
    /// l'horodatage de la première image prise avec elle, converti de l'horloge de l'appareil à celle des
    /// images (`synchronizationClock`, lue à chaque demande : elle peut changer). L'appareil doit être
    /// verrouillé.
    private func setCustomExposure(_ exposure: Exposure) {
        guard device.isExposureModeSupported(.custom) else { return }
        let format = device.activeFormat
        let wanted = CMTime(seconds: exposure.durationSeconds, preferredTimescale: 1_000_000_000)
        let duration = min(max(wanted, format.minExposureDuration), format.maxExposureDuration)
        let iso = min(max(Float(exposure.iso), format.minISO), format.maxISO)
        let processor = processor
        let deviceClock = deviceClock
        let frameClock = session.synchronizationClock
        device.setExposureModeCustom(duration: duration, iso: iso) { syncTime in
            let frameTime = if let deviceClock, let frameClock {
                CMSyncConvertTime(syncTime, from: deviceClock, to: frameClock)
            } else {
                syncTime
            }
            processor?.exposureApplied(exposure, syncTime: frameTime)
        }
    }
}
