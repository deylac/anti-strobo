import Foundation
import Testing
@testable import StrobeCore

// MARK: - Aides

/// 1 Go décimal, comme l'affiche iOS : 1 000 000 000 octets.
private let gigabyte = 1_000_000_000.0

/// Débit nominal en 1080p à 120 i/s, arrondi à 2,8 Mo/s (1 Mo = 1 000 000 octets).
private let nominal1080p120 = 2_800_000.0

// MARK: - Tests

@Suite("StorageEstimator")
struct StorageEstimatorTests {
    @Test func tenGigsPerHourAt1080p120() {
        let perHour = StorageEstimator.nominalBytesPerSecond(width: 1920, height: 1080, fps: 120) * 3600
        #expect(perHour > 9 * gigabyte)
        #expect(perHour < 11 * gigabyte)
    }

    @Test func nominalRateIsAbout2Point8MegabytesPerSecondAt1080p120() {
        let rate = StorageEstimator.nominalBytesPerSecond(width: 1920, height: 1080, fps: 120)
        // width × height × fps × 0,09 / 8 = 2 799 360 octets par seconde.
        #expect(abs(rate - 2_799_360) < 1)
    }

    @Test func nominalRateScalesLinearlyWithPixelsAndFPS() {
        let base = StorageEstimator.nominalBytesPerSecond(width: 1920, height: 1080, fps: 60)
        let doubledFPS = StorageEstimator.nominalBytesPerSecond(width: 1920, height: 1080, fps: 120)
        let fourTimesPixels = StorageEstimator.nominalBytesPerSecond(width: 3840, height: 2160, fps: 60)
        #expect(abs(doubledFPS - 2 * base) < 1e-6)
        #expect(abs(fourTimesPixels - 4 * base) < 1e-6)
    }

    // MARK: Copie nettoyée : débit de l'écriture

    /// Débit de la copie nettoyée d'un original 1080p au débit nominal : `max(4 Mbit/s, débit × 30/fps × 1,5)`.
    /// Le débit nominal étant proportionnel à la cadence, la copie pèse autant à 120, 60 et 30 i/s :
    /// 2 799 360 × 0,375 = 1 049 760 o/s. Elle valait 0,375 fois l'original à 120 i/s, mais 0,75 fois à 60 i/s
    /// et 1,5 fois à 30 i/s : l'ancien rapport fixe de 0,4 la sous-estimait d'autant.
    @Test(arguments: [120.0, 60.0, 30.0])
    func cleanedRateFollowsTheWriterRule(fps: Double) {
        let source = StorageEstimator.nominalBytesPerSecond(width: 1920, height: 1080, fps: fps)
        let cleaned = StorageEstimator.cleanedBytesPerSecond(sourceBytesPerSecond: source, sourceFPS: fps)

        #expect(abs(cleaned - 1_049_760) < 1e-6)
        #expect(abs(cleaned - VideoCleaner.outputBitRate(sourceBitRate: source * 8, sourceFPS: fps, outputFPS: 30) / 8) < 1e-6)
        #expect(abs(cleaned / source - 45 / fps) < 1e-12)
    }

    @Test func cleanedRateHasTheWriterFloor() {
        // 2 Mbit/s à 120 i/s donneraient 0,75 Mbit/s : le plancher de 4 Mbit/s (500 000 o/s) l'emporte.
        #expect(VideoCleaner.outputBitRate(sourceBitRate: 2_000_000, sourceFPS: 120, outputFPS: 30) == 4_000_000)
        #expect(StorageEstimator.cleanedBytesPerSecond(sourceBytesPerSecond: 250_000, sourceFPS: 120) == 500_000)
    }

    @Test func unknownSourceRateIsTreatedAs120fpsLikeTheWriter() {
        // L'écriture suppose 120 i/s quand le fichier ne dit pas sa cadence.
        let at120 = StorageEstimator.cleanedBytesPerSecond(sourceBytesPerSecond: 2_800_000, sourceFPS: 120)
        for fps in [0, -30, .nan, .infinity] as [Double] {
            #expect(StorageEstimator.cleanedBytesPerSecond(sourceBytesPerSecond: 2_800_000, sourceFPS: fps) == at120, "cadence \(fps)")
        }
    }

    // MARK: Temps d'enregistrement restant

    /// (13,5 Go − 0,5 Go) / (débit de l'original + débit de sa copie) à 120, 60 et 30 i/s.
    @Test(arguments: [(fps: 120.0, seconds: 13e9 / 3_849_120), (fps: 60.0, seconds: 13e9 / 2_449_440), (fps: 30.0, seconds: 13e9 / 1_749_600)])
    func remainingAccountsForCleanedCopyAndSafety(fps: Double, seconds expected: Double) {
        let seconds = StorageEstimator.remainingRecordingSeconds(
            freeBytes: Int64(13.5 * gigabyte),
            bytesPerSecond: StorageEstimator.nominalBytesPerSecond(width: 1920, height: 1080, fps: fps),
            fps: fps
        )
        #expect(abs(seconds - expected) < 1e-6)
    }

    @Test func remainingAt30fpsIsNoLongerOverestimated() {
        // À 30 i/s, l'ancien rapport (copie = 0,4 × l'original) annonçait 13 Go / (0,7 Mo/s × 1,4) ≈ 3 h 41 ;
        // la copie pesant 1,5 fois l'original, il reste en réalité ≈ 2 h 04.
        let seconds = StorageEstimator.remainingRecordingSeconds(
            freeBytes: Int64(13.5 * gigabyte),
            bytesPerSecond: StorageEstimator.nominalBytesPerSecond(width: 1920, height: 1080, fps: 30),
            fps: 30
        )
        #expect(seconds < 13e9 / (699_840 * 1.4) * 0.6)
    }

    @Test func belowTheSafetyMarginNothingIsLeft() {
        for free in [400_000_000, 500_000_000, -1_000_000] as [Int64] {
            let seconds = StorageEstimator.remainingRecordingSeconds(
                freeBytes: free,
                bytesPerSecond: nominal1080p120,
                fps: 120
            )
            #expect(seconds == 0, "\(free) octets libres")
        }
    }

    @Test func remainingWithoutSafetyMargin() {
        // 10 Mo libres, 1 Mo/s filmé à 30 i/s : copie à 1,5 Mo/s, donc 10 / 2,5 = 4 s.
        let seconds = StorageEstimator.remainingRecordingSeconds(
            freeBytes: 10_000_000,
            bytesPerSecond: 1_000_000,
            fps: 30,
            safetyBytes: 0
        )
        #expect(abs(seconds - 4) < 1e-9)
    }

    @Test func remainingIsZeroForInvalidRate() {
        for rate in [0, -1_000_000, .nan, .infinity, -.infinity] as [Double] {
            let seconds = StorageEstimator.remainingRecordingSeconds(
                freeBytes: 100_000_000_000,
                bytesPerSecond: rate,
                fps: 120
            )
            #expect(seconds == 0, "débit \(rate)")
        }
    }

    @Test func remainingHandlesExtremeFreeBytesWithoutOverflow() {
        // Int64.min − marge dépasserait Int64 : le calcul se fait en flottant.
        let tiny = StorageEstimator.remainingRecordingSeconds(freeBytes: .min, bytesPerSecond: nominal1080p120, fps: 120)
        #expect(tiny == 0)

        let huge = StorageEstimator.remainingRecordingSeconds(freeBytes: .max, bytesPerSecond: nominal1080p120, fps: 120)
        #expect(huge.isFinite)
        #expect(huge > 0)
    }

    // MARK: Copies nettoyées encore dues

    @Test func remainingReservesTheCleanedCopiesStillOwed() {
        // 1 Mo/s à 30 i/s (copie à 1,5 Mo/s), 2 Go libres, 0,5 Go de copies dues : (2 − 0,5) Go / 2,5 Mo/s = 600 s.
        let seconds = StorageEstimator.remainingRecordingSeconds(
            freeBytes: 2_000_000_000,
            bytesPerSecond: 1_000_000,
            fps: 30,
            owedCleanedBytes: 500_000_000,
            safetyBytes: 0
        )
        #expect(abs(seconds - 600) < 1e-9)
    }

    @Test func remainingReservesTheCopyOfTheRecordingInProgress() {
        // 400 Mo déjà filmés à 1 Mo/s et 30 i/s (400 s) : leur copie (1,5 × 400 Mo) est réservée.
        // (2 Go − 0,6 Go) / 2,5 Mo/s = 560 s.
        let seconds = StorageEstimator.remainingRecordingSeconds(
            freeBytes: 2_000_000_000,
            bytesPerSecond: 1_000_000,
            fps: 30,
            recordedBytes: 400_000_000,
            safetyBytes: 0
        )
        #expect(abs(seconds - 560) < 1e-9)
    }

    @Test func remainingIsZeroWhenOwedCopiesTakeAllTheRoom() {
        // 0,5 Go de marge + 0,6 Go de copies dues > 1 Go libre.
        let seconds = StorageEstimator.remainingRecordingSeconds(
            freeBytes: 1_000_000_000,
            bytesPerSecond: nominal1080p120,
            fps: 120,
            owedCleanedBytes: 600_000_000
        )
        #expect(seconds == 0)
    }

    @Test func negativeOwedOrRecordedBytesCountAsNothing() {
        let withNegative = StorageEstimator.remainingRecordingSeconds(
            freeBytes: 10_000_000_000,
            bytesPerSecond: nominal1080p120,
            fps: 120,
            recordedBytes: -1_000_000,
            owedCleanedBytes: -5_000_000_000
        )
        let withNothing = StorageEstimator.remainingRecordingSeconds(
            freeBytes: 10_000_000_000,
            bytesPerSecond: nominal1080p120,
            fps: 120
        )
        #expect(withNegative == withNothing)
    }

    // MARK: Place pour nettoyer

    @Test func roomToCleanNeedsTheCleanedCopyPlusTheSafetyMargin() {
        // Copie estimée de 0,4 Go + 0,5 Go de marge = 0,9 Go, borne comprise.
        #expect(StorageEstimator.hasRoomToClean(cleanedBytes: 400_000_000, freeBytes: 900_000_000))
        #expect(!StorageEstimator.hasRoomToClean(cleanedBytes: 400_000_000, freeBytes: 899_999_999))
        // Marge explicite.
        #expect(StorageEstimator.hasRoomToClean(cleanedBytes: 1_000_000_000, freeBytes: 1_000_000_000, safetyBytes: 0))
        #expect(!StorageEstimator.hasRoomToClean(cleanedBytes: 1_000_000_000, freeBytes: 999_999_999, safetyBytes: 0))
        // Sous la marge de sécurité, même une copie vide (ou une taille négative) ne se nettoie pas.
        #expect(!StorageEstimator.hasRoomToClean(cleanedBytes: 0, freeBytes: 499_999_999))
        #expect(!StorageEstimator.hasRoomToClean(cleanedBytes: -1, freeBytes: 499_999_999))
    }

    /// Une minute filmée en 1080p au débit nominal : la copie pèse ≈ 63 Mo à 120, 60 et 30 i/s. Avec l'ancien
    /// rapport, à 30 i/s, on n'en réservait que 17.
    @Test(arguments: [120.0, 60.0, 30.0])
    func cleanedCopyOfAMinuteWeighsTheSameAtEveryCadence(fps: Double) {
        let rate = StorageEstimator.nominalBytesPerSecond(width: 1920, height: 1080, fps: fps)
        let copy = StorageEstimator.cleanedBytesPerSecond(sourceBytesPerSecond: rate, sourceFPS: fps) * 60
        #expect(abs(copy - 62_985_600) < 1e-3)
        #expect(StorageEstimator.hasRoomToClean(cleanedBytes: Int64(copy), freeBytes: 562_985_600))
        #expect(!StorageEstimator.hasRoomToClean(cleanedBytes: Int64(copy), freeBytes: 562_985_599))
    }
}
