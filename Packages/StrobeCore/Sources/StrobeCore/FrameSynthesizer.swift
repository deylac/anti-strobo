import CoreMedia
import CoreVideo
import VideoToolbox

/// Ce dont le nettoyage a besoin pour recréer les images d'un trou. `FrameSynthesizer` en est la version
/// réelle ; les tests y substituent une synthèse qui échoue.
protocol FrameInterpolator: AnyObject {
    /// Images recréées entre `a` et `b` (images décodées, 420 bi-planaire plein écart, même taille), une par
    /// phase (strictement entre 0 et 1, 0 étant `a`), dans l'ordre des phases, au format, à la taille et aux
    /// couleurs de `a`. Aucune phase : aucune image.
    func frames(between a: CVPixelBuffer, and b: CVPixelBuffer, phases: [Float]) async throws -> [CVPixelBuffer]

    /// Termine le travail (session du processeur close). À appeler une fois les synthèses finies, avant de
    /// lâcher l'objet ; sans effet la deuxième fois.
    func finish()
}

#if !targetEnvironment(simulator)

/// Recrée des images intermédiaires entre deux images, par l'interpolation d'Apple (`VTFrameProcessor` avec
/// `VTFrameRateConversionConfiguration`, iOS 26 / macOS 15.4).
///
/// Le processeur ne lit pas forcément le format du décodeur (sur Mac, il ne prend que du RGBA demi-flottant) :
/// A et B sont copiés dans son format à l'aller, les images recréées reviennent au format du décodeur, couleurs
/// de A comprises (`PixelBufferConverter`). Chaque trou est indépendant des autres (mode `random` : les trous
/// ne se suivent pas). Mémoire : un trou est recréé en appels de `maximumFramesPerCall` images au plus (mêmes
/// A et B), et les images de travail qui ne servent plus sont rendues dès la fin du trou.
///
/// La session doit être close par `finish()` avant que l'objet soit lâché : un `VTFrameProcessor` libéré en
/// dernier depuis la file de rappel de VideoToolbox, session ouverte, fait planter l'app (attente sur sa propre
/// file).
final class FrameSynthesizer: FrameInterpolator {
    /// Échelle des horodatages donnés au processeur : la microseconde.
    private static let timescale: CMTimeScale = 1_000_000
    /// Nombre maximal d'images recréées par appel au processeur. Ses images de destination sont lourdes (RGBA
    /// demi-flottant sur Mac : 16 Mo chacune en 1080p) ; un trou plus long est recréé en plusieurs appels.
    static let maximumFramesPerCall = 4

    private let processor = VTFrameProcessor()
    /// Copie de A et B au format et aux exigences des images sources du processeur.
    private let sources: PixelBufferConverter
    /// Images que le processeur remplit.
    private let destinations: PixelBufferConverter
    /// Retour au format du décodeur.
    private let outputs: PixelBufferConverter
    /// Début (en tics de `timescale`) de l'appel suivant : chaque appel occupe 2 s, pour des horodatages
    /// toujours croissants.
    private var clock: Int64 = 0
    private var isFinished = false
    /// Nombre d'appels au processeur depuis la création (pour les tests).
    private(set) var processorCalls = 0

    /// `nil` si l'interpolation n'est pas prise en charge (appareil, taille) ou si sa session ne démarre pas.
    init?(width: Int, height: Int) {
        guard let configuration = Self.configuration(width: width, height: height),
              let format = Self.processingFormat(of: configuration),
              let sources = PixelBufferConverter(
                  format: format, width: width, height: height,
                  requirements: configuration.sourcePixelBufferAttributes
              ),
              let destinations = PixelBufferConverter(
                  format: format, width: width, height: height,
                  requirements: configuration.destinationPixelBufferAttributes
              ),
              let outputs = PixelBufferConverter(format: cleanerFrameFormat, width: width, height: height)
        else { return nil }
        self.sources = sources
        self.destinations = destinations
        self.outputs = outputs
        do {
            try processor.startSession(configuration: configuration)
        } catch {
            isFinished = true  // pas de session à clore
            return nil
        }
    }

    deinit {
        finish()
    }

    /// Vrai si l'appareil sait recréer des images de cette taille (sans démarrer de session).
    static func isSupported(width: Int, height: Int) -> Bool {
        configuration(width: width, height: height).flatMap(processingFormat) != nil
    }

    /// Vrai si l'appareil offre l'interpolation, toutes tailles confondues
    /// (`VTFrameRateConversionConfiguration.isSupported`).
    static var isAvailable: Bool {
        VTFrameRateConversionConfiguration.isSupported
    }

    func frames(between a: CVPixelBuffer, and b: CVPixelBuffer, phases: [Float]) async throws -> [CVPixelBuffer] {
        guard !phases.isEmpty else { return [] }
        defer {
            sources.flush()
            destinations.flush()
            outputs.flush()
        }
        let start = clock
        clock += 2 * Int64(Self.timescale)
        /// Horodatage d'une position du trajet de A (0) à B (1).
        func time(_ position: Float) -> CMTime {
            CMTime(value: start + Int64((Double(position) * Double(Self.timescale)).rounded()), timescale: Self.timescale)
        }

        guard let source = VTFrameProcessorFrame(
                  buffer: try sources.convert(a, colorsFrom: a), presentationTimeStamp: time(0)
              ),
              let next = VTFrameProcessorFrame(
                  buffer: try sources.convert(b, colorsFrom: b), presentationTimeStamp: time(1)
              )
        else { throw FrameProcessingError.invalidParameters }

        var images: [CVPixelBuffer] = []
        images.reserveCapacity(phases.count)
        for chunkStart in stride(from: 0, to: phases.count, by: Self.maximumFramesPerCall) {
            let chunk = Array(phases[chunkStart..<min(chunkStart + Self.maximumFramesPerCall, phases.count)])
            let frames = try chunk.compactMap { phase in
                VTFrameProcessorFrame(buffer: try destinations.makeBuffer(), presentationTimeStamp: time(phase))
            }
            guard frames.count == chunk.count,
                  let parameters = VTFrameRateConversionParameters(
                      sourceFrame: source,
                      nextFrame: next,
                      opticalFlow: nil,
                      interpolationPhase: chunk,
                      // Appels suivants du même trou : mêmes A et B, le processeur peut garder son travail.
                      submissionMode: chunkStart == 0 ? .random : .sequentialReferencesUnchanged,
                      destinationFrames: frames
                  )
            else { throw FrameProcessingError.invalidParameters }

            processorCalls += 1
            let _: any VTFrameProcessorParameters = try await processor.process(parameters: parameters)
            images += try frames.map { try outputs.convert($0.buffer, colorsFrom: a) }
        }
        return images
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        processor.endSession()
    }

    /// Configuration de l'interpolation pour cette taille, ou `nil` si elle n'est pas prise en charge.
    private static func configuration(width: Int, height: Int) -> VTFrameRateConversionConfiguration? {
        guard width > 0, height > 0, VTFrameRateConversionConfiguration.isSupported else { return nil }
        return VTFrameRateConversionConfiguration(
            frameWidth: width,
            frameHeight: height,
            usePrecomputedFlow: false,
            qualityPrioritization: .normal,
            revision: VTFrameRateConversionConfiguration.defaultRevision
        )
    }

    /// Format de travail du processeur : celui du décodeur s'il le prend, sinon le premier qu'il prend.
    private static func processingFormat(of configuration: VTFrameRateConversionConfiguration) -> OSType? {
        let formats = configuration.supportedPixelFormats
        return formats.contains(cleanerFrameFormat) ? cleanerFrameFormat : formats.first
    }
}

#else

/// Simulateur : VideoToolbox n'y offre pas l'interpolation, le nettoyage garde le comportement V1.
final class FrameSynthesizer: FrameInterpolator {
    static let maximumFramesPerCall = 4
    let processorCalls = 0

    init?(width: Int, height: Int) {
        return nil
    }

    static func isSupported(width: Int, height: Int) -> Bool {
        false
    }

    static var isAvailable: Bool {
        false
    }

    func frames(between a: CVPixelBuffer, and b: CVPixelBuffer, phases: [Float]) async throws -> [CVPixelBuffer] {
        throw FrameProcessingError.unavailable
    }

    func finish() {}
}

#endif
