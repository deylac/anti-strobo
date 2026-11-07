import AVFoundation
import ImageIO
import os
import StrobeCore

private let log = Logger(subsystem: "app.camantistrobo.ios", category: "Camera")

/// La cadence d'une mesure, et ce qu'il faut à `CadencePlanner` pour décider d'en changer à sa fin.
struct MeasurementCadence: Sendable {
    /// La cadence à laquelle la mesure est faite.
    let current: Double
    /// Les cadences offertes à cette résolution (`CaptureConfiguration.availableCadences`).
    let available: [Double]
    /// Faux quand la mesure doit se terminer à `current` : changements de cadence épuisés pour cette série de
    /// mesures, ou changement précédent refusé par l'appareil.
    let mayLower: Bool
}

/// Reçoit chaque image et chaque tampon audio sur la file de capture : mesure de l'exposition avant
/// l'enregistrement (et, à sa fin, choix d'une cadence plus basse si la scène est trop sombre), écriture pendant.
///
/// Confinement : tout l'état mutable (mesureur et sa cadence, expositions appliquées, enregistreur, limitation
/// des publications) n'est lu et écrit que sur `queue`, où AVFoundation appelle aussi les délégués ; d'où
/// `@unchecked Sendable`. Les résultats repartent par les fermetures `on…` (que `CameraController` relaie au fil
/// principal) ou par `control` (file de session).
final class FrameProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.camantistrobo.camera.data", qos: .userInitiated)

    private let control: CaptureDeviceControl
    /// État de la mesure, numéro de la mesure, et vrai si la caméra a refusé de verrouiller la référence.
    private let onMeasurement: @Sendable (MeasurementState, Int, Bool) -> Void
    /// La mesure (son numéro) finit sans verrouiller : elle demande à être refaite à cette cadence plus basse.
    private let onCadenceRequest: @Sendable (Double, Int) -> Void
    private let onRecordingFailure: @Sendable (URL) -> Void

    private var meter: ExposureMeter?
    private var generation = 0
    private var cadence: MeasurementCadence?
    /// Dernière cible envoyée à l'appareil.
    private var requestedTarget: Exposure?
    /// Exposition de chaque image, d'après les demandes appliquées ; remis à zéro à chaque mesure.
    private var appliedExposures: AppliedExposureTracker?
    private var lastPublishedState: MeasurementState?
    private var lastPublishTime = -Double.infinity
    private var lastDiagnosticTime = -Double.infinity

    private var pendingRecording: RecordingRequest?
    private var recorder: MovieRecorder?
    private var failureReported = false

    /// Écart minimal, en secondes de vidéo, entre deux publications d'un même compte à rebours.
    private static let publishInterval = 0.1

    init(
        control: CaptureDeviceControl,
        onMeasurement: @escaping @Sendable (MeasurementState, Int, Bool) -> Void,
        onCadenceRequest: @escaping @Sendable (Double, Int) -> Void,
        onRecordingFailure: @escaping @Sendable (URL) -> Void
    ) {
        self.control = control
        self.onMeasurement = onMeasurement
        self.onCadenceRequest = onCadenceRequest
        self.onRecordingFailure = onRecordingFailure
    }

    /// Remplace le mesureur ; sa cible va être demandée à l'appareil, qui avait jusque-là `deviceExposure`.
    /// La mesure est faite à la cadence `cadence.current`.
    func startMeasuring(_ meter: ExposureMeter, generation: Int, deviceExposure: Exposure, cadence: MeasurementCadence) {
        queue.async { [self] in
            self.meter = meter
            self.generation = generation
            self.cadence = cadence
            requestedTarget = meter.target
            appliedExposures = AppliedExposureTracker(deviceExposure: deviceExposure)
            lastPublishedState = nil
            lastPublishTime = -.infinity
            lastDiagnosticTime = -.infinity
        }
    }

    /// L'appareil applique `exposure` (telle que demandée) à partir de l'image d'horodatage `syncTime`
    /// (déjà ramené à l'horloge des images). Toutes les demandes comptent, même celles d'une mesure
    /// remplacée : elles ont bien réglé l'appareil.
    func exposureApplied(_ exposure: Exposure, syncTime: CMTime) {
        queue.async { [self] in
            if !syncTime.isNumeric { log.error("Exposition appliquée sans horodatage : ignorée") }
            appliedExposures?.requestApplied(exposure, syncTime: syncTime)
        }
    }

    /// L'enregistreur sera créé à la prochaine image, avec son format.
    ///
    /// À appeler depuis la file de session uniquement, comme `detachRecorder` (voir
    /// `CaptureDeviceControl.endRecording(of:)`) : début et fin arrivent alors ici dans l'ordre demandé.
    func beginRecording(_ request: RecordingRequest) {
        queue.async { [self] in
            pendingRecording = request
            failureReported = false
        }
    }

    /// Détache l'enregistreur (et oublie un enregistrement demandé qui n'a pas encore reçu d'image), puis le
    /// rend à `report`, sur la file de capture : ensuite, plus aucune image ni aucun son ne lui est donné.
    ///
    /// À appeler depuis la file de session uniquement, comme `beginRecording`.
    func detachRecorder(then report: @escaping @Sendable (MovieRecorder?) -> Void) {
        queue.async { [self] in
            let detached = recorder
            recorder = nil
            pendingRecording = nil
            report(detached)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        if output is AVCaptureAudioDataOutput {
            recorder?.append(audio: sampleBuffer)
        } else {
            handleVideo(sampleBuffer)
        }
    }

    // MARK: - Enregistrement

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        if let request = pendingRecording {
            pendingRecording = nil
            recorder = makeRecorder(request, firstFrame: sampleBuffer)
        }
        if let recorder {
            recorder.append(video: sampleBuffer)
            if !failureReported, recorder.hasFailed {
                failureReported = true
                onRecordingFailure(recorder.url)
            }
            return
        }
        measure(sampleBuffer)
    }

    private func makeRecorder(_ request: RecordingRequest, firstFrame: CMSampleBuffer) -> MovieRecorder? {
        guard let format = CMSampleBufferGetFormatDescription(firstFrame) else {
            log.error("Image sans description de format : enregistrement impossible")
            failureReported = true
            onRecordingFailure(request.url)
            return nil
        }
        do {
            return try MovieRecorder(
                url: request.url,
                videoSettings: request.videoSettings,
                audioSettings: request.audioSettings,
                sourceFormat: format,
                transform: request.transform
            )
        } catch {
            log.error("Enregistreur impossible à créer : \(String(describing: error), privacy: .public)")
            try? FileManager.default.removeItem(at: request.url)
            failureReported = true
            onRecordingFailure(request.url)
            return nil
        }
    }

    // MARK: - Mesure

    private func measure(_ sampleBuffer: CMSampleBuffer) {
        guard case .measuring? = meter?.state,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let time = presentationTime.seconds
        guard presentationTime.isNumeric, time.isFinite,
              let applied = appliedExposures?.exposure(at: presentationTime)
        else { return }

        let stats = LumaSampler.stats(of: pixelBuffer)
        logDiagnostic(sampleBuffer, applied: applied, stats: stats, at: time)
        guard let state = meter?.ingest(stats, at: time, appliedExposure: applied),
              let target = meter?.target
        else { return }

        switch state {
        case .measuring:
            if target != requestedTarget {
                requestedTarget = target
                control.applyMeasuringExposure(target, generation: generation)
            }
            publishIfDue(state, at: time)
        case let .ready(reference), let .failed(_, best: reference):
            lastPublishedState = state
            let generation = generation
            // Trop sombre à cette cadence, et une plus basse est permise : rien n'est verrouillé ni publié (l'écran
            // reste sur « Mesure de la lumière… »), la mesure est refaite à cette cadence. Le mesureur, terminé,
            // ignore les images d'ici le suivant.
            if let lower = lowerCadence() {
                onCadenceRequest(lower, generation)
                return
            }
            // L'écran n'apprend la fin de la mesure (et ne peut lancer l'enregistrement) qu'une fois le
            // verrouillage fait et vérifié par la file de session, qui publie elle-même le résultat.
            let onMeasurement = onMeasurement
            control.lockReference(reference, generation: generation) { locked in
                onMeasurement(state, generation, !locked)
            }
        }
    }

    /// À la fin d'une mesure : la cadence plus basse à laquelle la refaire (`CadencePlanner`), ou `nil` pour
    /// verrouiller à la cadence actuelle. Chaque décision est journalisée avec le rythme vu.
    private func lowerCadence() -> Double? {
        guard let meter, let cadence else { return nil }
        let rhythm = meter.rhythm
        let reachedMaximum = meter.reachedMaximum
        let lower = cadence.mayLower
            ? CadencePlanner.nextCadence(
                current: cadence.current,
                available: cadence.available,
                reachedMaximum: reachedMaximum,
                rhythm: rhythm
            )
            : nil
        log.notice("""
            Cadence : \(Int(lower ?? cadence.current)) i/s (rythme : strobe=\(rhythm.hasStrobe), \
            trou=\(rhythm.shortestDarkGap, format: .fixed(precision: 3)) s, au max=\(reachedMaximum))
            """)
        return lower
    }

    /// Publie l'état à chaque changement du compte à rebours ou de nature (fin de mesure), et sinon au plus
    /// toutes les `publishInterval` secondes.
    private func publishIfDue(_ state: MeasurementState, at time: Double) {
        guard state != lastPublishedState else { return }
        let countdownChanged: Bool
        if case let .measuring(_, seconds) = state, case let .measuring(_, previous)? = lastPublishedState {
            countdownChanged = seconds != previous
        } else {
            countdownChanged = true
        }
        guard countdownChanged || time - lastPublishTime >= Self.publishInterval else { return }
        lastPublishedState = state
        lastPublishTime = time
        onMeasurement(state, generation, false)
    }

    // MARK: - Diagnostic

    /// Environ une fois par seconde de mesure (niveau debug) : l'exposition attribuée à l'image (la
    /// demande appliquée) face à celle que dit son EXIF, pour vérifier sur iPhone que les deux concordent.
    private func logDiagnostic(_ sampleBuffer: CMSampleBuffer, applied: Exposure, stats: FrameStats, at time: Double) {
        guard time - lastDiagnosticTime >= 1, let target = meter?.target else { return }
        lastDiagnosticTime = time
        let exif = Self.exifExposure(of: sampleBuffer).map { "\($0.durationSeconds) s × \($0.iso)" } ?? "absente"
        log.debug("""
            Mesure : demandée \(applied.durationSeconds) s × \(applied.iso), EXIF \(exif, privacy: .public), \
            cible \(target.durationSeconds) s × \(target.iso), luma \(stats.meanLuma)
            """)
    }

    /// Exposition lue dans l'attachement EXIF de l'image, si elle y est.
    private static func exifExposure(of sampleBuffer: CMSampleBuffer) -> Exposure? {
        guard let exif = CMGetAttachment(sampleBuffer, key: kCGImagePropertyExifDictionary, attachmentModeOut: nil)
                as? [String: Any],
              let duration = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue,
              let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.doubleValue
        else { return nil }
        return Exposure(durationSeconds: duration, iso: iso)
    }
}
