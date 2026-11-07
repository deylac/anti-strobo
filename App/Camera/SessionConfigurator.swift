import AVFoundation
import os
import StrobeCore

private let log = Logger(subsystem: "app.camantistrobo.ios", category: "Camera")

/// Ce que la configuration a retenu : format, cadence, bornes d'exposition, son.
struct CaptureConfiguration: Sendable {
    let width: Int
    let height: Int
    /// Cadence en vigueur : celle de départ (`FormatChooser`), ou une cadence plus basse choisie pendant la
    /// mesure parce que la scène était trop sombre (`CadencePlanner`).
    let fps: Double
    /// Bornes d'exposition à cette cadence : une pose dure au plus une image (`1 / fps`, et la durée d'image
    /// appliquée).
    let limits: ExposureLimits
    let hasAudio: Bool
    /// Les cadences de `FormatChooser.cadenceSteps` qu'offre un format SDR 8 bits 4:2:0 de cette résolution, de
    /// la plus haute à la plus basse : celles où la mesure peut descendre.
    let availableCadences: [Double]

    var nominalBytesPerSecond: Double {
        StorageEstimator.nominalBytesPerSecond(width: width, height: height, fps: fps)
    }
}

enum CameraSetupError: Error {
    case noUsableFormat
    case unsupportedFrameRate
    case cannotAddVideoInput
    case cannotAddVideoOutput
}

/// Configure la session de capture et l'appareil : entrées et sorties, format SDR 8 bits et cadence fixe,
/// HDR et stabilisation coupés. Sans état ; appelé sur la file de session de `CaptureDeviceControl`.
enum SessionConfigurator {
    /// Un format et sa cadence, tels que choisis par `chooseFormat` ou `choice(at:from:of:)`.
    struct FormatChoice {
        let format: AVCaptureDevice.Format
        let fps: Double
        let frameDuration: CMTime
    }

    /// Le résultat de `configure` : la configuration publiée, le format choisi (à réappliquer si un
    /// redémarrage le perd) et l'horloge de l'appareil (celle des `syncTime` d'exposition).
    struct Setup {
        let configuration: CaptureConfiguration
        let choice: FormatChoice
        let deviceClock: CMClock?
    }

    /// Un format SDR 8 bits 4:2:0 de l'appareil, réduit à ce qui compte pour les choix de `FormatChooser`.
    private struct Candidate {
        let info: CameraFormatInfo
        /// Pleine plage (420f, comme la sortie) plutôt que plage vidéo (420v).
        let isFullRange: Bool
        let frameRates: [FrameRateRange]
        let maxISO: Double

        var cadenceFormat: CadenceFormat {
            CadenceFormat(
                index: info.index,
                width: info.width,
                height: info.height,
                isFullRange: isFullRange,
                frameRates: frameRates,
                maxISO: maxISO
            )
        }
    }

    static func configure(
        _ session: AVCaptureSession,
        device: AVCaptureDevice,
        delegate: FrameProcessor,
        withAudio: Bool
    ) throws -> Setup {
        let choice = try chooseFormat(of: device)

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let videoInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(videoInput) else { throw CameraSetupError.cannotAddVideoInput }
        session.addInput(videoInput)

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.setSampleBufferDelegate(delegate, queue: delegate.queue)
        guard session.canAddOutput(videoOutput) else { throw CameraSetupError.cannotAddVideoOutput }
        session.addOutput(videoOutput)

        let hasAudio = withAudio && addAudio(to: session, delegate: delegate)

        // Format et cadence après l'ajout des entrées et sorties, dans le même bloc de configuration :
        // la session ne les écrase plus (préréglage `inputPriority`, posé par `activeFormat`).
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        applyFormat(choice, to: device)

        if let connection = videoOutput.connection(with: .video) {
            // La stabilisation ajoute du délai et peut mélanger les images.
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
            // Images dans le sens du capteur, aux dimensions du format : l'orientation passe par le film.
            if connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }
        }

        return Setup(
            configuration: configuration(for: choice, hasAudio: hasAudio, of: device),
            choice: choice,
            deviceClock: videoInput.ports.first { $0.mediaType == .video }?.clock
        )
    }

    /// Format, cadence fixe, SDR. L'appareil doit être verrouillé.
    static func applyFormat(_ choice: FormatChoice, to device: AVCaptureDevice) {
        device.activeFormat = choice.format
        setFrameDuration(choice.frameDuration, on: device)
        // SDR seulement : la luma mesurée sur les images 8 bits doit être celle qu'on enregistre.
        device.automaticallyAdjustsVideoHDREnabled = false
        if choice.format.isVideoHDRSupported {
            device.isVideoHDREnabled = false
        }
    }

    /// Change de cadence : si le format reste le même, seule la durée d'image change (la session n'est pas
    /// reconfigurée) ; sinon le format est appliqué entier (`applyFormat`). L'appareil doit être verrouillé.
    static func applyCadence(_ choice: FormatChoice, to device: AVCaptureDevice) {
        guard device.activeFormat == choice.format else {
            applyFormat(choice, to: device)
            return
        }
        setFrameDuration(choice.frameDuration, on: device)
    }

    /// Vrai si l'appareil a déjà le format et la cadence de `choice`.
    static func isApplied(_ choice: FormatChoice, on device: AVCaptureDevice) -> Bool {
        device.activeFormat == choice.format
            && device.activeVideoMinFrameDuration == choice.frameDuration
            && device.activeVideoMaxFrameDuration == choice.frameDuration
    }

    /// Dimensions, cadence, bornes d'exposition d'un format choisi, et cadences offertes à sa résolution.
    static func configuration(for choice: FormatChoice, hasAudio: Bool, of device: AVCaptureDevice) -> CaptureConfiguration {
        let format = choice.format
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let width = Int(dimensions.width)
        let height = Int(dimensions.height)
        let limits = ExposureLimits(
            minDuration: format.minExposureDuration.seconds,
            formatMaxDuration: format.maxExposureDuration.seconds,
            fps: choice.fps,
            appliedFrameDuration: choice.frameDuration.seconds,
            minISO: Double(format.minISO),
            maxISO: Double(format.maxISO)
        )
        let sameResolution = candidates(of: device.formats).filter { $0.info.width == width && $0.info.height == height }
        return CaptureConfiguration(
            width: width,
            height: height,
            fps: choice.fps,
            limits: limits,
            hasAudio: hasAudio,
            availableCadences: FormatChooser.availableCadences(in: sameResolution.flatMap(\.frameRates))
        )
    }

    /// Le format de `FormatChooser`, parmi les formats SDR 8 bits 4:2:0 (pas de 10 bits ni de HDR). Si le
    /// même format existe en pleine plage (420f, comme la sortie), c'est lui qui est pris : pas de conversion
    /// de plage à chaque image.
    static func chooseFormat(of device: AVCaptureDevice) throws -> FormatChoice {
        let formats = device.formats
        let candidates = candidates(of: formats)
        guard let choice = FormatChooser.choose(candidates.map(\.info)),
              let chosen = candidates.first(where: { $0.info.index == choice.index })?.info
        else { throw CameraSetupError.noUsableFormat }

        let fullRangeTwin = candidates
            .filter { $0.isFullRange && $0.info.width == chosen.width && $0.info.height == chosen.height
                && $0.info.maxFPS == chosen.maxFPS }
            .min { $0.info.index < $1.info.index }
        let format = formats[fullRangeTwin?.info.index ?? chosen.index]
        return FormatChoice(format: format, fps: choice.fps, frameDuration: try frameDuration(of: format, fps: choice.fps))
    }

    /// Le choix pour filmer à `fps` sans changer de résolution : parmi les formats SDR 8 bits 4:2:0 de même
    /// résolution qui permettent cette cadence, le plus sensible (`FormatChooser.formatForCadence`) ; à ISO
    /// maximal égal, le format de `current` s'il est toujours proposé (seule la durée d'image change), puis la
    /// pleine plage (420f), puis le premier de la liste.
    static func choice(at fps: Double, from current: FormatChoice, of device: AVCaptureDevice) throws -> FormatChoice {
        let formats = device.formats
        let dimensions = CMVideoFormatDescriptionGetDimensions(current.format.formatDescription)
        let currentFormat = CadenceFormat(
            index: formats.firstIndex(of: current.format) ?? -1,
            width: Int(dimensions.width),
            height: Int(dimensions.height),
            isFullRange: CMFormatDescriptionGetMediaSubType(current.format.formatDescription)
                == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            frameRates: current.format.videoSupportedFrameRateRanges.map(frameRateRange),
            maxISO: Double(current.format.maxISO)
        )
        let cadenceFormats = candidates(of: formats).map(\.cadenceFormat)
        guard let index = FormatChooser.formatForCadence(fps, current: currentFormat, among: cadenceFormats) else {
            throw CameraSetupError.unsupportedFrameRate
        }
        let format = formats[index]
        return FormatChoice(format: format, fps: fps, frameDuration: try frameDuration(of: format, fps: fps))
    }

    /// Les formats SDR 8 bits 4:2:0 de `formats`, avec leur position dans la liste.
    private static func candidates(of formats: [AVCaptureDevice.Format]) -> [Candidate] {
        formats.enumerated().compactMap { index, format -> Candidate? in
            let isFullRange: Bool
            switch CMFormatDescriptionGetMediaSubType(format.formatDescription) {
            case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: isFullRange = true
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: isFullRange = false
            default: return nil
            }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let ranges = format.videoSupportedFrameRateRanges
            let maxRate = ranges.map(\.maxFrameRate).max() ?? 0
            // Arrondi : un format à 119,88 i/s compte comme un format 120 i/s.
            let info = CameraFormatInfo(
                index: index,
                width: Int(dimensions.width),
                height: Int(dimensions.height),
                maxFPS: maxRate.rounded()
            )
            return Candidate(
                info: info,
                isFullRange: isFullRange,
                frameRates: ranges.map(frameRateRange),
                maxISO: Double(format.maxISO)
            )
        }
    }

    private static func frameRateRange(_ range: AVFrameRateRange) -> FrameRateRange {
        FrameRateRange(minFPS: range.minFrameRate, maxFPS: range.maxFrameRate)
    }

    /// Durée d'image pour `fps`, ramenée dans la plage du format (119,88 i/s donne 1001/120000 s).
    private static func frameDuration(of format: AVCaptureDevice.Format, fps: Double) throws -> CMTime {
        let wanted = fps.rounded()
        guard let range = format.videoSupportedFrameRateRanges.first(where: { frameRateRange($0).allows(wanted) })
        else { throw CameraSetupError.unsupportedFrameRate }
        let duration = CMTime(value: 1, timescale: CMTimeScale(wanted))
        return min(max(duration, range.minFrameDuration), range.maxFrameDuration)
    }

    /// Cadence fixe : durées d'image minimale et maximale égales. L'ordre des deux écritures garde la minimale
    /// sous la maximale à chaque instant, que la cadence monte ou descende.
    private static func setFrameDuration(_ duration: CMTime, on device: AVCaptureDevice) {
        if duration > device.activeVideoMaxFrameDuration {
            device.activeVideoMaxFrameDuration = duration
            device.activeVideoMinFrameDuration = duration
        } else {
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }
    }

    /// Micro et sortie audio ; faux (vidéo seule) si l'un des deux ne peut pas être ajouté.
    private static func addAudio(to session: AVCaptureSession, delegate: FrameProcessor) -> Bool {
        guard let microphone = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: microphone),
              session.canAddInput(input)
        else {
            log.error("Micro indisponible : vidéo sans son")
            return false
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(delegate, queue: delegate.queue)
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            log.error("Sortie audio refusée : vidéo sans son")
            return false
        }
        session.addOutput(output)
        return true
    }
}
