import Foundation
import Testing
@testable import StrobeCore

// MARK: - Aides

private let a = UUID()
private let b = UUID()
private let c = UUID()

/// Nombre d'ordres « terminer la tâche de fond » dans une suite d'actions.
private func completions(_ actions: [CleaningScheduleAction]) -> Int {
    actions.count { if case .completeLease = $0 { true } else { false } }
}

// MARK: - Tests

@Suite("CleaningSchedule")
struct CleaningScheduleTests {
    // MARK: Ajout de travaux

    @Test func enqueueWhileIdleSubmitsOneLeaseAndStartsTheFirstJob() {
        var schedule = CleaningSchedule()
        let actions = schedule.enqueue([a, b])

        #expect(actions == [.submitLease(token: 1, firstJob: a), .start(a)])
        #expect(schedule.current == a)
        #expect(schedule.queue == [b])
        #expect(schedule.busy == [a, b])
        #expect(schedule.lease == CleaningSchedule.Lease(token: 1, isAttached: false))
        #expect(schedule.totalUnits == 200)
        #expect(schedule.completedUnits == 0)
        #expect(schedule.currentProgress == 0)
    }

    @Test func enqueueWhileALeaseIsOutstandingExtendsItsUnitsWithoutANewRequest() {
        var schedule = CleaningSchedule()
        _ = schedule.enqueue([a])

        // Demandée, pas encore lancée par iOS.
        #expect(schedule.enqueue([b]) == [])
        #expect(schedule.totalUnits == 200)

        // Lancée.
        #expect(schedule.leaseAttached(token: 1) == [])
        #expect(schedule.enqueue([c]) == [])
        #expect(schedule.totalUnits == 300)
        #expect(schedule.queue == [b, c])
        #expect(schedule.current == a)
    }

    @Test func busyJobsAreNeverAddedTwice() {
        var schedule = CleaningSchedule()
        _ = schedule.enqueue([a])
        #expect(schedule.enqueue([a, b, b]) == [])
        #expect(schedule.queue == [b])
        #expect(schedule.totalUnits == 200)
    }

    @Test func enqueueOfNothingWhileIdleDoesNothing() {
        var schedule = CleaningSchedule()
        #expect(schedule.enqueue([]) == [])
        #expect(schedule.lease == nil)
        #expect(schedule.currentProgress == nil)
    }

    // MARK: Avancement

    @Test func combinedProgressCoversEveryJobOfTheLease() {
        var schedule = CleaningSchedule()
        _ = schedule.enqueue([a, b])
        _ = schedule.leaseAttached(token: 1)

        schedule.progress(0.5, of: a)
        #expect(schedule.completedUnits == 50)
        #expect(schedule.currentProgress == 0.5)

        #expect(schedule.finish(a, success: true) == [.start(b)])
        #expect(schedule.completedUnits == 100)
        #expect(schedule.currentProgress == 0)

        schedule.progress(0.25, of: b)
        #expect(schedule.completedUnits == 125)
        // Ni recul, ni avancement d'un travail qui n'est pas en cours, ni dépassement.
        schedule.progress(0.1, of: b)
        schedule.progress(0.9, of: a)
        #expect(schedule.completedUnits == 125)
        schedule.progress(7, of: b)
        #expect(schedule.completedUnits == 200)
        #expect(schedule.currentProgress == 1)
    }

    // MARK: Fin de la file

    @Test func drainCompletesTheLeaseExactlyOnce() {
        var schedule = CleaningSchedule()
        _ = schedule.enqueue([a, b])
        _ = schedule.leaseAttached(token: 1)

        let first = schedule.finish(a, success: true)
        let second = schedule.finish(b, success: true)
        let again = schedule.finish(b, success: true)

        #expect(first == [.start(b)])
        #expect(second == [.completeLease(token: 1, success: true)])
        #expect(again == [])
        #expect(completions(first + second + again) == 1)
        #expect(schedule.lease == nil)
        #expect(schedule.busy.isEmpty)
        #expect(schedule.currentProgress == nil)
    }

    @Test func drainReportsFailureWhenAnyJobFailed() {
        var schedule = CleaningSchedule()
        _ = schedule.enqueue([a, b])
        _ = schedule.leaseAttached(token: 1)
        _ = schedule.finish(a, success: false)
        #expect(schedule.finish(b, success: true) == [.completeLease(token: 1, success: false)])
    }

    @Test func theNextEnqueueAfterADrainSubmitsANewLease() {
        var schedule = CleaningSchedule()
        _ = schedule.enqueue([a])
        _ = schedule.leaseAttached(token: 1)
        _ = schedule.finish(a, success: false)

        #expect(schedule.enqueue([b]) == [.submitLease(token: 2, firstJob: b), .start(b)])
        #expect(schedule.totalUnits == 100)
        #expect(schedule.completedUnits == 0)
        // Le nouveau lot repart réussi : l'échec du précédent ne compte plus.
        _ = schedule.leaseAttached(token: 2)
        #expect(schedule.finish(b, success: true) == [.completeLease(token: 2, success: true)])
    }

    // MARK: Expiration

    @Test func expirationCancelsTheCurrentJobAndLeavesTheRestForLater() {
        var schedule = CleaningSchedule()
        _ = schedule.enqueue([a, b, c])
        _ = schedule.leaseAttached(token: 1)

        #expect(schedule.leaseExpired(token: 1) == [.cancel(a), .completeLease(token: 1, success: false)])
        #expect(schedule.queue.isEmpty)
        #expect(schedule.lease == nil)
        // Le travail annulé finit : rien d'autre ne démarre, rien d'autre à terminer.
        #expect(schedule.finish(a, success: false) == [])
        #expect(schedule.busy.isEmpty)
    }

    @Test func expirationOfAnOldLeaseOnlyCompletesIt() {
        var schedule = CleaningSchedule()
        _ = schedule.enqueue([a])
        _ = schedule.leaseAttached(token: 1)
        #expect(schedule.leaseExpired(token: 99) == [.completeLease(token: 99, success: false)])
        #expect(schedule.current == a)
        #expect(schedule.lease == CleaningSchedule.Lease(token: 1, isAttached: true))
    }

    // MARK: Tâche refusée ou arrivée en retard

    @Test func refusedLeaseKeepsTheWorkGoingAndTheNextEnqueueTriesAgain() {
        var schedule = CleaningSchedule()
        _ = schedule.enqueue([a])
        schedule.leaseUnavailable(token: 1)
        #expect(schedule.lease == nil)
        #expect(schedule.current == a)

        schedule.progress(0.3, of: a)
        // Le travail en cours est couvert par la nouvelle demande.
        #expect(schedule.enqueue([b]) == [.submitLease(token: 2, firstJob: a)])
        #expect(schedule.totalUnits == 200)
        #expect(schedule.completedUnits == 30)
    }

    @Test func onlyARefusedLeaseLeavesTheWorkRunningWithoutOne() {
        var schedule = CleaningSchedule()
        #expect(!schedule.isRunningWithoutLease)
        _ = schedule.enqueue([a])
        // Demandée : iOS peut encore la lancer, rien à proposer.
        #expect(!schedule.isRunningWithoutLease)
        schedule.leaseUnavailable(token: 1)
        #expect(schedule.isRunningWithoutLease)
        _ = schedule.finish(a, success: true)
        #expect(!schedule.isRunningWithoutLease)

        // Lancée par iOS : couverte.
        _ = schedule.enqueue([b])
        _ = schedule.leaseAttached(token: 2)
        #expect(!schedule.isRunningWithoutLease)
    }

    @Test func resumeAfterARefusedLeaseRequestsANewOneForTheRunningJob() {
        var schedule = CleaningSchedule()
        _ = schedule.enqueue([a])
        schedule.leaseUnavailable(token: 1)

        // « Reprendre le nettoyage » confie de nouveau le travail en cours : rien n'est relancé ni dupliqué,
        // mais une tâche de fond est redemandée pour le couvrir.
        #expect(schedule.enqueue([a]) == [.submitLease(token: 2, firstJob: a)])
        #expect(schedule.current == a)
        #expect(schedule.queue.isEmpty)
        #expect(schedule.totalUnits == 100)
        #expect(!schedule.isRunningWithoutLease)
    }

    @Test func aCancelledJobStillFinishingIsNotRunningWithoutLease() {
        var schedule = CleaningSchedule()
        _ = schedule.enqueue([a])
        _ = schedule.leaseAttached(token: 1)
        // La tâche expire : le travail est annulé, mais il ne s'arrête qu'à son prochain point de contrôle.
        #expect(schedule.leaseExpired(token: 1) == [.cancel(a), .completeLease(token: 1, success: false)])
        #expect(schedule.current == a)
        #expect(!schedule.isRunningWithoutLease)
        _ = schedule.finish(a, success: false)
        #expect(!schedule.isRunningWithoutLease)
    }

    @Test func lateHandlerAfterTheQueueDrainedIsCompletedAtOnceWithTheOutcome() {
        var schedule = CleaningSchedule()
        _ = schedule.enqueue([a])
        // La file se vide avant que iOS ne lance la tâche : rien à terminer pour l'instant.
        #expect(schedule.finish(a, success: true) == [])
        #expect(schedule.lease == nil)

        #expect(schedule.leaseAttached(token: 1) == [.completeLease(token: 1, success: true)])
        // Une seule fois.
        #expect(schedule.leaseAttached(token: 1) == [.completeLease(token: 1, success: false)])
    }

    @Test func handlerForAnUnknownLeaseIsCompletedAsFailed() {
        var schedule = CleaningSchedule()
        #expect(schedule.leaseAttached(token: 42) == [.completeLease(token: 42, success: false)])
    }

    // MARK: Enregistrement en cours

    @Test func recordingCancelsTheCurrentJobEndsTheLeaseAndStartsNothing() {
        var schedule = CleaningSchedule()
        _ = schedule.enqueue([a, b])
        _ = schedule.leaseAttached(token: 1)

        #expect(schedule.setRecording(true) == [.cancel(a), .completeLease(token: 1, success: false)])
        #expect(schedule.queue.isEmpty)
        #expect(schedule.lease == nil)
        #expect(schedule.finish(a, success: false) == [])
        // Pendant l'enregistrement, rien ne démarre.
        #expect(schedule.enqueue([c]) == [])
        #expect(schedule.busy.isEmpty)

        // La fin de l'enregistrement ne relance rien d'elle-même…
        #expect(schedule.setRecording(false) == [])
        // … c'est le prochain ajout (après « Stop ») qui couvre tout ce qui attend.
        #expect(schedule.enqueue([a, b, c]) == [.submitLease(token: 2, firstJob: a), .start(a)])
        #expect(schedule.totalUnits == 300)
    }

    @Test func recordingWhileTheLeaseIsOnlyRequestedSettlesItAsFailed() {
        var schedule = CleaningSchedule()
        _ = schedule.enqueue([a])
        #expect(schedule.setRecording(true) == [.cancel(a)])
        #expect(schedule.leaseAttached(token: 1) == [.completeLease(token: 1, success: false)])
    }

    @Test func recordingWhileIdleOnlyBlocksNewWork() {
        var schedule = CleaningSchedule()
        #expect(schedule.setRecording(true) == [])
        #expect(schedule.isRecording)
        #expect(schedule.enqueue([a]) == [])
        #expect(schedule.setRecording(false) == [])
        #expect(!schedule.isRecording)
    }

    // MARK: Chauffe

    @Test func seriousAndCriticalHeatHoldTheCleaning() {
        #expect(!CleaningSchedule.isTooHot(.nominal))
        #expect(!CleaningSchedule.isTooHot(.fair))
        #expect(CleaningSchedule.isTooHot(.serious))
        #expect(CleaningSchedule.isTooHot(.critical))
    }

    @Test func heatLetsTheCurrentJobFinishButStartsNothingNew() {
        var schedule = CleaningSchedule()
        _ = schedule.enqueue([a, b])
        _ = schedule.leaseAttached(token: 1)

        // Le travail en cours continue.
        #expect(schedule.setOverheated(true) == [])
        #expect(schedule.isOverheated)
        #expect(schedule.current == a)
        #expect(!schedule.isWaitingForCooling)

        // À sa fin, rien ne démarre et la tâche de fond reste : la file attend.
        #expect(schedule.finish(a, success: true) == [])
        #expect(schedule.current == nil)
        #expect(schedule.currentProgress == nil)
        #expect(schedule.queue == [b])
        #expect(schedule.lease == CleaningSchedule.Lease(token: 1, isAttached: true))
        #expect(schedule.isWaitingForCooling)
        #expect(schedule.completedUnits == 100)

        // L'iPhone refroidit : la file repart là où elle s'était arrêtée.
        #expect(schedule.setOverheated(false) == [.start(b)])
        #expect(!schedule.isWaitingForCooling)
        #expect(schedule.finish(b, success: true) == [.completeLease(token: 1, success: true)])
    }

    @Test func enqueueWhileOverheatedRequestsTheLeaseButWaits() {
        var schedule = CleaningSchedule()
        _ = schedule.setOverheated(true)
        #expect(schedule.enqueue([a]) == [.submitLease(token: 1, firstJob: a)])
        #expect(schedule.current == nil)
        #expect(schedule.queue == [a])
        #expect(schedule.busy == [a])
        #expect(schedule.isWaitingForCooling)
        // Déjà en file : pas de doublon.
        #expect(schedule.enqueue([a]) == [])
        #expect(schedule.setOverheated(false) == [.start(a)])
    }

    @Test func coolingDownStartsNothingDuringARecording() {
        var schedule = CleaningSchedule()
        _ = schedule.setOverheated(true)
        _ = schedule.enqueue([a])
        // Un enregistrement vide la file, chauffe ou pas.
        #expect(schedule.setRecording(true) == [])
        #expect(schedule.queue.isEmpty)
        #expect(!schedule.isWaitingForCooling)
        #expect(schedule.setOverheated(false) == [])
        #expect(schedule.current == nil)
    }

    @Test func overheatingWhileIdleIsANoOp() {
        var schedule = CleaningSchedule()
        #expect(schedule.setOverheated(true) == [])
        #expect(!schedule.isWaitingForCooling)
        #expect(schedule.setOverheated(false) == [])
        #expect(schedule.busy.isEmpty)
    }
}
