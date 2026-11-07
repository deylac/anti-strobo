import Foundation
import Testing
@testable import StrobeCore

// MARK: - Aides

private let someExposure = Exposure(durationSeconds: 1.0 / 240.0, iso: 400)

// MARK: - Tests

@Suite("StatusText")
struct StatusTextTests {
    // MARK: Mesure

    @Test func measuringShowsRemainingSeconds() {
        #expect(StatusText.measurement(.measuring(progress: 0.3, secondsRemaining: 12)) == "Mesure de la lumière… 12 s")
        #expect(StatusText.measurement(.measuring(progress: 0.9, secondsRemaining: 1)) == "Mesure de la lumière… 1 s")
    }

    @Test func nothingMeasuredYetShowsNoCountdown() {
        // État de départ (aucune image encore mesurée) : le délai maximal n'est pas une estimation.
        #expect(StatusText.measurement(.measuring(progress: 0, secondsRemaining: 10)) == "Mesure de la lumière…")
        #expect(StatusText.measurement(.measuring(progress: 0, secondsRemaining: 3)) == "Mesure de la lumière…")
        // Dès que la mesure avance, le compte à rebours s'affiche.
        #expect(StatusText.measurement(.measuring(progress: 0.01, secondsRemaining: 10)) == "Mesure de la lumière… 10 s")
    }

    @Test func readyExposure() {
        #expect(StatusText.measurement(.ready(someExposure)) == "Exposition prête")
    }

    @Test func notEnoughGoodFramesFailure() {
        let text = StatusText.measurement(.failed(.notEnoughGoodFrames, best: someExposure))
        #expect(text == "Trop de flashs pour mesurer. Touche l'écran pour réessayer.")
    }

    @Test func tooDarkFailure() {
        let text = StatusText.measurement(.failed(.tooDark, best: someExposure))
        #expect(text == "Scène très sombre : l'image sera sombre. Touche l'écran pour réessayer.")
    }

    // MARK: Temps restant

    @Test(arguments: [
        (8100.0, "≈ 2 h 15 min restantes"),
        (2700.0, "≈ 45 min restantes"),
        (30.0, "Moins d'1 min restante"),
    ])
    func remainingExamplesFromTheSpec(seconds: Double, expected: String) {
        #expect(StatusText.remaining(seconds: seconds) == expected)
    }

    @Test(arguments: [
        // Moins d'une minute, bornes comprises.
        (0.0, "Moins d'1 min restante"),
        (59.9, "Moins d'1 min restante"),
        // Une minute : singulier.
        (60.0, "≈ 1 min restante"),
        (119.9, "≈ 1 min restante"),
        // De 2 à 59 minutes : pluriel, minutes arrondies à l'entier inférieur.
        (120.0, "≈ 2 min restantes"),
        (3539.0, "≈ 58 min restantes"),
        (3540.0, "≈ 59 min restantes"),
        (3599.0, "≈ 59 min restantes"),
        // À partir d'une heure : heures et minutes, sans zéro de remplissage.
        (3600.0, "≈ 1 h restante"),
        (3660.0, "≈ 1 h 1 min restantes"),
        (3840.0, "≈ 1 h 4 min restantes"),
        (7200.0, "≈ 2 h restantes"),
        (7260.0, "≈ 2 h 1 min restantes"),
        (36_000.0, "≈ 10 h restantes"),
    ])
    func remainingBoundaries(seconds: Double, expected: String) {
        #expect(StatusText.remaining(seconds: seconds) == expected)
    }

    @Test(arguments: [-1.0, -3600.0, -Double.infinity, Double.infinity, Double.nan])
    func remainingInvalidInputFallsBackToLessThanOneMinute(seconds: Double) {
        #expect(StatusText.remaining(seconds: seconds) == "Moins d'1 min restante")
    }

    @Test func remainingDoesNotTrapOnHugeDurations() {
        let text = StatusText.remaining(seconds: Double.greatestFiniteMagnitude)
        #expect(text.hasPrefix("≈ "))
        #expect(text.hasSuffix(" restantes"))
    }

    // MARK: Chaleur

    @Test func thermalSeriousAndCritical() {
        #expect(StatusText.thermal(.serious) == "L'iPhone chauffe")
        #expect(StatusText.thermal(.critical) == "L'iPhone est très chaud : il peut couper la caméra")
    }

    @Test func thermalNominalAndFairShowNothing() {
        #expect(StatusText.thermal(.nominal) == nil)
        #expect(StatusText.thermal(.fair) == nil)
    }

    // MARK: Nettoyage

    @Test func processingShowsPercentage() {
        #expect(StatusText.processing(progress: 0.42) == "Nettoyage de la vidéo… 42 %")
    }

    @Test(arguments: [
        (0.0, "Nettoyage de la vidéo… 0 %"),
        (0.999, "Nettoyage de la vidéo… 99 %"),
        (1.0, "Nettoyage de la vidéo… 100 %"),
        // Hors bornes : ramené dans 0…100.
        (1.5, "Nettoyage de la vidéo… 100 %"),
        (1e308, "Nettoyage de la vidéo… 100 %"),
        (-0.2, "Nettoyage de la vidéo… 0 %"),
        // Non fini : 0.
        (Double.nan, "Nettoyage de la vidéo… 0 %"),
        (Double.infinity, "Nettoyage de la vidéo… 0 %"),
        (-Double.infinity, "Nettoyage de la vidéo… 0 %"),
        // Pas de pourcentage en moins à cause de l'erreur d'arrondi : 0,57 × 100 vaut 56,99999999999999.
        (0.57, "Nettoyage de la vidéo… 57 %"),
        (0.29, "Nettoyage de la vidéo… 29 %"),
    ])
    func processingBoundaries(progress: Double, expected: String) {
        #expect(StatusText.processing(progress: progress) == expected)
    }

    // MARK: Fin et confirmation

    @Test func doneMessage() {
        #expect(StatusText.done == "Les deux vidéos sont dans ta pellicule")
    }

    @Test func unreliableReferenceConfirmation() {
        #expect(StatusText.unreliableReferenceConfirm == "La mesure n'est pas fiable. Filmer quand même ?")
    }

    // MARK: Écran caméra

    @Test func cameraProblems() {
        #expect(StatusText.cameraDenied == "Autorise la caméra dans Réglages pour filmer.")
        #expect(StatusText.cameraStopped == "La caméra s'est arrêtée. Relance l'app.")
        #expect(StatusText.referenceLockFailed == "Réglage impossible. Touche l'écran pour réessayer.")
    }

    @Test func cameraPaused() {
        #expect(StatusText.cameraPaused == "Caméra en pause")
    }

    @Test func buttons() {
        #expect(StatusText.record == "Filmer")
        #expect(StatusText.stop == "Arrêter")
        #expect(StatusText.cancel == "Annuler")
        #expect(StatusText.resumeCleaning == "Reprendre le nettoyage")
    }

    @Test func photosNotDeterminedNamesTheResumeButton() {
        #expect(StatusText.photosNotDetermined.contains("« \(StatusText.resumeCleaning) »"))
    }

    @Test(arguments: [
        // Moins d'une heure : minutes et secondes sur deux chiffres, secondes arrondies à l'entier inférieur.
        (0.0, "00:00"),
        (0.9, "00:00"),
        (5.0, "00:05"),
        (59.9, "00:59"),
        (60.0, "01:00"),
        (754.0, "12:34"),
        (3599.9, "59:59"),
        // À partir d'une heure : heures sans zéro de remplissage.
        (3600.0, "1:00:00"),
        (3661.0, "1:01:01"),
        (7325.0, "2:02:05"),
        (36_000.0, "10:00:00"),
    ])
    func elapsedRecordingTime(seconds: Double, expected: String) {
        #expect(StatusText.elapsed(seconds: seconds) == expected)
    }

    @Test(arguments: [-1.0, -3600.0, -Double.infinity, Double.infinity, Double.nan])
    func elapsedInvalidInputIsZero(seconds: Double) {
        #expect(StatusText.elapsed(seconds: seconds) == "00:00")
    }

    @Test func elapsedDoesNotTrapOnHugeDurations() {
        let text = StatusText.elapsed(seconds: Double.greatestFiniteMagnitude)
        #expect(text.split(separator: ":").count == 3)
    }

    @Test(arguments: [
        (Float(1.0), "Batterie 100 %"),
        (Float(0.8), "Batterie 80 %"),
        // Arrondi au pourcentage le plus proche : 0,57 en Float vaut 0,569999…
        (Float(0.57), "Batterie 57 %"),
        (Float(0.05), "Batterie 5 %"),
        (Float(0.0), "Batterie 0 %"),
        // Hors bornes : ramené à 100 %.
        (Float(1.2), "Batterie 100 %"),
    ])
    func batteryLevel(level: Float, expected: String) {
        #expect(StatusText.battery(level: level) == expected)
    }

    @Test(arguments: [Float(-1), Float.nan, Float.infinity, -Float.infinity])
    func unknownBatteryLevelShowsNothing(level: Float) {
        // `UIDevice.batteryLevel` vaut -1 quand le niveau est inconnu (simulateur, suivi désactivé).
        #expect(StatusText.battery(level: level) == nil)
    }

    // MARK: Nettoyage en arrière-plan

    @Test func backgroundTaskTitleAndSubtitle() {
        #expect(StatusText.backgroundTaskTitle == "Nettoyage de la vidéo")
        #expect(StatusText.backgroundTaskSubtitle == "Retrait des flashs, puis rangement dans ta pellicule")
    }

    @Test func cancelledCleaningIsAnInterruption() {
        #expect(StatusText.cleaningError(CancellationError()) == "Nettoyage interrompu : ta vidéo originale est gardée.")
    }

    @Test(arguments: [VideoCleanerError.noVideoTrack, .noVideoFrames])
    func videoWithoutFramesCannotBeCleaned(_ error: VideoCleanerError) {
        #expect(StatusText.cleaningError(error) == "Cette vidéo ne peut pas être nettoyée : l'original est gardé.")
    }

    @Test(arguments: [
        VideoCleanerError.sourceChanged, .unorderedFrames, .readFailed, .writeFailed, .outputIsInput,
    ])
    func otherCleanerErrorsAreAFailureWorthRetrying(_ error: VideoCleanerError) {
        #expect(StatusText.cleaningError(error) == "Le nettoyage a échoué : ta vidéo originale est gardée.")
    }

    @Test func foreignErrorsAreAFailureWorthRetrying() {
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11800)
        #expect(StatusText.cleaningError(error) == "Le nettoyage a échoué : ta vidéo originale est gardée.")
    }

    @Test func photosMessages() {
        #expect(StatusText.photosDenied == "Autorise l'accès à Photos dans Réglages pour y ranger tes vidéos.")
        #expect(StatusText.photosSaveFailed == "Impossible de ranger les vidéos dans ta pellicule : elles restent dans l'app.")
    }

    @Test func cleaningCouldNotStart() {
        #expect(StatusText.cleaningNotStarted == "Le nettoyage n'a pas pu démarrer : ta vidéo originale est gardée.")
    }

    @Test func photosNotAnsweredYetIsNeutral() {
        #expect(
            StatusText.photosNotDetermined
                == "Il reste à ranger tes vidéos dans Photos : touche « Reprendre le nettoyage »."
        )
    }

    @Test func originalSavedAloneAfterAPermanentFailure() {
        #expect(
            StatusText.originalSavedAlone
                == "Cette vidéo n'a pas pu être nettoyée : l'original est dans ta pellicule."
        )
    }

    @Test func cleaningWaitsForTheIPhoneToCoolDown() {
        #expect(StatusText.cleaningPausedForHeat == "Nettoyage en pause le temps que l'iPhone refroidisse.")
    }

    @Test func notEnoughSpaceToCleanNamesTheResumeButton() {
        #expect(
            StatusText.notEnoughSpaceToClean
                == "Plus assez de place pour nettoyer tes vidéos : libère de l'espace puis touche « Reprendre le nettoyage »."
        )
    }

    @Test func stringsUseOnlyPlainSpacesAndAsciiApostrophes() {
        let texts: [String] = [
            StatusText.measurement(.measuring(progress: 0.1, secondsRemaining: 5)),
            StatusText.measurement(.measuring(progress: 0, secondsRemaining: 10)),
            StatusText.measurement(.ready(someExposure)),
            StatusText.measurement(.failed(.notEnoughGoodFrames, best: someExposure)),
            StatusText.measurement(.failed(.tooDark, best: someExposure)),
            StatusText.remaining(seconds: 8100),
            StatusText.remaining(seconds: 30),
            StatusText.thermal(.serious) ?? "",
            StatusText.thermal(.critical) ?? "",
            StatusText.processing(progress: 0.42),
            StatusText.done,
            StatusText.unreliableReferenceConfirm,
            StatusText.backgroundTaskTitle,
            StatusText.backgroundTaskSubtitle,
            StatusText.cleaningError(CancellationError()),
            StatusText.cleaningError(VideoCleanerError.noVideoFrames),
            StatusText.cleaningError(VideoCleanerError.writeFailed),
            StatusText.photosDenied,
            StatusText.photosSaveFailed,
            StatusText.cleaningNotStarted,
            StatusText.photosNotDetermined,
            StatusText.originalSavedAlone,
            StatusText.notEnoughSpaceToClean,
            StatusText.cleaningPausedForHeat,
            StatusText.cameraPaused,
            StatusText.cameraDenied,
            StatusText.cameraStopped,
            StatusText.referenceLockFailed,
            StatusText.record,
            StatusText.stop,
            StatusText.cancel,
            StatusText.resumeCleaning,
            StatusText.elapsed(seconds: 3661),
            StatusText.battery(level: 0.8) ?? "",
        ]
        // Espace insécable, espace fine insécable, apostrophe typographique.
        let forbidden: Set<Unicode.Scalar> = ["\u{00A0}", "\u{202F}", "\u{2019}"]
        for text in texts {
            #expect(!text.unicodeScalars.contains(where: forbidden.contains), "Caractère typographique dans : \(text)")
        }
    }
}
