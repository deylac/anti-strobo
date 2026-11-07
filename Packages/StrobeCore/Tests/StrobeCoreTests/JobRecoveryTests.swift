import Foundation
import Testing
@testable import StrobeCore

// MARK: - Aides

/// Moment du lancement de l'app dans ces tests.
private let launch = Date(timeIntervalSince1970: 1_700_000_000)
/// Avant le lancement : fichier laissé par une exécution précédente.
private let beforeLaunch = launch.addingTimeInterval(-3600)
/// Depuis le lancement : fichier créé par l'app en cours (enregistrement en cours, par exemple).
private let sinceLaunch = launch.addingTimeInterval(5)

private func file(_ name: String, createdAt: Date? = beforeLaunch) -> RecordingFile {
    RecordingFile(name: name, createdAt: createdAt)
}

private func job(
    _ original: String,
    state: JobState = .recorded,
    cleaned: String? = nil,
    createdAt: Date = beforeLaunch
) -> CleaningJob {
    CleaningJob(id: UUID(), originalFile: original, cleanedFile: cleaned, state: state, createdAt: createdAt)
}

private func plan(
    jobs: [CleaningJob] = [],
    files: [RecordingFile] = [],
    busy: Set<UUID> = []
) -> RecoveryPlan {
    JobRecovery.plan(jobs: jobs, files: files, launchedAt: launch, busy: busy)
}

// MARK: - Tests

@Suite("JobRecovery")
struct JobRecoveryTests {
    // MARK: Nom du fichier nettoyé

    @Test func cleanedFileNameAddsCleanSuffixBeforeTheExtension() {
        #expect(JobRecovery.cleanedFileName(forOriginal: "4F2A.mov") == "4F2A-clean.mov")
        #expect(JobRecovery.cleanedFileName(forOriginal: "sans-extension") == "sans-extension-clean.mov")
    }

    // MARK: Enregistrements orphelins

    @Test func adoptsARecordingWithoutJobAsRecorded() {
        let result = plan(files: [file("A.mov", createdAt: beforeLaunch)])

        #expect(result.adopt.count == 1)
        let adopted = result.adopt[0]
        #expect(adopted.originalFile == "A.mov")
        #expect(adopted.cleanedFile == nil)
        #expect(adopted.state == .recorded)
        #expect(adopted.createdAt == beforeLaunch)
        #expect(result.update.isEmpty)
        #expect(result.remove.isEmpty)
        #expect(result.deleteFiles.isEmpty)
    }

    @Test func doesNotAdoptFilesReferencedByAJob() {
        let jobs = [
            job("A.mov"),
            job("B.mov", state: .cleaned, cleaned: "B-clean.mov"),
        ]
        let files = [file("A.mov"), file("B.mov"), file("B-clean.mov")]
        #expect(plan(jobs: jobs, files: files).adopt.isEmpty)
    }

    @Test func doesNotAdoptCleanedOutputsPartialFilesOrOtherFiles() {
        let files = [
            file("X-clean.mov"),
            file("X-clean.mov.partial"),
            file("jobs.json"),
            file("notes.txt"),
            file(".cache.mov"),
        ]
        #expect(plan(files: files).adopt.isEmpty)
    }

    @Test func doesNotAdoptFilesCreatedSinceLaunchOrOfUnknownDate() {
        // Un fichier créé depuis le lancement peut être l'enregistrement en cours : il a déjà son propriétaire.
        let files = [
            file("now.mov", createdAt: sinceLaunch),
            file("atLaunch.mov", createdAt: launch),
            file("unknown.mov", createdAt: nil),
        ]
        #expect(plan(files: files).adopt.isEmpty)
    }

    @Test func adoptionsAreSortedByCreationDateWithDistinctIDs() {
        let files = [
            file("late.mov", createdAt: beforeLaunch.addingTimeInterval(60)),
            file("early.mov", createdAt: beforeLaunch),
        ]
        let adopted = plan(files: files).adopt
        #expect(adopted.map(\.originalFile) == ["early.mov", "late.mov"])
        #expect(Set(adopted.map(\.id)).count == 2)
    }

    @Test func filesOfBusyJobsAreNotAdopted() {
        let running = job("A.mov")
        let result = plan(jobs: [running], files: [file("A.mov")], busy: [running.id])
        #expect(result.adopt.isEmpty)
    }

    // MARK: Travaux sains

    @Test func healthyPendingJobsAreLeftAlone() {
        let jobs = [
            job("A.mov"),
            job("B.mov", state: .cleaned, cleaned: "B-clean.mov"),
        ]
        let files = [file("A.mov"), file("A-clean.mov.partial"), file("B.mov"), file("B-clean.mov")]
        #expect(plan(jobs: jobs, files: files) == RecoveryPlan())
    }

    // MARK: Travaux terminés

    @Test func savedJobLeftoversAreDeletedCleanedFirstAndTheJobIsKeptMeanwhile() {
        // Les deux vidéos sont déjà dans Photos : les copies locales peuvent partir. Le travail reste tant qu'elles
        // existent : retiré trop tôt, un original dont la suppression a échoué deviendrait un orphelin à réadopter.
        let saved = job("A.mov", state: .saved, cleaned: "A-clean.mov")
        let result = plan(jobs: [saved], files: [file("A.mov"), file("A-clean.mov")])

        #expect(result.deleteFiles == ["A-clean.mov", "A.mov"])
        #expect(result.remove.isEmpty)
        #expect(result.adopt.isEmpty)
        #expect(result.update.isEmpty)

        let originalOnly = plan(jobs: [saved], files: [file("A.mov")])
        #expect(originalOnly.deleteFiles == ["A.mov"])
        #expect(originalOnly.remove.isEmpty)
    }

    @Test func savedJobWithoutFilesIsOnlyRemoved() {
        let saved = job("A.mov", state: .saved, cleaned: "A-clean.mov")
        let result = plan(jobs: [saved], files: [])
        #expect(result.deleteFiles.isEmpty)
        #expect(result.remove == [saved.id])
    }

    // MARK: Travaux dont les fichiers ont disparu

    @Test func recordedJobWhoseOriginalIsGoneIsRemoved() {
        let ghost = job("A.mov")
        let result = plan(jobs: [ghost], files: [])
        #expect(result.remove == [ghost.id])
        #expect(result.deleteFiles.isEmpty)
    }

    @Test func cleanedJobWhoseOriginalIsGoneIsRemovedAndItsCleanedFileKept() {
        // Rien ne prouve que la copie nettoyée est dans Photos : on ne la supprime pas.
        let orphanedClean = job("A.mov", state: .cleaned, cleaned: "A-clean.mov")
        let result = plan(jobs: [orphanedClean], files: [file("A-clean.mov")])
        #expect(result.remove == [orphanedClean.id])
        #expect(result.deleteFiles.isEmpty)
        #expect(result.adopt.isEmpty)
    }

    @Test func cleanedJobWhoseCleanedFileIsGoneIsCleanedAgain() {
        let lostClean = job("A.mov", state: .cleaned, cleaned: "A-clean.mov")
        let noName = job("B.mov", state: .cleaned, cleaned: nil)
        let result = plan(jobs: [lostClean, noName], files: [file("A.mov"), file("B.mov")])

        var expectedA = lostClean
        expectedA.state = .recorded
        expectedA.cleanedFile = nil
        var expectedB = noName
        expectedB.state = .recorded
        #expect(result.update == [expectedA, expectedB])
        #expect(result.remove.isEmpty)
        #expect(result.adopt.isEmpty)
    }

    // MARK: Originaux inutilisables

    @Test func unusableJobKeepsItsFileAndIsNeverRetriedNorAdopted() {
        // Original sans piste vidéo : gardé dans l'app, ni nettoyé, ni rangé, ni réadopté.
        let unusable = job("A.mov", state: .unusable)
        #expect(plan(jobs: [unusable], files: [file("A.mov")]) == RecoveryPlan())
    }

    @Test func unusableJobWhoseFileIsGoneIsRemoved() {
        let unusable = job("A.mov", state: .unusable)
        let result = plan(jobs: [unusable], files: [])
        #expect(result.remove == [unusable.id])
        #expect(result.deleteFiles.isEmpty)
    }

    // MARK: Travaux en cours

    @Test func busyJobsAreNeverTouched() {
        let saved = job("A.mov", state: .saved, cleaned: "A-clean.mov")
        let ghost = job("B.mov")
        let lostClean = job("C.mov", state: .cleaned, cleaned: "C-clean.mov")
        let result = plan(
            jobs: [saved, ghost, lostClean],
            files: [file("A.mov"), file("A-clean.mov"), file("C.mov")],
            busy: [saved.id, ghost.id, lostClean.id]
        )
        #expect(result == RecoveryPlan())
    }
}
