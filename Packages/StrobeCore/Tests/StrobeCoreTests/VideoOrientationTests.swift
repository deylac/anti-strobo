import CoreGraphics
import Testing
@testable import StrobeCore

@Suite("VideoOrientation")
struct VideoOrientationTests {
    // MARK: Quarts de tour

    @Test(arguments: [
        (0.0, 0), (90.0, 1), (180.0, 2), (270.0, 3), (360.0, 0), (450.0, 1),
        (-90.0, 3), (-180.0, 2), (-270.0, 1), (-360.0, 0),
    ])
    func rightAngles(degrees: Double, quarterTurns: Int) {
        #expect(VideoOrientation.quarterTurns(clockwiseDegrees: degrees) == quarterTurns)
    }

    @Test(arguments: [
        (30.0, 0), (60.0, 1), (100.0, 1), (134.0, 1), (136.0, 2), (300.0, 3), (330.0, 0),
        (-30.0, 0), (-60.0, 3), (89.999, 1), (0.001, 0),
    ])
    func otherAnglesGoToTheNearestQuarter(degrees: Double, quarterTurns: Int) {
        #expect(VideoOrientation.quarterTurns(clockwiseDegrees: degrees) == quarterTurns)
    }

    @Test(arguments: [(45.0, 1), (135.0, 2), (225.0, 3), (315.0, 0), (-45.0, 0), (405.0, 1)])
    func halfQuartersGoToTheNextQuarterClockwise(degrees: Double, quarterTurns: Int) {
        #expect(VideoOrientation.quarterTurns(clockwiseDegrees: degrees) == quarterTurns)
    }

    @Test func nonFiniteAngleIsNoRotation() {
        for degrees in [Double.nan, .infinity, -.infinity] {
            #expect(VideoOrientation.quarterTurns(clockwiseDegrees: degrees) == 0)
            #expect(VideoOrientation.preferredTransform(rotatingClockwise: degrees, width: 1920, height: 1080) == .identity)
        }
    }

    // MARK: Transformations

    @Test func matricesForEachQuarterTurn() {
        let width = 1920
        let height = 1080
        #expect(VideoOrientation.preferredTransform(rotatingClockwise: 0, width: width, height: height) == .identity)
        // Comme les films portrait de l'appareil photo : [0 1 -1 0 hauteur 0].
        #expect(VideoOrientation.preferredTransform(rotatingClockwise: 90, width: width, height: height)
            == CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0))
        #expect(VideoOrientation.preferredTransform(rotatingClockwise: 180, width: width, height: height)
            == CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080))
        #expect(VideoOrientation.preferredTransform(rotatingClockwise: 270, width: width, height: height)
            == CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1920))
        // Un angle quelconque prend la transformation de son quart de tour.
        #expect(VideoOrientation.preferredTransform(rotatingClockwise: -80, width: width, height: height)
            == VideoOrientation.preferredTransform(rotatingClockwise: 270, width: width, height: height))
    }

    @Test(arguments: [0.0, 90.0, 180.0, 270.0])
    func transformedImageStartsAtOriginWithSwappedSizeWhenSideways(degrees: Double) {
        let transform = VideoOrientation.preferredTransform(rotatingClockwise: degrees, width: 1920, height: 1080)
        let shown = CGRect(x: 0, y: 0, width: 1920, height: 1080).applying(transform)
        let sideways = Int(degrees) % 180 != 0

        #expect(shown.origin == .zero)
        #expect(shown.size == (sideways ? CGSize(width: 1080, height: 1920) : CGSize(width: 1920, height: 1080)))
    }

    @Test func ninetyDegreesTurnsClockwise() {
        // Repère image (y vers le bas) : le coin haut gauche du capteur passe en haut à droite.
        let transform = VideoOrientation.preferredTransform(rotatingClockwise: 90, width: 1920, height: 1080)
        #expect(CGPoint(x: 0, y: 0).applying(transform) == CGPoint(x: 1080, y: 0))
        #expect(CGPoint(x: 1920, y: 0).applying(transform) == CGPoint(x: 1080, y: 1920))
    }
}
