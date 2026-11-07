import CoreVideo
import VideoToolbox

/// Échec d'un traitement d'image (synthèse ou débruitage). Jamais remonté par le nettoyage, qui se replie.
enum FrameProcessingError: Error {
    /// Création d'une image dans un pool (code `CVReturn`).
    case bufferCreation(CVReturn)
    /// Conversion de format par `VTPixelTransferSession` (code `OSStatus`).
    case transfer(OSStatus)
    /// Paramètres refusés par le processeur (formats ou nombres d'images incohérents), ou résultat incomplet.
    case invalidParameters
    /// Aucune synthèse d'images disponible.
    case unavailable
    /// Résultat sans rapport avec ses images de départ (noir, faute de GPU écran verrouillé) : rendu sans erreur,
    /// mais faux.
    case implausibleResult
}

/// Fabrique des images d'un format donné, prises dans un pool (IOSurface), et y copie des images d'un autre
/// format (`VTPixelTransferSession`, conversion de couleurs comprise).
///
/// Sert aux processeurs de VideoToolbox, qui ont leurs formats et leurs exigences (alignement, cache) : leurs
/// images sources et de destination sont toujours prises ici, même quand le format est celui du décodeur.
final class PixelBufferConverter {
    /// Format des images fabriquées.
    let format: OSType
    private let pool: CVPixelBufferPool
    private let session: VTPixelTransferSession

    /// `nil` si la taille est nulle ou si le pool ou la session de conversion ne peuvent pas être créés.
    /// - Parameter requirements: exigences d'un processeur (`sourcePixelBufferAttributes`,
    ///   `destinationPixelBufferAttributes`), combinées au format et à la taille demandés.
    init?(format: OSType, width: Int, height: Int, requirements: [String: Any] = [:]) {
        guard width > 0, height > 0 else { return nil }
        let wanted: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var attributes: CFDictionary?
        guard CVPixelBufferCreateResolvedAttributesDictionary(
            nil, [requirements, wanted] as CFArray, &attributes
        ) == kCVReturnSuccess else { return nil }

        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attributes, &pool) == kCVReturnSuccess, let pool else { return nil }
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) == noErr,
              let session
        else { return nil }

        self.format = format
        self.pool = pool
        self.session = session
    }

    deinit {
        VTPixelTransferSessionInvalidate(session)
    }

    /// Image neuve du pool (contenu indéfini).
    func makeBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw FrameProcessingError.bufferCreation(status) }
        return buffer
    }

    /// Libère tout de suite les images du pool qui ne servent plus (sinon gardées une seconde). Une durée de
    /// vie nulle (`kCVPixelBufferPoolMaximumBufferAgeKey` à 0) ne conviendrait pas : elle les garderait toujours.
    func flush() {
        CVPixelBufferPoolFlush(pool, .excessBuffers)
    }

    /// Copie de `buffer` dans ce format.
    ///
    /// Les couleurs (primaires, transfert, matrice YCbCr) de `colors` sont d'abord posées sur `buffer` : la
    /// conversion les suit et les recopie sur la copie. Le retour depuis un processeur, qui rend des images
    /// sans couleurs (VideoToolbox supposerait alors la matrice HD), garde ainsi celles de la source.
    func convert(_ buffer: CVPixelBuffer, colorsFrom colors: CVPixelBuffer) throws -> CVPixelBuffer {
        let copy = try makeBuffer()
        if buffer !== colors { CVBufferPropagateAttachments(colors, buffer) }
        let status = VTPixelTransferSessionTransferImage(session, from: buffer, to: copy)
        guard status == noErr else { throw FrameProcessingError.transfer(status) }
        return copy
    }
}
