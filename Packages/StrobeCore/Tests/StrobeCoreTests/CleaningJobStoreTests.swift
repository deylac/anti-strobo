import Foundation
import Testing
@testable import StrobeCore

// MARK: - Aides

/// Dossier temporaire neuf, qui n'existe pas encore sur le disque ; supprimé à la fin du test.
private struct TempDirectory {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleaningJobStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    var jobsFile: URL { url.appendingPathComponent("jobs.json") }

    func remove() {
        // Un test peut avoir retiré le droit d'écriture : on le rend avant de supprimer.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }

    /// Fichiers `jobs.corrupt-*.json` présents dans le dossier.
    func corruptFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names
            .filter { $0.hasPrefix("jobs.corrupt-") && $0.hasSuffix(".json") }
            .map { url.appendingPathComponent($0) }
    }
}

/// Date entière en secondes : le JSON ISO-8601 ne garde pas les fractions de seconde.
private func date(_ secondsSince1970: TimeInterval) -> Date {
    Date(timeIntervalSince1970: secondsSince1970)
}

private func makeJob(
    _ name: String,
    state: JobState = .recorded,
    cleaned: String? = nil,
    createdAt: Date
) -> CleaningJob {
    CleaningJob(
        id: UUID(),
        originalFile: "\(name).mov",
        cleanedFile: cleaned,
        state: state,
        createdAt: createdAt
    )
}

// MARK: - Tests

@Suite("CleaningJobStore")
struct CleaningJobStoreTests {
    @Test func startsEmptyOnAFreshDirectory() async {
        let dir = TempDirectory()
        defer { dir.remove() }
        let store = CleaningJobStore(directory: dir.url)
        #expect(await store.all().isEmpty)
        #expect(await store.pending().isEmpty)
    }

    @Test func upsertThenAllSurvivesRecreatingTheActor() async throws {
        let dir = TempDirectory()
        defer { dir.remove() }
        let first = makeJob("a", createdAt: date(1_700_000_000))
        let second = makeJob("b", state: .cleaned, cleaned: "b-clean.mov", createdAt: date(1_700_000_100))

        let store = CleaningJobStore(directory: dir.url)
        try await store.upsert(first)
        try await store.upsert(second)
        #expect(await store.all() == [first, second])

        let reopened = CleaningJobStore(directory: dir.url)
        #expect(await reopened.all() == [first, second])
    }

    @Test func upsertReplacesTheJobWithTheSameID() async throws {
        let dir = TempDirectory()
        defer { dir.remove() }
        var job = makeJob("a", createdAt: date(1_700_000_000))
        let store = CleaningJobStore(directory: dir.url)
        try await store.upsert(job)

        job.state = .cleaned
        job.cleanedFile = "a-clean.mov"
        try await store.upsert(job)

        #expect(await store.all() == [job])
        #expect(await CleaningJobStore(directory: dir.url).all() == [job])
    }

    @Test func allIsSortedByCreationDateAscending() async throws {
        let dir = TempDirectory()
        defer { dir.remove() }
        let early = makeJob("early", createdAt: date(1_700_000_000))
        let middle = makeJob("middle", createdAt: date(1_700_000_500))
        let late = makeJob("late", createdAt: date(1_700_001_000))

        let store = CleaningJobStore(directory: dir.url)
        try await store.upsert(late)
        try await store.upsert(early)
        try await store.upsert(middle)

        #expect(await store.all() == [early, middle, late])
        #expect(await CleaningJobStore(directory: dir.url).all() == [early, middle, late])
    }

    @Test func orderSurvivesReloadWhenCreationDatesShareTheSameSecond() async throws {
        // Le JSON ISO-8601 tronque les fractions : après relecture, ces deux dates sont égales.
        let dir = TempDirectory()
        defer { dir.remove() }
        let later = makeJob("later", createdAt: date(1_700_000_000.7))
        let earlier = makeJob("earlier", createdAt: date(1_700_000_000.2))

        let store = CleaningJobStore(directory: dir.url)
        try await store.upsert(later)
        try await store.upsert(earlier)
        #expect(await store.all().map(\.id) == [earlier.id, later.id])

        let reopened = await CleaningJobStore(directory: dir.url).all()
        #expect(reopened.map(\.id) == [earlier.id, later.id])
    }

    @Test func pendingExcludesSavedJobsAndIsSortedByDate() async throws {
        let dir = TempDirectory()
        defer { dir.remove() }
        let saved = makeJob("saved", state: .saved, cleaned: "saved-clean.mov", createdAt: date(1_700_000_000))
        let cleaned = makeJob("cleaned", state: .cleaned, cleaned: "cleaned-clean.mov", createdAt: date(1_700_000_300))
        let recorded = makeJob("recorded", state: .recorded, createdAt: date(1_700_000_200))

        let store = CleaningJobStore(directory: dir.url)
        try await store.upsert(cleaned)
        try await store.upsert(saved)
        try await store.upsert(recorded)

        #expect(await store.pending() == [recorded, cleaned])
        #expect(await store.all() == [saved, recorded, cleaned])
        #expect(await CleaningJobStore(directory: dir.url).pending() == [recorded, cleaned])
    }

    @Test func pendingAlsoExcludesUnusableJobs() async throws {
        let dir = TempDirectory()
        defer { dir.remove() }
        let unusable = makeJob("empty", state: .unusable, createdAt: date(1_700_000_000))
        let recorded = makeJob("recorded", state: .recorded, createdAt: date(1_700_000_100))

        let store = CleaningJobStore(directory: dir.url)
        try await store.upsert(unusable)
        try await store.upsert(recorded)

        #expect(await store.pending() == [recorded])
        #expect(await CleaningJobStore(directory: dir.url).all() == [unusable, recorded])
        let json = try String(contentsOf: dir.jobsFile, encoding: .utf8)
        #expect(json.contains("\"state\":\"unusable\""))
    }

    @Test(arguments: [
        (JobState.recorded, true), (.cleaned, true), (.saved, false), (.unusable, false),
    ])
    func onlyRecordedAndCleanedArePending(_ state: JobState, _ expected: Bool) {
        #expect(state.isPending == expected)
    }

    @Test func removeDeletesTheJobAndPersists() async throws {
        let dir = TempDirectory()
        defer { dir.remove() }
        let keep = makeJob("keep", createdAt: date(1_700_000_000))
        let drop = makeJob("drop", createdAt: date(1_700_000_100))
        let store = CleaningJobStore(directory: dir.url)
        try await store.upsert(keep)
        try await store.upsert(drop)

        try await store.remove(id: drop.id)

        #expect(await store.all() == [keep])
        #expect(await CleaningJobStore(directory: dir.url).all() == [keep])
    }

    @Test func removingAnUnknownIDChangesNothing() async throws {
        let dir = TempDirectory()
        defer { dir.remove() }
        let job = makeJob("a", createdAt: date(1_700_000_000))
        let store = CleaningJobStore(directory: dir.url)
        try await store.upsert(job)

        try await store.remove(id: UUID())

        #expect(await store.all() == [job])
    }

    @Test func createsTheDirectoryIfMissing() async throws {
        let dir = TempDirectory()
        defer { dir.remove() }
        let nested = dir.url.appendingPathComponent("a/b", isDirectory: true)
        let job = makeJob("a", createdAt: date(1_700_000_000))

        let store = CleaningJobStore(directory: nested)
        try await store.upsert(job)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(await CleaningJobStore(directory: nested).all() == [job])
    }

    @Test func writesJobsJSONWithISO8601DatesAndRawStates() async throws {
        let dir = TempDirectory()
        defer { dir.remove() }
        let job = makeJob("a", state: .cleaned, cleaned: "a-clean.mov", createdAt: date(1_700_000_000))
        try await CleaningJobStore(directory: dir.url).upsert(job)

        let data = try Data(contentsOf: dir.jobsFile)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let entry = try #require(json.first)
        #expect(json.count == 1)
        #expect(entry["id"] as? String == job.id.uuidString)
        #expect(entry["originalFile"] as? String == "a.mov")
        #expect(entry["cleanedFile"] as? String == "a-clean.mov")
        #expect(entry["state"] as? String == "cleaned")
        // 1 700 000 000 s après 1970 = 2023-11-14 22:13:20 UTC.
        #expect(entry["createdAt"] as? String == "2023-11-14T22:13:20Z")
    }

    @Test func noTemporaryFileIsLeftBehindByTheAtomicWrite() async throws {
        let dir = TempDirectory()
        defer { dir.remove() }
        let store = CleaningJobStore(directory: dir.url)
        try await store.upsert(makeJob("a", createdAt: date(1_700_000_000)))
        try await store.upsert(makeJob("b", createdAt: date(1_700_000_100)))

        let names = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
        #expect(names == ["jobs.json"])
    }

    // MARK: Fichier illisible

    @Test func unreadableFileIsMovedAsideAndTheStoreStartsEmpty() async throws {
        let dir = TempDirectory()
        defer { dir.remove() }
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        let garbage = Data("{ ceci n'est pas du JSON".utf8)
        try garbage.write(to: dir.jobsFile)

        let store = CleaningJobStore(directory: dir.url)
        #expect(await store.all().isEmpty)

        // Le fichier illisible est conservé tel quel sous un nom `jobs.corrupt-<horodatage>.json`.
        let corrupt = dir.corruptFiles()
        #expect(corrupt.count == 1)
        let moved = try #require(corrupt.first)
        #expect(try Data(contentsOf: moved) == garbage)
        let stamp = moved.lastPathComponent
            .dropFirst("jobs.corrupt-".count)
            .dropLast(".json".count)
        #expect(Int(stamp) != nil)
        #expect(!FileManager.default.fileExists(atPath: dir.jobsFile.path))

        // Le magasin reste utilisable, et le fichier mis de côté n'est pas touché.
        let job = makeJob("a", createdAt: date(1_700_000_000))
        try await store.upsert(job)
        #expect(await CleaningJobStore(directory: dir.url).all() == [job])
        #expect(try Data(contentsOf: moved) == garbage)
    }

    @Test func validJSONWithTheWrongShapeIsAlsoMovedAside() async throws {
        let dir = TempDirectory()
        defer { dir.remove() }
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        let wrongShape = Data(#"{"jobs": []}"#.utf8)
        try wrongShape.write(to: dir.jobsFile)

        #expect(await CleaningJobStore(directory: dir.url).all().isEmpty)
        let moved = try #require(dir.corruptFiles().first)
        #expect(try Data(contentsOf: moved) == wrongShape)
    }

    // MARK: Erreur de lecture (pas une corruption)

    @Test func readErrorIsNotCorruptionAndTheReadIsRetriedLater() async throws {
        let dir = TempDirectory()
        defer { dir.remove() }
        let job = makeJob("a", createdAt: date(1_700_000_000))
        try await CleaningJobStore(directory: dir.url).upsert(job)
        let original = try Data(contentsOf: dir.jobsFile)

        // Le fichier existe et est valide, mais le système refuse de le lire (comme sous protection de données).
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.jobsFile.path)
        let store = CleaningJobStore(directory: dir.url)
        #expect(await store.all().isEmpty)
        #expect(await store.pending().isEmpty)
        await #expect(throws: (any Error).self) {
            try await store.upsert(makeJob("b", createdAt: date(1_700_000_100)))
        }
        await #expect(throws: (any Error).self) {
            try await store.remove(id: job.id)
        }

        // Ni renommé, ni écrasé.
        #expect(dir.corruptFiles().isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.jobsFile.path)
        #expect(try Data(contentsOf: dir.jobsFile) == original)

        // Le résultat vide n'a pas été mémorisé : la lecture suivante voit le vrai contenu.
        #expect(await store.all() == [job])
        let added = makeJob("b", createdAt: date(1_700_000_100))
        try await store.upsert(added)
        #expect(await CleaningJobStore(directory: dir.url).all() == [job, added])
        #expect(dir.corruptFiles().isEmpty)
    }

    @Test func readAllReturnsTheJobsOrAnEmptyListForAFreshDirectory() async throws {
        let dir = TempDirectory()
        defer { dir.remove() }
        let store = CleaningJobStore(directory: dir.url)
        #expect(try await store.readAll().isEmpty)

        let job = makeJob("a", state: .saved, createdAt: date(1_700_000_000))
        try await store.upsert(job)
        #expect(try await store.readAll() == [job])
        #expect(try await CleaningJobStore(directory: dir.url).readAll() == [job])
    }

    @Test func readAllThrowsOnAReadErrorInsteadOfReturningAnEmptyList() async throws {
        let dir = TempDirectory()
        defer { dir.remove() }
        let job = makeJob("a", createdAt: date(1_700_000_000))
        try await CleaningJobStore(directory: dir.url).upsert(job)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.jobsFile.path)
        let store = CleaningJobStore(directory: dir.url)
        await #expect(throws: (any Error).self) {
            try await store.readAll()
        }

        // L'échec n'est pas mémorisé : une fois le fichier lisible, la liste revient.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.jobsFile.path)
        #expect(try await store.readAll() == [job])
        #expect(dir.corruptFiles().isEmpty)
    }

    @Test func jobsFileThatIsADirectoryIsAReadErrorAndIsLeftAlone() async throws {
        let dir = TempDirectory()
        defer { dir.remove() }
        try FileManager.default.createDirectory(at: dir.jobsFile, withIntermediateDirectories: true)
        let inner = dir.jobsFile.appendingPathComponent("inner.txt")
        try Data("à garder".utf8).write(to: inner)

        let store = CleaningJobStore(directory: dir.url)
        #expect(await store.all().isEmpty)
        await #expect(throws: (any Error).self) {
            try await store.upsert(makeJob("a", createdAt: date(1_700_000_000)))
        }

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.jobsFile.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(try Data(contentsOf: inner) == Data("à garder".utf8))
        #expect(dir.corruptFiles().isEmpty)
    }

    @Test func unreadableFileThatCannotBeMovedAsideIsNeverOverwritten() async throws {
        let dir = TempDirectory()
        defer { dir.remove() }
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        let garbage = Data("pas du JSON".utf8)
        try garbage.write(to: dir.jobsFile)
        // Dossier en lecture seule : on ne peut ni renommer le fichier ni en écrire un autre.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.url.path)

        let store = CleaningJobStore(directory: dir.url)
        #expect(await store.all().isEmpty)
        await #expect(throws: (any Error).self) {
            try await store.upsert(makeJob("a", createdAt: date(1_700_000_000)))
        }
        #expect(await store.all().isEmpty)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.url.path)
        #expect(try Data(contentsOf: dir.jobsFile) == garbage)
    }

    @Test func unreadableFileIsNeverOverwrittenEvenWhenTheDirectoryIsWritable() async throws {
        let dir = TempDirectory()
        defer { dir.remove() }
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        let garbage = Data("pas du JSON".utf8)
        try garbage.write(to: dir.jobsFile)
        // Tous les noms `jobs.corrupt-<horodatage>.json` des prochaines secondes sont pris : le renommage échoue,
        // alors que le dossier reste ouvert en écriture.
        let now = Int(Date().timeIntervalSince1970)
        for stamp in (now - 5)...(now + 30) {
            try Data("déjà là".utf8).write(to: dir.url.appendingPathComponent("jobs.corrupt-\(stamp).json"))
        }

        let store = CleaningJobStore(directory: dir.url)
        #expect(await store.all().isEmpty)
        await #expect(throws: (any Error).self) {
            try await store.upsert(makeJob("a", createdAt: date(1_700_000_000)))
        }
        await #expect(throws: (any Error).self) {
            try await store.remove(id: UUID())
        }

        #expect(try Data(contentsOf: dir.jobsFile) == garbage)
    }

    // MARK: Échec d'écriture

    @Test func failedWriteThrowsAndLeavesTheStoreUnchanged() async throws {
        let dir = TempDirectory()
        defer { dir.remove() }
        let kept = makeJob("kept", createdAt: date(1_700_000_000))
        let store = CleaningJobStore(directory: dir.url)
        try await store.upsert(kept)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.url.path)
        let rejected = makeJob("rejected", createdAt: date(1_700_000_100))
        await #expect(throws: (any Error).self) {
            try await store.upsert(rejected)
        }
        await #expect(throws: (any Error).self) {
            try await store.remove(id: kept.id)
        }

        // La mémoire reste alignée sur le disque.
        #expect(await store.all() == [kept])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.url.path)
        #expect(await CleaningJobStore(directory: dir.url).all() == [kept])
    }
}
