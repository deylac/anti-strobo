import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Ce qu'il faut savoir du fichier source, chargé une fois.
struct SourceVideo {
    let asset: AVURLAsset
    let videoTrack: AVAssetTrack
    /// Début et fin (secondes) de la plage de la piste vidéo ; `end` est la durée donnée au choix des images.
    let start: Double
    let end: Double
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    /// Cadence nominale (0 si inconnue).
    let nominalFrameRate: Float
    /// Débit estimé de la piste vidéo, en bits par seconde.
    let estimatedDataRate: Float
    let audioTrack: AVAssetTrack?
    let audioFormat: CMFormatDescription?

    init(url: URL) async throws {
        asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoCleanerError.noVideoTrack
        }
        videoTrack = video
        let (range, size, transform, frameRate, dataRate) = try await video.load(
            .timeRange, .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate
        )
        start = range.start.seconds
        end = range.end.seconds
        naturalSize = size
        preferredTransform = transform
        nominalFrameRate = frameRate
        estimatedDataRate = dataRate

        audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        audioFormat = try await audioTrack?.load(.formatDescriptions).first
    }

    /// Taille des images décodées, en pixels (celle du capteur, avant l'orientation d'affichage).
    var frameSize: (width: Int, height: Int) {
        (Int(naturalSize.width.rounded()), Int(naturalSize.height.rounded()))
    }
}

/// Format des images décodées par le nettoyage (lu par `LumaSampler`), et donc des images rendues par la
/// synthèse et le débruitage.
let cleanerFrameFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

/// Images décodées de la piste vidéo, au format `cleanerFrameFormat` (420 bi-planaire plein écart),
/// dans l'ordre d'affichage. Les deux passes lisent la même suite : l'indice d'une image est son rang ici.
struct VideoFrames {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput

    init(of source: SourceVideo) throws {
        reader = try AVAssetReader(asset: source.asset)
        output = AVAssetReaderTrackOutput(track: source.videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: cleanerFrameFormat,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoCleanerError.readFailed }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? VideoCleanerError.readFailed }
    }

    /// Image suivante, ou `nil` en fin de piste ; lève l'erreur du lecteur s'il a échoué.
    func next() throws -> (time: Double, image: CVPixelBuffer)? {
        while let sample = output.copyNextSampleBuffer() {
            // Les tampons sans image (marqueurs) ne comptent pas comme des images.
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            return (CMSampleBufferGetPresentationTimeStamp(sample).seconds, image)
        }
        if reader.status == .failed { throw reader.error ?? VideoCleanerError.readFailed }
        return nil
    }

    /// Arrête la lecture et libère le décodeur.
    func cancel() {
        reader.cancelReading()
    }
}

/// Compte les images traitées ; toutes les `VideoCleaner.cancellationInterval`, vérifie l'annulation et
/// cède la main (`Task.yield`) pour ne pas accaparer un fil du pool coopératif pendant tout le nettoyage.
struct CancellationCheckpoint {
    private var count = 0

    /// Compte une image ; lève `CancellationError` si la tâche est annulée.
    mutating func step() async throws {
        count += 1
        guard count.isMultiple(of: VideoCleaner.cancellationInterval) else { return }
        try Task.checkCancellation()
        await Task.yield()
    }
}
