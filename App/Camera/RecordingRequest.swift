import AVFoundation
import StrobeCore

/// Un enregistrement à ouvrir dès la prochaine image : fichier, réglages d'encodage et orientation.
struct RecordingRequest: Sendable {
    let url: URL
    let width: Int
    let height: Int
    let fps: Double
    let hasAudio: Bool
    /// Orientation d'affichage du film (`preferredTransform`) ; les images restent celles du capteur.
    let transform: CGAffineTransform

    /// - Parameter rotationAngle: angle de capture d'`AVCaptureDevice.RotationCoordinator` au lancement.
    init(url: URL, configuration: CaptureConfiguration, rotationAngle: CGFloat) {
        self.url = url
        width = configuration.width
        height = configuration.height
        fps = configuration.fps
        hasAudio = configuration.hasAudio
        transform = VideoOrientation.preferredTransform(rotatingClockwise: rotationAngle, width: width, height: height)
    }

    /// HEVC aux dimensions du format, au débit nominal de `StorageEstimator` : l'estimation du temps
    /// restant correspond ainsi au fichier écrit.
    var videoSettings: [String: Any] {
        let bitsPerSecond = StorageEstimator.nominalBytesPerSecond(width: width, height: height, fps: fps) * 8
        return [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(bitsPerSecond.rounded()),
                AVVideoExpectedSourceFrameRateKey: fps,
            ] as [String: Any],
        ]
    }

    /// AAC 48 kHz stéréo, ou `nil` sans micro.
    var audioSettings: [String: Any]? {
        guard hasAudio else { return nil }
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
        ]
    }
}
