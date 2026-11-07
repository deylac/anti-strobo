import CoreMedia
import CoreVideo
import VideoToolbox

/// Débruite les images de la vidéo nettoyée, par le filtre temporel d'Apple (`VTFrameProcessor` avec
/// `VTTemporalNoiseFilterConfiguration`, iOS 26 / macOS 26).
///
/// Chaque image est filtrée avec ses voisines de la vidéo de sortie, non filtrées, comme références : jusqu'à
/// `previousFrameCount` images d'avant et `nextFrameCount` d'après, comme le demande le filtre. Les images
/// sortent donc avec un retard de `nextFrameCount` images : `push` en rend une (aucune au début), `flush`
/// rend les dernières. Mémoire bornée : `nextFrameCount + 1` images en attente et `previousFrameCount`
/// références au plus.
///
/// Le filtre ne lit pas le format du décodeur : les images sont copiées dans un format qu'il prend (sans perte
/// de préférence) puis reviennent au format du décodeur, couleurs comprises. Une image dont le filtrage échoue, ou
/// rend une image plus de deux fois plus sombre (`FrameProcessingError.implausibleResult`), sort telle quelle : le
/// débruitage ne fait jamais échouer le nettoyage.
final class NoiseReducer {
    /// Image rendue, dans l'ordre d'arrivée.
    struct Output {
        var image: CVPixelBuffer
        /// Faux si le filtrage a échoué : `image` est alors l'image reçue, telle quelle.
        var isFiltered: Bool
    }

    /// Étape de filtrage d'une image : envoie ses paramètres au filtre et attend le résultat. Les tests
    /// l'enrobent (`wrapProcess`) pour simuler des échecs.
    typealias Process = (any VTFrameProcessorParameters) async throws -> Void

    #if !targetEnvironment(simulator)

    /// Force du filtre (0…1) : 0,5 par défaut, pour retirer le grain d'une scène sombre sans en lisser les détails ;
    /// plus fort quand la scène est éclaircie (`ShadowLift.denoiseStrength`).
    private let strength: Float
    /// Formats de travail préférés, dans l'ordre : sans perte d'abord (aller-retour exact), puis le format du
    /// décodeur ; plein écart d'abord, comme le décodeur. À défaut, le premier format que le filtre prend.
    private static let preferredFormats: [OSType] = [
        kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    ]

    /// Image reçue et pas encore rendue, avec sa copie au format du filtre (`nil` si la copie a échoué : elle
    /// sortira telle quelle et ne servira pas de référence).
    private struct Pending {
        var original: CVPixelBuffer
        var frame: VTFrameProcessorFrame?
    }

    private let processor = VTFrameProcessor()
    private let process: Process
    private let sources: PixelBufferConverter
    private let destinations: PixelBufferConverter
    private let outputs: PixelBufferConverter
    private let previousCount: Int
    private let nextCount: Int
    private var pending: [Pending] = []
    /// Références d'avant : copies non filtrées des dernières images rendues.
    private var previous: [VTFrameProcessorFrame] = []
    /// Nombre d'images reçues : horodatage (en 1/30 s) de la suivante pour le filtre.
    private var received: Int64 = 0
    /// Vrai une fois une image filtrée : la première signale au filtre le début d'une suite.
    private var hasFiltered = false
    private var isFinished = false

    /// `nil` si le filtre n'est pas pris en charge (appareil, taille, formats) ou si sa session ne démarre pas.
    /// - Parameter wrapProcess: enrobe l'étape de filtrage (tests) ; par défaut, le filtre d'Apple tel quel.
    init?(width: Int, height: Int, strength: Float = 0.5, wrapProcess: ((@escaping Process) -> Process)? = nil) {
        guard case let (configuration, format)? = Self.configuration(width: width, height: height),
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
        let filter: Process = { [processor] parameters in
            let _: any VTFrameProcessorParameters = try await processor.process(parameters: parameters)
        }
        process = wrapProcess?(filter) ?? filter
        self.strength = min(1, max(0, strength))
        self.sources = sources
        self.destinations = destinations
        self.outputs = outputs
        previousCount = max(0, configuration.previousFrameCount ?? 1)
        nextCount = max(0, configuration.nextFrameCount ?? 1)
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

    /// Vrai si l'appareil sait débruiter des images de cette taille (sans démarrer de session).
    static func isSupported(width: Int, height: Int) -> Bool {
        configuration(width: width, height: height) != nil
    }

    /// Vrai si l'appareil offre le débruitage, toutes tailles confondues
    /// (`VTTemporalNoiseFilterConfiguration.isSupported`).
    static var isAvailable: Bool {
        VTTemporalNoiseFilterConfiguration.isSupported
    }

    /// Configuration du filtre pour cette taille et son format de travail, ou `nil` s'il n'est pas pris en
    /// charge.
    private static func configuration(
        width: Int,
        height: Int
    ) -> (VTTemporalNoiseFilterConfiguration, OSType)? {
        guard width > 0, height > 0, VTTemporalNoiseFilterConfiguration.isSupported else { return nil }
        let supported = VTTemporalNoiseFilterConfiguration.supportedSourcePixelFormats
        guard let format = preferredFormats.first(where: supported.contains) ?? supported.first,
              let configuration = VTTemporalNoiseFilterConfiguration(
                  frameWidth: width, frameHeight: height, sourcePixelFormat: format
              )
        else { return nil }
        return (configuration, format)
    }

    /// Reçoit l'image suivante de la vidéo de sortie (format du décodeur) ; rend celles qui sont prêtes, dans
    /// l'ordre : aucune tant que les `nextFrameCount` images d'après ne sont pas arrivées, une ensuite.
    func push(_ image: CVPixelBuffer) async -> [Output] {
        let time = CMTime(value: received, timescale: 30)
        received += 1
        let copy = try? sources.convert(image, colorsFrom: image)
        pending.append(Pending(
            original: image,
            frame: copy.flatMap { VTFrameProcessorFrame(buffer: $0, presentationTimeStamp: time) }
        ))
        guard pending.count > nextCount else { return [] }
        return [await filterFirst()]
    }

    /// Rend toutes les images en attente (fin de la vidéo), filtrées avec les références qui restent.
    func flush() async -> [Output] {
        var outputs: [Output] = []
        while !pending.isEmpty {
            outputs.append(await filterFirst())
        }
        return outputs
    }

    /// Termine le travail (session du filtre close) ; à appeler avant de lâcher l'objet, sans effet ensuite.
    func finish() {
        guard !isFinished else { return }
        isFinished = true
        processor.endSession()
    }

    /// Filtre et rend la plus ancienne image en attente, qui devient une référence d'avant.
    private func filterFirst() async -> Output {
        let target = pending.removeFirst()
        defer {
            if let frame = target.frame {
                previous = Array((previous + [frame]).suffix(previousCount))
            }
        }
        guard let source = target.frame else { return Output(image: target.original, isFiltered: false) }

        do {
            guard let destination = VTFrameProcessorFrame(
                      buffer: try destinations.makeBuffer(), presentationTimeStamp: source.presentationTimeStamp
                  ),
                  let parameters = VTTemporalNoiseFilterParameters(
                      sourceFrame: source,
                      nextFrames: pending.prefix(nextCount).compactMap(\.frame),
                      previousFrames: previous,
                      destinationFrame: destination,
                      filterStrength: strength,
                      hasDiscontinuity: !hasFiltered
                  )
            else { throw FrameProcessingError.invalidParameters }
            try await process(parameters)
            hasFiltered = true
            let filtered = try outputs.convert(destination.buffer, colorsFrom: target.original)
            // Un débruitage ne rend pas l'image deux fois plus sombre : sinon le filtre a échoué sans le dire (GPU
            // refusé, iPhone verrouillé pendant le nettoyage, qui rend du noir).
            guard LumaSampler.stats(of: filtered).meanLuma >= LumaSampler.stats(of: target.original).meanLuma / 2
            else { throw FrameProcessingError.implausibleResult }
            return Output(image: filtered, isFiltered: true)
        } catch {
            return Output(image: target.original, isFiltered: false)
        }
    }

    #else

    /// Simulateur : VideoToolbox n'y offre pas le filtre, rien n'est débruité.
    init?(width: Int, height: Int, strength: Float = 0.5, wrapProcess: ((@escaping Process) -> Process)? = nil) {
        return nil
    }

    static func isSupported(width: Int, height: Int) -> Bool {
        false
    }

    static var isAvailable: Bool {
        false
    }

    func push(_ image: CVPixelBuffer) async -> [Output] {
        [Output(image: image, isFiltered: false)]
    }

    func flush() async -> [Output] {
        []
    }

    func finish() {}

    #endif
}
