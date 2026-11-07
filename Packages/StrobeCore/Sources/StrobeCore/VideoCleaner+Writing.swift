import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

extension VideoCleaner {
    /// Cadence supposée de la source quand le fichier ne l'indique pas.
    private static let fallbackSourceFPS = 120.0

    /// Cadence de la source pour la règle de débit : `nominal`, ou `fallbackSourceFPS` si elle est inconnue
    /// (nulle, négative ou non finie).
    static func sourceFPS(nominal: Double) -> Double {
        nominal.isFinite && nominal > 0 ? nominal : fallbackSourceFPS
    }
    /// Débit vidéo minimal de la sortie, en bits par seconde.
    private static let minimumBitRate = 4_000_000.0
    /// Attente quand aucune entrée ne veut de données : doublée à chaque tour à vide, jusqu'au plafond,
    /// et remise au minimum dès qu'une entrée reprend.
    private static let minimumIdleWait = Duration.milliseconds(1)
    private static let maximumIdleWait = Duration.milliseconds(20)

    /// Ce que l'écriture a fait de plus que le plan : trous non recréés et images débruitées.
    struct WriteOutcome {
        /// Créneaux interpolés au plan qui répètent finalement A, la synthèse ayant échoué.
        var failedInterpolations = 0
        /// Trous dont la synthèse a échoué, et combien n'ont pas été détaillés dans le journal.
        var failureLog = FailureLogBudget()
        /// Images passées par le débruitage.
        var denoisedFrames = 0
        /// Images éclaircies.
        var brightenedFrames = 0
    }

    /// Passe 2 : écrit à `url` l'image du créneau k du plan à l'instant k / `outputFPS` (HEVC, même taille et
    /// même orientation que la source) et recopie la piste audio sans réencodage, horodatages compris.
    ///
    /// Les créneaux interpolés sont recréés par `interpolator` (A répétée en cas d'échec, voir `SlotImages`) ;
    /// chaque image écrite passe par `reducer` s'il est fourni (telle quelle si son filtrage échoue), puis par
    /// `lifter` s'il est fourni.
    /// `times` sont les horodatages relevés à l'analyse : chaque image relue doit avoir le sien, sinon
    /// `VideoCleanerError.sourceChanged`.
    ///
    /// `url` ne doit pas exister. `progress` reçoit la fraction des créneaux écrits (0…1, sans le 1 final).
    /// En cas d'erreur ou d'annulation, l'écriture est abandonnée ; c'est à l'appelant de supprimer le fichier.
    func write(
        _ plan: [SlotPlan],
        times: [Double],
        from source: SourceVideo,
        to url: URL,
        interpolator: (any FrameInterpolator)?,
        reducer: NoiseReducer?,
        lifter: ShadowLifter? = nil,
        progress: (Double) -> Void
    ) async throws -> WriteOutcome {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        do {
            return try await write(
                plan, times: times, from: source, with: writer,
                interpolator: interpolator, reducer: reducer, lifter: lifter, progress: progress
            )
        } catch {
            // Un ajout refusé signifie que l'écrivain a échoué : son erreur est la plus parlante.
            let failure = (writer.status == .failed ? writer.error : nil) ?? error
            if writer.status == .writing { writer.cancelWriting() }
            throw failure
        }
    }

    private func write(
        _ plan: [SlotPlan],
        times: [Double],
        from source: SourceVideo,
        with writer: AVAssetWriter,
        interpolator: (any FrameInterpolator)?,
        reducer: NoiseReducer?,
        lifter: ShadowLifter?,
        progress: (Double) -> Void
    ) async throws -> WriteOutcome {
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(for: source))
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = source.preferredTransform
        guard writer.canAdd(videoInput) else { throw VideoCleanerError.writeFailed }
        writer.add(videoInput)
        // La relecture est arrêtée en sortie, même si le plan est refusé (`SlotImages.init`).
        let frames = try VideoFrames(of: source)
        defer { frames.cancel() }
        var video = VideoPump(
            images: try SlotImages(plan: plan, times: times, frames: frames, interpolator: interpolator),
            slotCount: plan.count,
            reducer: reducer,
            lifter: lifter,
            input: videoInput,
            adaptor: AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil),
            outputFPS: config.outputFPS
        )

        var audio = try source.audioTrack.map { try AudioPassthrough(track: $0, of: source, into: writer) }
        defer { audio?.cancel() }

        guard writer.startWriting() else { throw writer.error ?? VideoCleanerError.writeFailed }
        // La session commence à 0, ou au premier échantillon audio s'il le précède.
        var sessionStart = CMTime.zero
        if let audioStart = audio?.startTime, audioStart.isNumeric {
            sessionStart = CMTimeMinimum(sessionStart, audioStart)
        }
        writer.startSession(atSourceTime: sessionStart)

        // Une seule boucle alimente les deux entrées, chacune quand elle en redemande : l'écrivain entrelace
        // audio et vidéo et n'accepte plus une entrée qui a trop d'avance sur l'autre, il ne faut donc jamais
        // attendre l'une sans servir l'autre.
        var checkpoint = CancellationCheckpoint()
        var idleWait = Self.minimumIdleWait
        while !video.isFinished || !(audio?.isFinished ?? true) {
            let wroteVideo = try await video.pump(&checkpoint, progress: progress)
            let wroteAudio = try await audio?.pump(&checkpoint) ?? false
            if wroteVideo || wroteAudio {
                idleWait = Self.minimumIdleWait
            } else {
                guard writer.status == .writing else { throw writer.error ?? VideoCleanerError.writeFailed }
                try await Task.sleep(for: idleWait)
                idleWait = min(idleWait * 2, Self.maximumIdleWait)
            }
        }

        try Task.checkCancellation()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? VideoCleanerError.writeFailed }
        return WriteOutcome(
            failedInterpolations: video.failedInterpolations,
            failureLog: video.failureLog,
            denoisedFrames: video.denoisedFrames,
            brightenedFrames: video.brightenedFrames
        )
    }

    /// Débit vidéo de la copie nettoyée, en bits par seconde : débit de la source ramené à la cadence de
    /// sortie, avec une marge de 50 %, et au moins `minimumBitRate`. `StorageEstimator.cleanedBytesPerSecond`
    /// et `estimatedCleanedBytes(of:)` en dérivent.
    static func outputBitRate(sourceBitRate: Double, sourceFPS: Double, outputFPS: Double) -> Double {
        max(minimumBitRate, sourceBitRate * outputFPS / sourceFPS * 1.5)
    }

    /// Débit vidéo de la copie nettoyée de `source` (`outputBitRate` avec le débit et la cadence de sa piste).
    func outputBitRate(for source: SourceVideo) -> Double {
        Self.outputBitRate(
            sourceBitRate: Double(source.estimatedDataRate),
            sourceFPS: Self.sourceFPS(nominal: Double(source.nominalFrameRate)),
            outputFPS: config.outputFPS
        )
    }

    /// Taille estimée, en octets, de la copie nettoyée de `url`, sans rien lire des images : la vidéo au débit
    /// que l'écriture choisira (`outputBitRate`) sur la durée de la piste vidéo, plus le son recopié tel quel.
    /// Une majoration : l'encodeur reste en général sous le débit demandé.
    ///
    /// Toujours exécutée hors de l'acteur de l'appelant (`@concurrent`).
    /// - Throws: `VideoCleanerError.noVideoTrack`, ou l'erreur d'AVFoundation si le fichier est illisible.
    @concurrent
    public func estimatedCleanedBytes(of url: URL) async throws -> Int64 {
        let source = try await SourceVideo(url: url)
        let duration = max(0, source.end - source.start)
        let audioBitRate = try await source.audioTrack?.load(.estimatedDataRate) ?? 0
        let bytes = (outputBitRate(for: source) + Double(audioBitRate)) / 8 * duration
        return bytes.isFinite ? Int64(bytes.rounded(.up)) : 0
    }

    /// HEVC, même taille que la source, au débit `outputBitRate`.
    private func videoSettings(for source: SourceVideo) -> [String: Any] {
        let bitRate = outputBitRate(for: source)
        return [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(source.naturalSize.width.rounded()),
            AVVideoHeightKey: Int(source.naturalSize.height.rounded()),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(bitRate.rounded()),
                AVVideoExpectedSourceFrameRateKey: config.outputFPS,
            ],
        ]
    }
}

/// Écrit les images de la vidéo nettoyée, une par créneau de sortie, débruitées si `reducer` est fourni, puis
/// éclaircies si `lifter` l'est.
private struct VideoPump {
    /// Échelle des horodatages de sortie : 1/30 000 s, multiple des cadences usuelles (24, 25, 30, 60…).
    /// Avec l'échelle 600, l'encodeur HEVC allongeait la piste d'un tic (3,0017 s, 29,98 i/s pour 3 s).
    private static let timescale: CMTimeScale = 30_000

    private var images: SlotImages
    let slotCount: Int
    let reducer: NoiseReducer?
    let lifter: ShadowLifter?
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let outputFPS: Double

    /// Images prêtes à écrire, dans l'ordre : la première est celle du créneau `written`. Au plus les images
    /// d'un trou et le retard du débruitage.
    private var ready: [CVPixelBuffer] = []
    /// Nombre de créneaux écrits.
    private var written = 0
    private(set) var denoisedFrames = 0
    private(set) var brightenedFrames = 0

    init(
        images: SlotImages,
        slotCount: Int,
        reducer: NoiseReducer?,
        lifter: ShadowLifter?,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        outputFPS: Double
    ) {
        self.images = images
        self.slotCount = slotCount
        self.reducer = reducer
        self.lifter = lifter
        self.input = input
        self.adaptor = adaptor
        self.outputFPS = outputFPS
    }

    var isFinished: Bool { written == slotCount }
    var failedInterpolations: Int { images.failedInterpolations }
    var failureLog: FailureLogBudget { images.failureLog }

    /// Écrit des créneaux tant que l'entrée en accepte ; `true` si au moins un a été écrit.
    /// `progress` reçoit la fraction des créneaux écrits tous les 30 créneaux.
    mutating func pump(
        _ checkpoint: inout CancellationCheckpoint,
        progress: (Double) -> Void
    ) async throws -> Bool {
        var wrote = false
        while written < slotCount, input.isReadyForMoreMediaData {
            while ready.isEmpty {
                // Chaque créneau du plan donne une image, et le débruitage rend autant d'images qu'il en reçoit :
                // ne plus rien avoir avant le dernier créneau serait une erreur de programmation.
                guard try await refill(&checkpoint) else { throw VideoCleanerError.writeFailed }
            }
            var image = ready.removeFirst()
            if let lifter {
                let lifted = lifter.apply(to: image)
                if lifted !== image { brightenedFrames += 1 }
                image = lifted
            }
            let time = CMTime(seconds: Double(written) / outputFPS, preferredTimescale: Self.timescale)
            guard adaptor.append(image, withPresentationTime: time) else { throw VideoCleanerError.writeFailed }
            written += 1
            wrote = true
            try await checkpoint.step()

            if written == slotCount {
                // Entrée épuisée : la clore tout de suite, sinon l'écrivain attend la suite pour entrelacer.
                input.markAsFinished()
            } else if written.isMultiple(of: VideoCleaner.cancellationInterval) {
                progress(Double(written) / Double(slotCount))
            }
        }
        return wrote
    }

    /// Ajoute à `ready` les images suivantes : celles du créneau (ou du trou) suivant, passées au débruitage,
    /// ou, une fois le plan épuisé, les dernières images retenues par le débruitage. `false` s'il n'y a plus rien.
    private mutating func refill(_ checkpoint: inout CancellationCheckpoint) async throws -> Bool {
        guard !images.isFinished else {
            guard let reducer else { return false }
            let outputs = await reducer.flush()
            take(outputs)
            return !outputs.isEmpty
        }
        let produced = try await images.next(&checkpoint)
        guard let reducer else {
            ready += produced
            return true
        }
        for image in produced {
            take(await reducer.push(image))
        }
        return true
    }

    private mutating func take(_ outputs: [NoiseReducer.Output]) {
        ready += outputs.map(\.image)
        denoisedFrames += outputs.count { $0.isFiltered }
    }
}

/// Recopie la piste audio sans réencodage : tampons compressés tels quels, horodatages d'origine.
private struct AudioPassthrough {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let input: AVAssetWriterInput
    /// Prochain tampon à écrire, lu d'avance (son horodatage fixe le début de la session).
    private var pending: CMSampleBuffer?
    private(set) var isFinished = false

    init(track: AVAssetTrack, of source: SourceVideo, into writer: AVAssetWriter) throws {
        reader = try AVAssetReader(asset: source.asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoCleanerError.readFailed }
        reader.add(output)

        input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: source.audioFormat)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw VideoCleanerError.writeFailed }
        writer.add(input)

        guard reader.startReading() else { throw reader.error ?? VideoCleanerError.readFailed }
        pending = try Self.next(from: output, of: reader)
    }

    /// Horodatage du premier tampon audio (`nil` si la piste est vide). Valable avant le premier `pump`.
    var startTime: CMTime? {
        pending.map(CMSampleBufferGetPresentationTimeStamp)
    }

    /// Écrit des tampons tant que l'entrée en accepte ; `true` si au moins un a été écrit.
    mutating func pump(_ checkpoint: inout CancellationCheckpoint) async throws -> Bool {
        var wrote = false
        while !isFinished {
            guard let sample = pending else {
                input.markAsFinished()
                isFinished = true
                break
            }
            guard input.isReadyForMoreMediaData else { break }
            guard input.append(sample) else { throw VideoCleanerError.writeFailed }
            wrote = true
            pending = try Self.next(from: output, of: reader)
            try await checkpoint.step()
        }
        return wrote
    }

    /// Arrête la lecture.
    func cancel() {
        reader.cancelReading()
    }

    private static func next(from output: AVAssetReaderTrackOutput, of reader: AVAssetReader) throws -> CMSampleBuffer? {
        if let sample = output.copyNextSampleBuffer() { return sample }
        if reader.status == .failed { throw reader.error ?? VideoCleanerError.readFailed }
        return nil
    }
}
