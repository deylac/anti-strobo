import AVFoundation
import os
import Synchronization

private let log = Logger(subsystem: "app.camantistrobo.ios", category: "MovieRecorder")

/// Écrit l'enregistrement original à partir des tampons de la caméra : vidéo encodée selon `videoSettings`,
/// audio optionnel, dans un `.mov` fragmenté chaque seconde pour qu'un enregistrement coupé net (chauffe,
/// appel, app tuée) reste lisible jusqu'au dernier fragment écrit.
///
/// La session d'écriture commence à l'horodatage de la première image vidéo ; l'audio qui la précède est
/// écarté. Une image qui arrive quand l'encodeur n'est pas prêt est perdue (on écrit en temps réel) : le
/// nettoyage travaille sur les horodatages et tolère une cadence irrégulière.
///
/// Sûr entre threads : `append` et `hasFailed` passent par un verrou et ne touchent plus au writer dès que
/// `finish()` a commencé (posé sous ce même verrou) ; `finish()` en a alors l'usage exclusif, et un second
/// `finish()` échoue. Les appelants détachent tout de même l'enregistreur de la file de capture avant
/// d'appeler `finish()` (c'est ce que fait `CameraController`) : sinon les images suivantes seraient
/// ignorées en silence.
final class MovieRecorder: @unchecked Sendable {
    enum RecorderError: Error {
        /// L'`AVAssetWriter` refuse une piste avec ces réglages.
        case cannotAddInput(AVMediaType)
        /// `startWriting()` a échoué.
        case cannotStartWriting((any Error)?)
        /// Aucune image vidéo n'a été reçue : il n'y a rien à garder, le fichier est supprimé.
        case noVideoFrame
        /// `finish()` a déjà été appelé.
        case alreadyFinished
        /// L'écriture a échoué en cours de route, ou à la finalisation.
        case writingFailed((any Error)?)
    }

    /// Le fichier écrit.
    let url: URL

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?

    /// Tout ce qui change après l'init, et tout accès au writer et à ses pistes, passe par ce verrou ; sauf
    /// dans `finish()` une fois `isFinished` posé, quand plus rien d'autre n'y touche.
    private let state = Mutex(State())

    private struct State {
        /// Horodatage de la première image vidéo, où commence la session d'écriture.
        var sessionStart: CMTime?
        var isFinished = false
        var droppedVideoFrames = 0
        var droppedAudioBuffers = 0
    }

    /// Une session d'écriture fragmentée : chaque seconde, ce qui est écrit devient lisible.
    private static let fragmentInterval = CMTime(value: 1, timescale: 1)

    /// - Parameters:
    ///   - url: fichier `.mov` à créer (il ne doit pas exister).
    ///   - videoSettings: réglages de sortie de la piste vidéo (codec, dimensions, compression).
    ///   - audioSettings: réglages de sortie de la piste audio, ou `nil` pour un film sans son.
    ///   - sourceFormat: format des images de la caméra.
    ///   - transform: orientation d'affichage de la vidéo (`preferredTransform` de la piste) ; les images
    ///     sont écrites telles que le capteur les donne.
    init(
        url: URL,
        videoSettings: [String: Any],
        audioSettings: [String: Any]?,
        sourceFormat: CMFormatDescription,
        transform: CGAffineTransform = .identity
    ) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = Self.fragmentInterval

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings, sourceFormatHint: sourceFormat)
        videoInput.expectsMediaDataInRealTime = true
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else { throw RecorderError.cannotAddInput(.video) }
        writer.add(videoInput)

        if let audioSettings {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecorderError.cannotAddInput(.audio) }
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }

        guard writer.startWriting() else { throw RecorderError.cannotStartWriting(writer.error) }
    }

    /// Vrai quand l'écriture a échoué (disque plein, encodeur en erreur) : plus rien ne sera écrit. Faux
    /// une fois `finish()` commencé, sans toucher au writer (qui appartient alors à `finish()`).
    var hasFailed: Bool {
        state.withLock { state in !state.isFinished && writer.status == .failed }
    }

    /// Ajoute une image vidéo ; la première ouvre la session d'écriture à son horodatage.
    func append(video sampleBuffer: CMSampleBuffer) {
        state.withLock { state in
            guard !state.isFinished, writer.status == .writing else { return }
            if state.sessionStart == nil {
                let start = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                writer.startSession(atSourceTime: start)
                state.sessionStart = start
            }
            guard videoInput.isReadyForMoreMediaData else {
                state.droppedVideoFrames += 1
                return
            }
            // Un refus veut dire que le writer est passé en échec : `hasFailed` le signale.
            _ = videoInput.append(sampleBuffer)
        }
    }

    /// Ajoute un tampon audio ; ignoré tant que la vidéo n'a pas commencé, ou s'il précède la première image.
    func append(audio sampleBuffer: CMSampleBuffer) {
        state.withLock { state in
            guard let audioInput, !state.isFinished, writer.status == .writing,
                  let start = state.sessionStart,
                  CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= start
            else { return }
            guard audioInput.isReadyForMoreMediaData else {
                state.droppedAudioBuffers += 1
                return
            }
            _ = audioInput.append(sampleBuffer)
        }
    }

    /// Termine le fichier et le rend. À appeler une seule fois, quand plus aucune image n'arrive (arrêt
    /// normal ou interruption) ; les `append` qui suivent sont ignorés.
    ///
    /// Sans aucune image vidéo, le fichier est supprimé et `RecorderError.noVideoFrame` est levée. Si
    /// l'écriture a échoué, l'erreur est levée et le fichier, s'il existe, est laissé tel quel : ses fragments
    /// complets restent lisibles.
    func finish() async throws -> URL {
        let summary = try state.withLock { state in
            guard !state.isFinished else { throw RecorderError.alreadyFinished }
            state.isFinished = true
            return (hasVideo: state.sessionStart != nil,
                    droppedVideo: state.droppedVideoFrames,
                    droppedAudio: state.droppedAudioBuffers)
        }
        // Désormais, aucun `append` ne touche plus au writer : il est à nous seuls.

        guard summary.hasVideo else {
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: url)
            throw RecorderError.noVideoFrame
        }
        guard writer.status == .writing else {
            log.error("Écriture en échec avant la fin : \(String(describing: self.writer.error), privacy: .public)")
            throw RecorderError.writingFailed(writer.error)
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            log.error("Finalisation impossible : \(String(describing: self.writer.error), privacy: .public)")
            throw RecorderError.writingFailed(writer.error)
        }

        if summary.droppedVideo > 0 || summary.droppedAudio > 0 {
            log.notice("Tampons perdus (encodeur pas prêt) : \(summary.droppedVideo) images, \(summary.droppedAudio) audio")
        }
        return url
    }
}
