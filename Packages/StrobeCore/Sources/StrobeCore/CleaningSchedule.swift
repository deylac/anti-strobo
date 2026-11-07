import Foundation

/// Ce que l'app doit faire après un événement de la file de nettoyage.
public enum CleaningScheduleAction: Sendable, Equatable {
    /// Demander à iOS une tâche de fond (`BGContinuedProcessingTask`) couvrant la file, nommée d'après `firstJob`.
    case submitLease(token: Int, firstJob: UUID)
    /// Lancer ce travail.
    case start(UUID)
    /// Annuler ce travail (il reste à reprendre).
    case cancel(UUID)
    /// Terminer la tâche de fond `token` (`setTaskCompleted(success:)`).
    case completeLease(token: Int, success: Bool)
}

/// Comptabilité de la file de nettoyage et de **sa** tâche de fond. Logique pure : l'app applique les actions.
///
/// - Un seul travail tourne à la fois ; un travail n'est jamais deux fois en file ou en cours.
/// - Une seule tâche de fond couvre toute la file : elle est demandée quand des travaux arrivent et qu'aucune
///   tâche n'est en cours ni demandée ; chaque travail ajouté ensuite lui ajoute `unitsPerJob` unités. Son
///   avancement est celui de toute la file. Elle est terminée une seule fois, quand la file se vide (réussie si
///   tous ses travaux ont réussi).
/// - Expiration de la tâche : le travail en cours est annulé et le reste de la file abandonné (les travaux restent
///   à reprendre dans la liste mémorisée).
/// - Enregistrement en cours : même chose, et rien ne démarre tant qu'il dure. La fin de l'enregistrement ne
///   relance rien : c'est le prochain ajout (un toucher) qui redemande une tâche.
/// - iPhone trop chaud (`setOverheated`) : le travail en cours finit, mais aucun autre ne démarre ; la file et sa
///   tâche de fond attendent, et la file repart d'elle-même quand l'iPhone a refroidi.
/// - Une tâche qu'iOS lance après coup (file déjà vide, demande remplacée) est terminée aussitôt.
/// - Une demande refusée laisse le travail continuer sans tâche de fond (`isRunningWithoutLease`) : le prochain
///   ajout, même d'un travail déjà en cours, en redemande une.
public struct CleaningSchedule: Sendable {
    /// Tâche de fond demandée (`isAttached` faux) ou lancée par iOS.
    public struct Lease: Sendable, Equatable {
        public let token: Int
        public var isAttached: Bool

        public init(token: Int, isAttached: Bool) {
            self.token = token
            self.isAttached = isAttached
        }
    }

    /// Unités de la tâche de fond par travail couvert.
    public static let unitsPerJob: Int64 = 100

    /// Travaux qui attendent leur tour.
    public private(set) var queue: [UUID] = []
    /// Travail en cours.
    public private(set) var current: UUID?
    /// Tâche de fond de la file, s'il y en a une.
    public private(set) var lease: Lease?
    /// Vrai pendant un enregistrement : rien ne tourne.
    public private(set) var isRecording = false
    /// Vrai quand l'iPhone chauffe trop : aucun travail ne démarre (celui en cours finit).
    public private(set) var isOverheated = false
    /// Unités de la tâche de fond : `unitsPerJob` par travail couvert.
    public private(set) var totalUnits: Int64 = 0

    /// Unités des travaux de la tâche déjà finis.
    private var finishedUnits: Int64 = 0
    /// Avancement (0…1) du travail en cours.
    private var currentFraction = 0.0
    /// Vrai tant qu'aucun travail de la tâche n'a échoué.
    private var allSucceeded = true
    /// Vrai quand le travail en cours a reçu l'ordre d'annulation et n'a pas encore fini.
    private var currentCancelled = false
    /// Dernier numéro de tâche donné.
    private var lastToken = 0
    /// Issue des demandes dont la file s'est vidée (ou a été arrêtée) avant qu'iOS ne lance la tâche.
    private var settled: [Int: Bool] = [:]

    public init() {}

    /// Travaux en file ou en cours.
    public var busy: Set<UUID> {
        var ids = Set(queue)
        if let current { ids.insert(current) }
        return ids
    }

    /// Avancement du travail en cours (0…1), `nil` quand rien ne tourne.
    public var currentProgress: Double? {
        current == nil ? nil : currentFraction
    }

    /// Vrai quand un travail tourne sans tâche de fond ni demande en cours (demande refusée par iOS) : il
    /// s'arrêtera si l'app passe en arrière-plan. Faux pour un travail déjà annulé qui finit.
    public var isRunningWithoutLease: Bool {
        current != nil && !currentCancelled && lease == nil
    }

    /// Vrai quand des travaux attendent que l'iPhone refroidisse : rien ne tourne, la file n'est pas vide.
    public var isWaitingForCooling: Bool {
        isOverheated && current == nil && !queue.isEmpty
    }

    /// Vrai à partir de l'état thermique `serious` : le nettoyage (décodage et encodage HEVC) chaufferait encore.
    public static func isTooHot(_ state: ProcessInfo.ThermalState) -> Bool {
        state.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }

    /// Unités faites de la tâche de fond : travaux finis, plus la part faite du travail en cours.
    public var completedUnits: Int64 {
        let running = current == nil ? 0 : Int64((currentFraction * Double(Self.unitsPerJob)).rounded(.down))
        return min(totalUnits, finishedUnits + running)
    }

    // MARK: - Événements

    /// Ajoute des travaux (suite à un toucher de l'utilisateur), dans l'ordre, sauf ceux déjà en file ou en cours.
    /// Sans effet pendant un enregistrement.
    public mutating func enqueue(_ jobs: [UUID]) -> [CleaningScheduleAction] {
        guard !isRecording else { return [] }
        var actions: [CleaningScheduleAction] = []

        var added = 0
        for job in jobs where !busy.contains(job) {
            queue.append(job)
            added += 1
        }

        if lease != nil {
            totalUnits += Int64(added) * Self.unitsPerJob
        } else if let first = current ?? queue.first {
            lastToken += 1
            lease = Lease(token: lastToken, isAttached: false)
            totalUnits = Int64(busy.count) * Self.unitsPerJob
            finishedUnits = 0
            allSucceeded = true
            actions.append(.submitLease(token: lastToken, firstJob: first))
        }

        actions += startNextIfIdle()
        return actions
    }

    /// Avancement du travail en cours ; ignoré pour un autre travail. Ne recule jamais, borné à 0…1.
    public mutating func progress(_ fraction: Double, of job: UUID) {
        guard job == current, fraction.isFinite else { return }
        currentFraction = min(1, max(currentFraction, fraction))
    }

    /// Le travail en cours est fini (rangé dans Photos, ou non). Lance le suivant, ou termine la tâche de fond si
    /// la file est vide. Une file qui attend (iPhone trop chaud) garde sa tâche de fond.
    public mutating func finish(_ job: UUID, success: Bool) -> [CleaningScheduleAction] {
        guard job == current else { return [] }
        current = nil
        currentFraction = 0
        currentCancelled = false
        if lease != nil {
            finishedUnits += Self.unitsPerJob
            allSucceeded = allSucceeded && success
        }

        let next = startNextIfIdle()
        guard next.isEmpty, queue.isEmpty else { return next }
        return endLease(success: allSucceeded)
    }

    /// iOS lance la tâche de fond `token`. Celle de la file s'y rattache ; une autre (file vidée entre-temps,
    /// demande remplacée) est terminée aussitôt.
    public mutating func leaseAttached(token: Int) -> [CleaningScheduleAction] {
        if lease?.token == token {
            lease?.isAttached = true
            return []
        }
        let success = settled.removeValue(forKey: token) ?? false
        return [.completeLease(token: token, success: success)]
    }

    /// La tâche de fond `token` expire (iOS reprend son temps, ou l'utilisateur l'arrête) : le travail en cours
    /// est annulé et le reste de la file abandonné.
    public mutating func leaseExpired(token: Int) -> [CleaningScheduleAction] {
        guard lease?.token == token else { return [.completeLease(token: token, success: false)] }
        return stopAll()
    }

    /// La demande `token` a été refusée : le travail continue au premier plan, sans tâche de fond.
    public mutating func leaseUnavailable(token: Int) {
        guard lease?.token == token else { return }
        lease = nil
        totalUnits = 0
        finishedUnits = 0
    }

    /// L'iPhone devient trop chaud, ou refroidit. Trop chaud : le travail en cours finit, rien d'autre ne démarre.
    /// Refroidi : le travail suivant de la file démarre (sauf pendant un enregistrement).
    public mutating func setOverheated(_ hot: Bool) -> [CleaningScheduleAction] {
        isOverheated = hot
        return startNextIfIdle()
    }

    /// Un enregistrement commence ou finit. Au début : le travail en cours est annulé, le reste de la file
    /// abandonné, la tâche de fond terminée. À la fin : rien ne repart de soi-même.
    public mutating func setRecording(_ active: Bool) -> [CleaningScheduleAction] {
        let wasRecording = isRecording
        isRecording = active
        guard active, !wasRecording else { return [] }
        return stopAll()
    }

    // MARK: - Interne

    private mutating func startNextIfIdle() -> [CleaningScheduleAction] {
        guard current == nil, !isRecording, !isOverheated, !queue.isEmpty else { return [] }
        let next = queue.removeFirst()
        current = next
        currentFraction = 0
        currentCancelled = false
        return [.start(next)]
    }

    /// Annule le travail en cours, vide la file et termine la tâche de fond en échec.
    private mutating func stopAll() -> [CleaningScheduleAction] {
        var actions: [CleaningScheduleAction] = []
        if let current {
            actions.append(.cancel(current))
            currentCancelled = true
        }
        queue.removeAll()
        return actions + endLease(success: false)
    }

    /// Termine la tâche de fond : tout de suite si iOS l'a lancée, sinon à son arrivée (`leaseAttached`).
    private mutating func endLease(success: Bool) -> [CleaningScheduleAction] {
        guard let ended = lease else { return [] }
        lease = nil
        totalUnits = 0
        finishedUnits = 0
        if ended.isAttached {
            return [.completeLease(token: ended.token, success: success)]
        }
        settled[ended.token] = success
        return []
    }
}
