import CoreVideo
import Testing
@testable import StrobeCore

/// Construit un `CVPixelBuffer` 64×64 dont le plan de luma est rempli ligne par ligne.
private func makeBiPlanarBuffer(
    format: OSType,
    size: Int = 64,
    lumaForRow: (Int) -> UInt8
) -> CVPixelBuffer {
    var created: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, size, size, format, nil, &created)
    precondition(status == kCVReturnSuccess, "CVPixelBufferCreate a échoué (\(status))")
    let buffer = created!

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, 0) {
        let value = lumaForRow(row)
        for column in 0..<CVPixelBufferGetWidthOfPlane(buffer, 0) {
            yBase[row * yStride + column] = value
        }
    }

    // Chroma neutre : ne doit avoir aucune influence sur la mesure.
    let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
    let cStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
    for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) {
        for byte in 0..<cStride {
            cBase[row * cStride + byte] = 128
        }
    }
    return buffer
}

/// Construit un `CVPixelBuffer` 64×64 en BGRA rempli d'une couleur unie.
private func makeBGRABuffer(size: Int = 64, blue: UInt8, green: UInt8, red: UInt8) -> CVPixelBuffer {
    var created: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA, nil, &created)
    precondition(status == kCVReturnSuccess, "CVPixelBufferCreate a échoué (\(status))")
    let buffer = created!

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for row in 0..<CVPixelBufferGetHeight(buffer) {
        for column in 0..<CVPixelBufferGetWidth(buffer) {
            let offset = row * stride + column * 4
            base[offset] = blue
            base[offset + 1] = green
            base[offset + 2] = red
            base[offset + 3] = 255
        }
    }
    return buffer
}

@Suite("FrameStats")
struct FrameStatsTests {
    @Test func uniformGray() {
        let buffer = makeBiPlanarBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) { _ in 128 }
        let stats = LumaSampler.stats(of: buffer)
        #expect(abs(stats.meanLuma - 128.0 / 255.0) <= 0.005)
        #expect(stats.saturatedFraction == 0)
    }

    @Test func fullyBlown() {
        let buffer = makeBiPlanarBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) { _ in 255 }
        let stats = LumaSampler.stats(of: buffer)
        #expect(abs(stats.meanLuma - 1) <= 0.005)
        #expect(stats.saturatedFraction == 1)
    }

    @Test func halfBlown() {
        let buffer = makeBiPlanarBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) { row in
            row < 32 ? 255 : 20
        }
        let stats = LumaSampler.stats(of: buffer)
        #expect(abs(stats.saturatedFraction - 0.5) <= 0.05)
    }

    @Test func videoRangeNormalized() {
        let white = makeBiPlanarBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) { _ in 235 }
        let whiteStats = LumaSampler.stats(of: white)
        #expect(abs(whiteStats.meanLuma - 1) <= 0.005)
        #expect(whiteStats.saturatedFraction == 1)

        let black = makeBiPlanarBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) { _ in 16 }
        let blackStats = LumaSampler.stats(of: black)
        #expect(abs(blackStats.meanLuma) <= 0.005)
        #expect(blackStats.saturatedFraction == 0)
    }

    @Test func videoRangeClampsOutOfRangeValues() {
        // Sous le noir (Y < 16) et au-dessus du blanc (Y > 235) : borné à 0…1.
        let below = makeBiPlanarBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) { _ in 0 }
        #expect(LumaSampler.stats(of: below).meanLuma == 0)

        let above = makeBiPlanarBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) { _ in 255 }
        let aboveStats = LumaSampler.stats(of: above)
        #expect(aboveStats.meanLuma == 1)
        #expect(aboveStats.saturatedFraction == 1)
    }

    @Test func bgraUsesRec709Luma() {
        let white = LumaSampler.stats(of: makeBGRABuffer(blue: 255, green: 255, red: 255))
        #expect(abs(white.meanLuma - 1) <= 0.005)
        #expect(white.saturatedFraction == 1)

        let black = LumaSampler.stats(of: makeBGRABuffer(blue: 0, green: 0, red: 0))
        #expect(black.meanLuma == 0)
        #expect(black.saturatedFraction == 0)

        // Rec.709 : Y = 0,2126 R + 0,7152 G + 0,0722 B
        let green = LumaSampler.stats(of: makeBGRABuffer(blue: 0, green: 255, red: 0))
        #expect(abs(green.meanLuma - 0.7152) <= 0.005)
        let blue = LumaSampler.stats(of: makeBGRABuffer(blue: 255, green: 0, red: 0))
        #expect(abs(blue.meanLuma - 0.0722) <= 0.005)
        #expect(blue.saturatedFraction == 0)
    }

    @Test func nonPositiveStepFallsBackToEveryPixel() {
        let buffer = makeBiPlanarBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) { _ in 255 }
        #expect(LumaSampler.stats(of: buffer, step: 0).saturatedFraction == 1)
        #expect(LumaSampler.stats(of: buffer, step: -3).saturatedFraction == 1)
    }

    @Test func codableRoundTrip() throws {
        let original = FrameStats(meanLuma: 0.25, saturatedFraction: 0.1)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(FrameStats.self, from: data) == original)
    }
}
