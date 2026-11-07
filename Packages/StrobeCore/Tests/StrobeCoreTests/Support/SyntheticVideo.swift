import AVFoundation
import CoreVideo
import Foundation

/// Fabrique des vidéos .mov de test : scène unie, éclairs (ou lampe qui clignote) à des indices connus,
/// audio sinus 440 Hz.
///
/// Chaque image porte son indice source dans une bande en haut de l'image : 16 bits, poids fort à gauche,
/// chaque bit codé en Manchester sur deux blocs côte à côte (blanc puis noir pour 1, noir puis blanc pour 0).
/// La bande a donc la même luma moyenne quel que soit l'indice et ne fausse pas la détection d'éclairs.
/// Les blocs (1/32 de la largeur, 1/6 de la hauteur) sont assez grands pour survivre à deux compressions HEVC
/// (fabrication puis nettoyage). Les éclairs sont des images blanches (luma 1) dont la bande reste lisible.
enum SyntheticVideo {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// File dédiée à la fabrication : l'écriture attend l'encodeur (sommeils, sémaphore), ce qui ne doit pas
    /// bloquer un fil du pool coopératif des tests.
    private static let queue = DispatchQueue(label: "SyntheticVideo", qos: .userInitiated)

    /// Écrit la vidéo à `url` (remplace un fichier existant), sur une file dédiée hors du pool coopératif.
    ///
    /// - Parameters:
    ///   - fps: cadence ; l'image i est horodatée `startTime` + i / fps.
    ///   - seconds: durée filmée.
    ///   - flashIndices: indices des images brûlées (blanches).
    ///   - baseLuma: luma de la scène hors éclairs (0…1).
    ///   - withAudio: ajoute une piste AAC (sinus 440 Hz) de même durée.
    ///   - fragmentInterval: si présent, écrit un fichier fragmenté (`movieFragmentInterval`, en secondes).
    ///   - truncateAfterSeconds: simule une app tuée en plein tournage (exige `fragmentInterval`). Dès que
    ///     les fragments écrits sur disque dépassent cet instant, on cesse d'alimenter l'écriture et on copie
    ///     les octets du fichier en cours, sans `finishWriting` : le fichier obtenu se termine par un `mdat`
    ///     inachevé, comme après un plantage. L'écriture d'origine est annulée sur son propre chemin.
    ///   - transform: `preferredTransform` de la piste vidéo (orientation, comme une vidéo filmée en portrait).
    ///   - startTime: horodatage de la première image et du premier son, en secondes ; la session d'écriture
    ///     commence là. Une valeur comme 86 400,5 imite l'app, qui écrit à l'horloge de la caméra (temps depuis
    ///     le démarrage de l'iPhone).
    ///   - lampRect: si présent, les éclairs n'allument que ce rectangle (en fractions de la largeur et de la
    ///     hauteur, origine en haut à gauche) à `flashLuma` ; le reste de l'image reste à `baseLuma`, comme une
    ///     petite lampe dans une pièce claire.
    ///   - flashLuma: luma de la scène pendant les éclairs (1 : image blanche, brûlée). Une valeur plus basse
    ///     imite une lampe qui éclaire la scène sans la brûler (voir `squareWave`).
    static func make(
        at url: URL,
        fps: Double,
        seconds: Double,
        size: CGSize,
        flashIndices: Set<Int>,
        baseLuma: Double,
        withAudio: Bool,
        fragmentInterval: Double? = nil,
        truncateAfterSeconds: Double? = nil,
        transform: CGAffineTransform = .identity,
        startTime: Double = 0,
        flashLuma: Double = 1,
        lampRect: CGRect? = nil
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                continuation.resume(with: Result {
                    try write(
                        at: url, fps: fps, seconds: seconds, size: size, flashIndices: flashIndices,
                        baseLuma: baseLuma, flashLuma: flashLuma, lampRect: lampRect, withAudio: withAudio,
                        fragmentInterval: fragmentInterval, truncateAfterSeconds: truncateAfterSeconds,
                        transform: transform, startTime: startTime
                    )
                })
            }
        }
    }

    /// Images allumées d'une lumière qui clignote en créneaux : chaque période de `fps / frequency` images
    /// (arrondi, entier) commence éteinte, puis s'allume pour sa dernière fraction `litFraction`.
    /// Pour 120 i/s, 5 Hz et 50 % : images 12 à 23 de chaque période de 24. La vidéo commence donc sans
    /// lumière, comme le premier essai sur iPhone (lampe allumée la moitié du temps).
    static func squareWave(fps: Double, seconds: Double, frequency: Double, litFraction: Double) -> Set<Int> {
        let period = Int((fps / frequency).rounded())
        let litFrames = Int((Double(period) * litFraction).rounded())
        let frameCount = Int((seconds * fps).rounded())
        return Set((0..<frameCount).filter { $0 % period >= period - litFrames })
    }

    /// Image 420 bi-planaire plein écart (IOSurface) de taille `size` : fond de luma `luma`, bande portant
    /// `index`. Pour tester les traitements d'image sans passer par une vidéo.
    static func frame(index: Int, luma: Double, size: CGSize) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        let status = CVPixelBufferCreate(
            nil, Int(size.width), Int(size.height), kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            attributes as CFDictionary, &created
        )
        guard status == kCVReturnSuccess, let buffer = created else {
            throw Failure(description: "CVPixelBufferCreate (\(status))")
        }
        draw(index: index, luma: luma, into: buffer)
        // Couleurs de la vidéo HD, comme les images d'un décodeur.
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return buffer
    }

    /// Corps bloquant de `make`.
    private static func write(
        at url: URL,
        fps: Double,
        seconds: Double,
        size: CGSize,
        flashIndices: Set<Int>,
        baseLuma: Double,
        flashLuma: Double,
        lampRect: CGRect?,
        withAudio: Bool,
        fragmentInterval: Double?,
        truncateAfterSeconds: Double?,
        transform: CGAffineTransform,
        startTime: Double
    ) throws {
        let frameCount = Int((seconds * fps).rounded())
        precondition(frameCount <= 1 << bitCount, "16 bits ne suffisent pas pour \(frameCount) images")
        precondition(
            truncateAfterSeconds == nil || fragmentInterval != nil,
            "truncateAfterSeconds exige fragmentInterval"
        )

        try? FileManager.default.removeItem(at: url)
        // Coupure simulée : on écrit ailleurs et on ne garde qu'une copie des octets déjà écrits.
        let writingURL = truncateAfterSeconds == nil
            ? url
            : url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".writing")
        try? FileManager.default.removeItem(at: writingURL)
        defer { if writingURL != url { try? FileManager.default.removeItem(at: writingURL) } }

        let writer = try AVAssetWriter(outputURL: writingURL, fileType: .mov)
        if let fragmentInterval {
            writer.movieFragmentInterval = CMTime(seconds: fragmentInterval, preferredTimescale: 600)
        }

        let width = Int(size.width)
        let height = Int(size.height)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                // Débit généreux : la bande d'indices doit rester nette.
                AVVideoAverageBitRateKey: max(4_000_000, width * height * Int(fps) / 4),
                AVVideoExpectedSourceFrameRateKey: fps,
            ],
        ])
        // Entrées « temps réel », comme à la capture : l'écrivain n'exige pas d'entrelacement strict, ce qui
        // permet de lui donner les tampons dans l'ordre des horodatages sans risque de blocage.
        videoInput.expectsMediaDataInRealTime = true
        videoInput.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(videoInput)

        let audioInput = withAudio ? AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]) : nil
        if let audioInput {
            audioInput.expectsMediaDataInRealTime = true
            writer.add(audioInput)
        }

        guard writer.startWriting() else { throw Failure(description: "startWriting : \(String(describing: writer.error))") }
        // Échelle des horodatages : 1/120 000 s pour la vidéo, 1/48 000 s pour l'audio.
        let videoStart = CMTime(seconds: startTime, preferredTimescale: 120_000)
        let audioStart = CMTime(seconds: startTime, preferredTimescale: CMTimeScale(audioSampleRate))
        writer.startSession(atSourceTime: CMTimeMinimum(videoStart, audioStart))

        let audioSampleCount = withAudio ? Int((seconds * audioSampleRate).rounded()) : 0
        let audioFormat = try makeAudioFormat()
        var nextFrame = 0
        var nextAudioSample = 0
        if frameCount == 0 { videoInput.markAsFinished() }
        if audioSampleCount == 0 { audioInput?.markAsFinished() }

        /// Ajoute l'image suivante si l'entrée vidéo en veut ; `true` si une image a été ajoutée.
        func appendVideo() throws -> Bool {
            guard nextFrame < frameCount, videoInput.isReadyForMoreMediaData else { return false }
            guard let pool = adaptor.pixelBufferPool else { throw Failure(description: "pas de pixelBufferPool") }
            var created: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
            guard let buffer = created else { throw Failure(description: "CVPixelBufferPoolCreatePixelBuffer") }
            let isFlash = flashIndices.contains(nextFrame)
            if let lampRect {
                draw(index: nextFrame, luma: baseLuma, into: buffer, lamp: (lampRect, isFlash ? flashLuma : baseLuma))
            } else {
                draw(index: nextFrame, luma: isFlash ? flashLuma : baseLuma, into: buffer)
            }
            let time = videoStart + CMTime(seconds: Double(nextFrame) / fps, preferredTimescale: 120_000)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw Failure(description: "ajout vidéo : \(String(describing: writer.error))")
            }
            nextFrame += 1
            // Une entrée épuisée doit être close tout de suite, sinon l'entrelacement bloque l'autre.
            if nextFrame == frameCount { videoInput.markAsFinished() }
            return true
        }

        /// Ajoute le morceau d'audio suivant si l'entrée audio en veut ; `true` si un morceau a été ajouté.
        func appendAudio() throws -> Bool {
            guard let audioInput, nextAudioSample < audioSampleCount, audioInput.isReadyForMoreMediaData else {
                return false
            }
            let count = min(audioChunk, audioSampleCount - nextAudioSample)
            let buffer = try makeSineBuffer(start: nextAudioSample, count: count, format: audioFormat, offset: audioStart)
            guard audioInput.append(buffer) else {
                throw Failure(description: "ajout audio : \(String(describing: writer.error))")
            }
            nextAudioSample += count
            if nextAudioSample == audioSampleCount { audioInput.markAsFinished() }
            return true
        }

        while nextFrame < frameCount || nextAudioSample < audioSampleCount {
            if writer.status == .failed { throw Failure(description: "écriture : \(String(describing: writer.error))") }

            // Coupure : on relit la structure du fichier toutes les 12 images, pas à chaque tampon.
            if let cut = truncateAfterSeconds, let interval = fragmentInterval, nextFrame % 12 == 0,
               try fragments(of: writingURL, interval: interval, cover: cut) {
                try copyWhenIdle(writingURL, to: url)
                writer.cancelWriting()
                return
            }

            // Comme à la capture : les tampons arrivent dans l'ordre des horodatages, audio et vidéo mêlés.
            let videoNext = nextAudioSample == audioSampleCount
                || (nextFrame < frameCount && Double(nextFrame) / fps <= Double(nextAudioSample) / audioSampleRate)
            let appended = videoNext ? try appendVideo() : try appendAudio()
            if !appended { Thread.sleep(forTimeInterval: 0.001) }
        }

        if truncateAfterSeconds != nil {
            writer.cancelWriting()
            throw Failure(description: "fin de la vidéo atteinte avant la coupure demandée")
        }

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw Failure(description: "finishWriting : \(String(describing: writer.error))")
        }
    }

    /// Relit l'indice source inscrit dans la bande d'une image (plan Y d'un format 420 bi-planaire).
    /// `nil` si un bit est illisible (deux blocs trop proches).
    static func decodeIndex(from buffer: CVPixelBuffer) -> Int? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(buffer) == 2,
              let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
        else { return nil }

        let luma = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let layout = BandLayout(width: CVPixelBufferGetWidthOfPlane(buffer, 0), height: CVPixelBufferGetHeightOfPlane(buffer, 0))
        guard layout.blockWidth >= 4, layout.height >= 4 else { return nil }

        // Moyenne du centre d'un bloc : loin des bords, que la compression étale.
        func centerMean(ofBlock block: Int) -> Double {
            let left = block * layout.blockWidth + layout.blockWidth / 4
            let right = (block + 1) * layout.blockWidth - layout.blockWidth / 4
            let rows = (layout.height / 4)..<(layout.height - layout.height / 4)
            var sum = 0
            for row in rows {
                for column in left..<right { sum += Int(luma[row * rowBytes + column]) }
            }
            return Double(sum) / Double(rows.count * (right - left))
        }

        var index = 0
        for bit in 0..<bitCount {
            let first = centerMean(ofBlock: 2 * bit)
            let second = centerMean(ofBlock: 2 * bit + 1)
            guard abs(first - second) >= minimumContrast else { return nil }
            index = index << 1 | (first > second ? 1 : 0)
        }
        return index
    }

    // MARK: - Image

    private static let bitCount = 16
    /// Écart minimal (sur 255) entre les deux blocs d'un bit pour le juger lisible.
    private static let minimumContrast = 64.0

    /// Géométrie de la bande : 32 blocs sur la largeur, 1/6 de la hauteur.
    private struct BandLayout {
        var blockWidth: Int
        var height: Int

        init(width: Int, height: Int) {
            blockWidth = width / (2 * SyntheticVideo.bitCount)
            self.height = height / 6
        }
    }

    /// Remplit `buffer` (420 bi-planaire plein écart) : fond de luma `luma`, rectangle `lamp` (fractions de l'image)
    /// à sa propre luma, bande d'indice, chroma neutre.
    private static func draw(
        index: Int,
        luma: Double,
        into buffer: CVPixelBuffer,
        lamp: (rect: CGRect, luma: Double)? = nil
    ) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let lumaPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
        let background = Int32((min(1, max(0, luma)) * 255).rounded())
        let layout = BandLayout(width: width, height: height)

        for row in 0..<height {
            let line = lumaPlane + row * rowBytes
            memset(line, background, width)
            if let lamp, (Double(row) / Double(height)) >= lamp.rect.minY, (Double(row) / Double(height)) < lamp.rect.maxY {
                let start = Int(lamp.rect.minX * Double(width))
                let end = Int(lamp.rect.maxX * Double(width))
                memset(line + start, Int32((min(1, max(0, lamp.luma)) * 255).rounded()), end - start)
            }
            guard row < layout.height else { continue }
            for bit in 0..<bitCount {
                let isOne = (index >> (bitCount - 1 - bit)) & 1 == 1
                let left = line + 2 * bit * layout.blockWidth
                memset(left, isOne ? 255 : 0, layout.blockWidth)
                memset(left + layout.blockWidth, isOne ? 0 : 255, layout.blockWidth)
            }
        }

        let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
    }

    // MARK: - Audio

    private static let audioSampleRate = 48_000.0
    /// Nombre d'échantillons par tampon audio (0,1 s).
    private static let audioChunk = 4_800

    /// Format PCM 16 bits mono des tampons audio fournis à l'encodeur AAC.
    private static func makeAudioFormat() throws -> CMAudioFormatDescription {
        var description = AudioStreamBasicDescription(
            mSampleRate: audioSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
        guard status == noErr, let format else { throw Failure(description: "format audio (\(status))") }
        return format
    }

    /// `count` échantillons d'un sinus 440 Hz à partir de l'échantillon `start`, horodatés `offset + start / 48 000`.
    private static func makeSineBuffer(
        start: Int, count: Int, format: CMAudioFormatDescription, offset: CMTime
    ) throws -> CMSampleBuffer {
        let samples = (0..<count).map { offset in
            Int16(sin(2 * .pi * 440 * Double(start + offset) / audioSampleRate) * 8_000)
        }
        let byteCount = count * MemoryLayout<Int16>.size

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        guard status == noErr, let block else { throw Failure(description: "bloc audio (\(status))") }
        status = samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount
            )
        }
        guard status == noErr else { throw Failure(description: "copie audio (\(status))") }

        var buffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
            presentationTimeStamp: offset + CMTime(value: CMTimeValue(start), timescale: CMTimeScale(audioSampleRate)),
            packetDescriptions: nil, sampleBufferOut: &buffer
        )
        guard status == noErr, let buffer else { throw Failure(description: "tampon audio (\(status))") }
        return buffer
    }

    // MARK: - Coupure simulée

    /// Vrai si le fichier fragmenté en cours d'écriture décrit déjà plus de `cut` secondes de média.
    ///
    /// AVAssetWriter écrit d'abord un `moov` qui décrit le premier intervalle, puis un `moof` complet après
    /// chaque intervalle suivant : `n` `moof` complets décrivent donc `(n + 1) × interval` secondes.
    private static func fragments(of url: URL, interval: Double, cover cut: Double) throws -> Bool {
        let atoms = try completeTopLevelAtoms(of: url)
        guard atoms.contains("moov") else { return false }
        let fragmentCount = atoms.filter { $0 == "moof" }.count
        return Double(fragmentCount + 1) * interval > cut
    }

    /// Types des atomes de premier niveau entièrement présents sur disque, dans l'ordre du fichier.
    private static func completeTopLevelAtoms(of url: URL) throws -> [String] {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()

        var atoms: [String] = []
        var offset: UInt64 = 0
        while offset + 8 <= length {
            try file.seek(toOffset: offset)
            guard let header = try file.read(upToCount: 16), header.count >= 8 else { break }
            let bytes = [UInt8](header)
            var size = bytes[0..<4].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            if size == 1, bytes.count == 16 {
                size = bytes[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            }
            // Taille 0 (« jusqu'à la fin », atome en cours) ou incohérente, ou atome tronqué : on s'arrête.
            guard size >= 8, offset + size <= length else { break }
            atoms.append(String(decoding: bytes[4..<8], as: UTF8.self))
            offset += size
        }
        return atoms
    }

    /// Copie `source` à `destination` une fois que l'écriture s'est arrêtée (taille stable),
    /// pour que la copie ne coupe pas un atome au milieu d'une écriture en cours.
    private static func copyWhenIdle(_ source: URL, to destination: URL) throws {
        var previousSize = -1
        for _ in 0..<50 {
            let size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int) ?? 0
            if size == previousSize { break }
            previousSize = size
            Thread.sleep(forTimeInterval: 0.05)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}
