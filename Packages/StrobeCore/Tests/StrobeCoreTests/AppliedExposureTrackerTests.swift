import CoreMedia
import Testing
@testable import StrobeCore

// MARK: - Aides

/// Un instant en millisecondes.
private func ms(_ value: Int64) -> CMTime {
    CMTime(value: value, timescale: 1000)
}

/// Exposition lue sur l'appareil au début de la mesure.
private let deviceExposure = Exposure(durationSeconds: 1.0 / 60, iso: 400)
private let first = Exposure(durationSeconds: 1.0 / 120, iso: 800)
private let second = Exposure(durationSeconds: 1.0 / 120, iso: 200)

// MARK: - Tests

@Suite("AppliedExposureTracker")
struct AppliedExposureTrackerTests {
    @Test func framesBeforeFirstCompletionGetTheDeviceExposure() {
        var tracker = AppliedExposureTracker(deviceExposure: deviceExposure)
        #expect(tracker.exposure(at: ms(0)) == deviceExposure)

        tracker.requestApplied(first, syncTime: ms(100))
        #expect(tracker.exposure(at: ms(99)) == deviceExposure)
    }

    @Test func frameExactlyAtSyncTimeGetsTheRequest() {
        var tracker = AppliedExposureTracker(deviceExposure: deviceExposure)
        tracker.requestApplied(first, syncTime: ms(100))

        #expect(tracker.exposure(at: ms(100)) == first)
        #expect(tracker.exposure(at: ms(101)) == first)
        // Une microseconde avant : encore l'exposition d'avant.
        #expect(tracker.exposure(at: CMTime(value: 99_999, timescale: 1_000_000)) == deviceExposure)
    }

    @Test func comparesAcrossTimescalesWithoutRounding() {
        var tracker = AppliedExposureTracker(deviceExposure: deviceExposure)
        // 1/120 s, exprimé en deux échelles différentes : c'est le même instant.
        tracker.requestApplied(first, syncTime: CMTime(value: 1, timescale: 120))

        #expect(tracker.exposure(at: CMTime(value: 1000, timescale: 120_000)) == first)
        #expect(tracker.exposure(at: CMTime(value: 999, timescale: 120_000)) == deviceExposure)
    }

    @Test func framesBetweenTwoRequestsGetTheEarlierOne() {
        var tracker = AppliedExposureTracker(deviceExposure: deviceExposure)
        tracker.requestApplied(first, syncTime: ms(100))
        tracker.requestApplied(second, syncTime: ms(200))

        #expect(tracker.exposure(at: ms(150)) == first)
        #expect(tracker.exposure(at: ms(200)) == second)
        // Seules la dernière demande et la précédente sont gardées : avant la précédente, c'est elle aussi.
        #expect(tracker.exposure(at: ms(50)) == first)
    }

    @Test func sameSyncTimeTwiceKeepsTheNewerRequest() {
        var tracker = AppliedExposureTracker(deviceExposure: deviceExposure)
        tracker.requestApplied(first, syncTime: ms(100))
        tracker.requestApplied(second, syncTime: ms(100))

        #expect(tracker.exposure(at: ms(100)) == second)
        // La précédente reste celle d'avant l'image commune.
        #expect(tracker.exposure(at: ms(99)) == deviceExposure)
    }

    @Test func outOfOrderCompletionIsIgnored() {
        var tracker = AppliedExposureTracker(deviceExposure: deviceExposure)
        tracker.requestApplied(first, syncTime: ms(200))
        tracker.requestApplied(second, syncTime: ms(100))

        #expect(tracker.exposure(at: ms(250)) == first)
        #expect(tracker.exposure(at: ms(150)) == deviceExposure)
    }

    @Test func nonNumericSyncTimeIsIgnored() {
        var tracker = AppliedExposureTracker(deviceExposure: deviceExposure)
        tracker.requestApplied(first, syncTime: .invalid)
        tracker.requestApplied(second, syncTime: .positiveInfinity)

        #expect(tracker.exposure(at: ms(1000)) == deviceExposure)
    }
}
