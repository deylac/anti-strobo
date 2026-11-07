import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import os

private let log = Logger(subsystem: "app.camantistrobo.ios", category: "VideoCleaner")

/// Éclaircissement de la vidéo nettoyée d'une scène sombre (règle V2-R23) : du gain en lumière linéaire, puis les
/// ombres remontées par l'outil local de Core Image (`CIHighlightShadowAdjust`), qui tient les hautes lumières.
///
/// À 120 ou 60 i/s, la pose de chaque image est courte : dans une salle sombre, l'exposition est au maximum et
/// l'image reste noire. Essai sur iPhone du 7 novembre en pièce noire : luma moyenne des bonnes images 0,04 ; avec
/// +2 IL et les ombres remontées, la pièce apparaît (luma moyenne 0,15, la moitié de l'image hors du noir).
public struct ShadowLift: Sendable, Equatable, Codable {
    /// Gain en lumière linéaire, en IL (+1 IL double la lumière).
    public var exposureEV: Double
    /// Part des ombres remontées, de 0 (rien) à 1 (`CIHighlightShadowAdjust.shadowAmount`).
    public var shadows: Double

    /// Aucun éclaircissement.
    public static let none = ShadowLift(exposureEV: 0, shadows: 0)

    /// Gain maximal : au-delà, le grain et les blocs de compression des zones noires dominent.
    static let maxExposureEV = 2.0
    /// Luma de scène sous laquelle les ombres sont remontées en entier et le gain commence.
    static let fullLiftLuma = VideoCleaner.darkSceneLuma / 2
    /// Gamma supposé entre la lumière et la luma, comme `ExposureMeterConfig.gamma`.
    private static let gamma = 2.2

    public init(exposureEV: Double, shadows: Double) {
        self.exposureEV = exposureEV
        self.shadows = shadows
    }

    /// Le réglage d'une scène dont la luma moyenne médiane des bonnes images vaut `luma` :
    /// - à partir de `VideoCleaner.darkSceneLuma` (0,3), scène pas sombre : rien ;
    /// - de 0,3 à `fullLiftLuma` (0,15) : les ombres seulement, de 0 à 1 ;
    /// - sous 0,15 : les ombres en entier, et le gain qui ramènerait la luma à 0,15, `gamma × log2(0,15 / luma)`,
    ///   au plus `maxExposureEV`.
    public static func forScene(luma: Double) -> ShadowLift {
        let dark = VideoCleaner.darkSceneLuma
        guard luma < dark else { return .none }
        let shadows = min(1, (dark - luma) / (dark - fullLiftLuma))
        let exposureEV = luma <= 0 ? maxExposureEV : min(maxExposureEV, max(0, gamma * log2(fullLiftLuma / luma)))
        return ShadowLift(exposureEV: exposureEV, shadows: shadows)
    }

    /// Vrai si le réglage ne change rien.
    public var isNone: Bool { exposureEV == 0 && shadows == 0 }

    /// Force du débruitage d'une scène sombre ainsi éclaircie : le grain monte avec l'éclaircissement. 0,5 sans
    /// éclaircir (comme avant la V2-R23), plus 0,25 par IL de gain et pour les ombres en entier, au plus 1.
    public var denoiseStrength: Float {
        Float(min(1, 0.5 + 0.25 * (exposureEV + shadows)))
    }
}

/// Applique un `ShadowLift` aux images de la vidéo nettoyée (420f, `cleanerFrameFormat`). Les couleurs de l'image
/// (matrice, primaires, transfert) passent à l'image éclaircie.
///
/// Sur le GPU d'abord. Un nettoyage poursuivi en arrière-plan sans le GPU (iPhone qui ne le prête pas aux tâches de
/// fond) voit ses rendus refusés : la suite de la vidéo passe alors par le processeur, plus lent mais pareil, pour
/// ne pas alterner images éclaircies et images sombres. Si le processeur échoue aussi, les images restent telles
/// quelles : l'éclaircissement ne fait jamais échouer le nettoyage.
final class ShadowLifter {
    /// Rendu de `image` dans `output` par `context` ; lève si le rendu échoue.
    typealias Render = (_ image: CIImage, _ output: CVPixelBuffer, _ context: CIContext) throws -> Void

    private let lift: ShadowLift
    private let render: Render
    /// Contextes encore à essayer, dans l'ordre : GPU, puis processeur. Chaque image différente : pas de cache.
    private var contexts = [
        CIContext(options: [.cacheIntermediates: false]),
        CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true]),
    ]
    private let pool: CVPixelBufferPool

    /// `nil` si les images de cette taille ne peuvent pas être préparées.
    /// - Parameter render: rendu d'une image (les tests l'enrobent pour simuler des refus).
    init?(lift: ShadowLift, width: Int, height: Int, render: @escaping Render = ShadowLifter.render) {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: cleanerFrameFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var created: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &created) == kCVReturnSuccess,
              let created
        else { return nil }
        self.lift = lift
        self.render = render
        pool = created
    }

    /// Rendu par défaut, dont l'échec se voit (`CIContext.render(_:to:)` ne dit rien d'un rendu refusé).
    static func render(_ image: CIImage, into output: CVPixelBuffer, with context: CIContext) throws {
        try context.startTask(toRender: image, to: CIRenderDestination(pixelBuffer: output)).waitUntilCompleted()
    }

    /// L'image éclaircie, ou `image` elle-même si l'éclaircissement échoue.
    func apply(to image: CVPixelBuffer) -> CVPixelBuffer {
        var created: CVPixelBuffer?
        guard !contexts.isEmpty,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == kCVReturnSuccess,
              let output = created,
              let result = lifted(CIImage(cvPixelBuffer: image))
        else { return image }
        CVBufferPropagateAttachments(image, output)
        // Un éclaircissement ne rend pas l'image deux fois plus sombre : sinon le rendu a échoué sans le dire (GPU
        // refusé qui rend du noir).
        let floor = LumaSampler.stats(of: image).meanLuma / 2

        while let context = contexts.first {
            do {
                try render(result, output, context)
                guard LumaSampler.stats(of: output).meanLuma >= floor else { throw FrameProcessingError.implausibleResult }
                return output
            } catch {
                contexts.removeFirst()
                log.error("""
                    Éclaircissement refusé (\(String(describing: error), privacy: .public)) : \
                    \(self.contexts.isEmpty ? "images laissées sombres" : "suite au processeur", privacy: .public)
                    """)
            }
        }
        return image
    }

    private func lifted(_ image: CIImage) -> CIImage? {
        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = image
        exposure.ev = Float(lift.exposureEV)
        guard lift.shadows > 0 else { return exposure.outputImage }
        let local = CIFilter.highlightShadowAdjust()
        local.inputImage = exposure.outputImage
        local.shadowAmount = Float(lift.shadows)
        local.highlightAmount = 0.7
        local.radius = 12
        return local.outputImage
    }
}
