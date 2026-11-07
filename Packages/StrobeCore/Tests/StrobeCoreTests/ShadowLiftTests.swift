import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import StrobeCore

/// Image 64×64 420f de luma uniforme `luma` (sur 255), chroma neutre, couleurs BT.709.
private func uniformFrame(luma: UInt8) -> CVPixelBuffer {
    var created: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes, &created
    )
    precondition(status == kCVReturnSuccess, "CVPixelBufferCreate a échoué (\(status))")
    let buffer = created!
    CVPixelBufferLockBaseAddress(buffer, [])
    for plane in 0..<2 {
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
        let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
        memset(base, plane == 0 ? Int32(luma) : 128, bytes)
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    return buffer
}

/// Valeur moyenne (sur 255) du plan `plane` : 0 la luma, 1 la chroma (Cb et Cr entrelacés).
private func mean(of buffer: CVPixelBuffer, plane: Int = 0) -> Double {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt8.self)
    let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
    let width = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
    let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
    var sum = 0
    for row in 0..<height {
        for column in 0..<width { sum += Int(base[row * rowBytes + column]) }
    }
    return Double(sum) / Double(width * height)
}

private func meanLuma(of buffer: CVPixelBuffer) -> Double { mean(of: buffer) }

private struct RenderRefused: Error {}

@Suite("Éclaircissement des scènes sombres")
struct ShadowLiftTests {
    @Test(arguments: [0.3, 0.31, 0.6])
    func sceneThatIsNotDarkIsLeftAsItIs(luma: Double) {
        #expect(ShadowLift.forScene(luma: luma) == .none)
    }

    @Test func darkSceneHasItsShadowsRaisedFirst() {
        // Entre 0,3 (seuil des scènes sombres) et 0,15 : seulement les ombres, de plus en plus.
        let lift = ShadowLift.forScene(luma: 0.2)
        #expect(lift.exposureEV == 0)
        #expect(abs(lift.shadows - 2.0 / 3) < 1e-9)
        #expect(ShadowLift.forScene(luma: 0.15) == ShadowLift(exposureEV: 0, shadows: 1))
    }

    @Test func veryDarkSceneGetsGainUpToFourTimesTheLight() {
        // Sous 0,15 : du gain en lumière linéaire, pour ramener la luma vers 0,15 (gamma 2,2), au plus +2 IL. La pièce
        // noire de l'essai sur iPhone (luma médiane 0,037) prend les +2 IL.
        let lift = ShadowLift.forScene(luma: 0.1)
        #expect(abs(lift.exposureEV - 2.2 * log2(1.5)) < 1e-9)
        #expect(lift.shadows == 1)
        #expect(ShadowLift.forScene(luma: 0.037) == ShadowLift(exposureEV: 2, shadows: 1))
        #expect(ShadowLift.forScene(luma: 0) == ShadowLift(exposureEV: 2, shadows: 1))
    }

    @Test func denoisingGrowsWithTheLift() {
        // Le grain monte avec l'éclaircissement : débruitage de 0,5 (sans éclaircir, comme avant) à 1.
        #expect(ShadowLift.none.denoiseStrength == 0.5)
        #expect(ShadowLift(exposureEV: 0, shadows: 1).denoiseStrength == 0.75)
        #expect(ShadowLift(exposureEV: 2, shadows: 1).denoiseStrength == 1)
    }

    @Test func lifterBrightensADarkFrameAndKeepsItsColors() throws {
        let lifter = try #require(ShadowLifter(lift: ShadowLift(exposureEV: 2, shadows: 1), width: 64, height: 64))
        let dark = uniformFrame(luma: 25)
        let lifted = lifter.apply(to: dark)

        #expect(meanLuma(of: lifted) > 50, "luma \(meanLuma(of: lifted))")
        // Gris en entrée, gris en sortie : la chroma reste neutre (128).
        #expect(abs(mean(of: lifted, plane: 1) - 128) < 3, "chroma \(mean(of: lifted, plane: 1))")
        #expect(CVPixelBufferGetPixelFormatType(lifted) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        #expect(CVPixelBufferGetWidth(lifted) == 64 && CVPixelBufferGetHeight(lifted) == 64)
        for key in [kCVImageBufferYCbCrMatrixKey, kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey] {
            let value = CVBufferCopyAttachment(lifted, key, nil) as? String
            #expect(value == CVBufferCopyAttachment(dark, key, nil) as? String, "\(key)")
        }
    }

    @Test func lifterGoesOnWithTheProcessorWhenTheGPURefuses() throws {
        // Nettoyage poursuivi en arrière-plan sans GPU (iPhone de test) : le rendu Core Image échoue. Le reste de
        // la vidéo est rendu par le processeur, de la même façon, sans alterner images claires et sombres.
        var contexts: [ObjectIdentifier] = []
        let lifter = try #require(ShadowLifter(
            lift: ShadowLift(exposureEV: 2, shadows: 1), width: 64, height: 64,
            render: { image, output, context in
                contexts.append(ObjectIdentifier(context))
                if contexts.count == 1 { throw RenderRefused() }
                try ShadowLifter.render(image, into: output, with: context)
            }
        ))
        let first = lifter.apply(to: uniformFrame(luma: 25))
        let second = lifter.apply(to: uniformFrame(luma: 25))

        #expect(meanLuma(of: first) > 50)
        #expect(meanLuma(of: second) > 50)
        #expect(contexts.count == 3)
        #expect(contexts[0] != contexts[1], "le processeur après le refus du GPU")
        #expect(contexts[1] == contexts[2], "puis le processeur pour la suite")
    }

    @Test func lifterThatRendersBlackGoesOnWithTheProcessor() throws {
        // Le GPU refusé peut aussi « réussir » en rendant du noir : une image éclaircie plus sombre que l'image de
        // départ est un échec, et la suite passe par le processeur.
        var calls = 0
        let lifter = try #require(ShadowLifter(
            lift: ShadowLift(exposureEV: 2, shadows: 1), width: 64, height: 64,
            render: { image, output, context in
                calls += 1
                guard calls > 1 else {
                    try ShadowLifter.render(CIImage(color: .black).cropped(to: image.extent), into: output, with: context)
                    return
                }
                try ShadowLifter.render(image, into: output, with: context)
            }
        ))
        #expect(meanLuma(of: lifter.apply(to: uniformFrame(luma: 25))) > 50)
        #expect(calls == 2)
    }

    @Test func lifterThatCannotRenderLeavesTheFrameAsItIs() throws {
        let lifter = try #require(ShadowLifter(
            lift: ShadowLift(exposureEV: 2, shadows: 1), width: 64, height: 64,
            render: { _, _, _ in throw RenderRefused() }
        ))
        let frame = uniformFrame(luma: 25)
        #expect(lifter.apply(to: frame) === frame)
        #expect(lifter.apply(to: frame) === frame)
    }

    @Test func liftIsSettingAndCoding() throws {
        #expect(CleanerConfig().brightenDarkScenes)
        var config = CleanerConfig()
        config.brightenDarkScenes = false
        #expect(try JSONDecoder().decode(CleanerConfig.self, from: JSONEncoder().encode(config)) == config)
    }
}
