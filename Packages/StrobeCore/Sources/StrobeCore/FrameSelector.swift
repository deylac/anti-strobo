/// Bilan d'une sélection d'images : combien de créneaux de sortie, et combien n'ont pas eu de bonne image.
///
/// Chaque créneau est de l'une de ces quatre sortes : image source d'un créneau avec une bonne image, interpolé,
/// répété ou de repli. Le nombre de créneaux source est donc `slots − interpolatedSlots − heldSlots − fallbackSlots`.
public struct SelectionReport: Sendable, Equatable, Codable {
    /// Nombre de créneaux de sortie (donc d'images de la vidéo nettoyée).
    public var slots: Int
    /// Créneaux sans bonne image qui répètent la dernière bonne image choisie, encore récente, ou qui, en tout
    /// début de vidéo, montrent déjà la première bonne image, proche (`FrameSelector.plan` avec interpolation).
    public var heldSlots: Int
    /// Créneaux sans bonne image ni image récente à répéter : image la moins lumineuse du créneau,
    /// ou choix du créneau précédent si le créneau est vide.
    public var fallbackSlots: Int
    /// Créneaux sans bonne image reconstruits par interpolation entre la dernière bonne image d'avant et la
    /// première d'après (toujours 0 pour `FrameSelector.select`, qui n'interpole pas).
    public var interpolatedSlots: Int

    public init(slots: Int, heldSlots: Int, fallbackSlots: Int, interpolatedSlots: Int = 0) {
        self.slots = slots
        self.heldSlots = heldSlots
        self.fallbackSlots = fallbackSlots
        self.interpolatedSlots = interpolatedSlots
    }

    /// Créneaux qui montrent une bonne image du créneau : `slots − interpolatedSlots − heldSlots − fallbackSlots`.
    public var sourceSlots: Int {
        slots - interpolatedSlots - heldSlots - fallbackSlots
    }
}

/// Ce qu'une image de la vidéo de sortie (un créneau) montre : les indices sont ceux des tableaux passés à
/// `FrameSelector.plan`.
public enum SlotPlan: Sendable, Equatable {
    /// Une bonne image du créneau (la première).
    case source(Int)
    /// Image synthétisée à la `phase` (strictement entre 0 et 1) du trajet entre deux bonnes images : `from`
    /// (la dernière bonne image avant le créneau) et `to` (la première après, éventuellement dans un créneau
    /// suivant).
    case interpolate(from: Int, to: Int, phase: Double)
    /// La dernière bonne image choisie, répétée (créneau sans bonne image, trou court).
    case hold(Int)
    /// Dernier recours : image la moins lumineuse du créneau, ou choix du créneau précédent si le créneau est vide.
    case fallback(Int)
}

/// Choisit, pour chaque image de la vidéo de sortie (30 i/s), ce qu'elle montre : une image source (filmée à
/// 120, 60 ou 30 i/s), une image recréée entre deux images sources, ou une image répétée.
public enum FrameSelector {
    /// Tolérance (secondes) des calculs en flottant : conversion de `maxHoldSeconds` en créneaux, comparaison
    /// d'un écart de temps à `maxInterpolationGap` (52/120 − 10/120 vaut 0,35000000000000003 et non 0,35), et
    /// rangement d'une image pile à mi-chemin entre deux débuts de créneau (voir `slotShift`).
    private static let epsilon = 1e-6

    /// Plus grand nombre de créneaux accepté : au-delà, ce n'est pas une vidéo et le tableau de candidats
    /// serait énorme ; on renvoie alors un résultat vide.
    private static let maxSlotCount = Double(Int32.max)

    /// Bornes de la phase d'une interpolation : une phase de 0 ou de 1 redonnerait une des deux images sources
    /// (donc l'image brûlée voisine ou un doublon), la synthèse n'a rien à faire à moins de 0,1 % d'elles.
    private static let phaseRange = 0.001...0.999

    /// Choisit une image source par créneau de sortie, sans jamais interpoler (comportement V1).
    ///
    /// Équivaut à `plan(…, interpolationAvailable: false)` dont on ne garde que l'indice de chaque créneau.
    ///
    /// Le nombre de créneaux est `Int((duration × outputFPS).rounded())` ; le créneau k commence à
    /// `k/outputFPS` et reçoit les images rangées comme le dit `plan` (à une demi-image près). Pour chaque
    /// créneau, dans l'ordre :
    /// 1. il contient une bonne image : la première bonne image du créneau ;
    /// 2. sinon, la dernière bonne image choisie a été émise il y a moins de `maxHoldSeconds`, mesuré en
    ///    créneaux entiers (`maxHoldSeconds × outputFPS` arrondi vers le bas, soit 6 par défaut) : on la
    ///    répète (`heldSlots`). Une même image source sert donc au plus `maxHoldSeconds × outputFPS`
    ///    créneaux d'affilée, quelle que soit sa position dans son créneau d'origine ;
    /// 3. sinon : l'image de plus faible `meanLuma` du créneau (`fallbackSlots`), ou, si le créneau est
    ///    vide (images perdues, fin de fichier), l'image choisie au créneau précédent (à défaut l'image 0).
    ///
    /// Avec des horodatages croissants, les indices retournés sont croissants : jamais de retour en arrière.
    /// Les images rangées hors des créneaux (avant le premier ou après le dernier) sont ignorées. Une cadence ou
    /// une durée invalide (nulle, négative, non finie) ou un nombre de créneaux absurde donne un résultat vide.
    /// - Parameters:
    ///   - times: horodatage source en secondes de chaque image, croissant.
    ///   - verdicts: verdict de chaque image (même longueur que `times`).
    ///   - stats: statistiques de chaque image (même longueur que `times`).
    ///   - duration: durée de la vidéo en secondes.
    ///   - outputFPS: cadence de la vidéo de sortie.
    ///   - maxHoldSeconds: durée maximale (secondes) pendant laquelle on répète une bonne image ; nulle,
    ///     négative ou non numérique, on ne répète jamais.
    /// - Returns: un indice d'image source par créneau (vide si `times` est vide) et le bilan.
    public static func select(
        times: [Double],
        verdicts: [FrameVerdict],
        stats: [FrameStats],
        duration: Double,
        outputFPS: Double = 30,
        maxHoldSeconds: Double = 0.2
    ) -> (indices: [Int], report: SelectionReport) {
        let result = plan(
            times: times,
            verdicts: verdicts,
            stats: stats,
            duration: duration,
            outputFPS: outputFPS,
            maxHoldSeconds: maxHoldSeconds,
            interpolationAvailable: false
        )
        return (result.slots.map(\.singleSourceIndex), result.report)
    }

    /// Planifie, pour chaque créneau de sortie, l'image à montrer : une image source, une interpolation entre
    /// deux images sources, ou (comme en V1) une image répétée ou de repli.
    ///
    /// Le créneau k commence à `t = k/outputFPS`, l'instant où son image est montrée. Une image d'horodatage
    /// `time` est rangée dans le créneau qui commence au plus tard à `time + s` : `s` (voir `slotShift`) vaut
    /// la moitié de l'écart médian entre deux images, au plus la moitié d'un créneau. Chaque créneau reçoit
    /// ainsi les images les plus proches de son début, et la gigue des horodatages d'une caméra (quelques
    /// dizaines de µs) ne fait jamais passer une image dans le créneau d'avant, même à 30 i/s où chaque
    /// créneau n'a qu'une image. Pile à mi-chemin, une image va au créneau qui la contient.
    ///
    /// Pour chaque créneau, dans l'ordre :
    /// 1. il contient une bonne image : `.source` de la première bonne image du créneau ;
    /// 2. sinon, si `interpolationAvailable`, soit A la dernière bonne image des créneaux précédents et B la
    ///    première des créneaux suivants. Si les deux existent et que `time(B) − time(A) ≤ maxInterpolationGap` :
    ///    `.interpolate(from: A, to: B, phase:)` avec `phase = (u − time(A)) / (time(B) − time(A))`, bornée à
    ///    `[0,001 ; 0,999]`, où `u` est l'horodatage de l'image retirée que le créneau aurait montrée (sa
    ///    première image), ou `t` si le créneau est vide : l'image recréée est montrée au même instant de la
    ///    scène qu'une image source ;
    /// 3. sinon, si `interpolationAvailable` et qu'aucune bonne image ne précède le créneau (début de vidéo
    ///    éclairé) : `.hold` de la première bonne image B si `time(B) − t ≤ maxInterpolationGap` (même
    ///    tolérance), compté dans `heldSlots` : la vidéo commence sur une image sans lumière plutôt que sur une
    ///    image brûlée ;
    /// 4. sinon, si `interpolationAvailable` et qu'aucune bonne image ne suit le créneau (fin de vidéo
    ///    éclairée) : `.hold` de la dernière bonne image choisie A' si `t − time(A') ≤ maxInterpolationGap`
    ///    (même tolérance), compté dans `heldSlots` : la vidéo finit sur une image sans lumière ;
    /// 5. sinon les règles de `select` : `.hold` de la dernière bonne image choisie tant qu'elle date de
    ///    moins de `maxHoldSeconds` (en créneaux entiers), puis `.fallback`.
    ///
    /// Les créneaux sans bonne image qui se suivent ont tous les mêmes A et B : un trou est interpolé en
    /// entier ou pas du tout, jamais en partie. Avant la première bonne image, il n'y a pas de A : ces créneaux
    /// montrent B s'il est proche (règle 3), sinon suivent les règles de `select`. Après la dernière, il n'y a
    /// pas de B : ces créneaux répètent la dernière bonne image choisie si elle est proche (règle 4, la même
    /// que le maintien de `select`), sinon suivent les règles de `select`.
    ///
    /// Avec des horodatages croissants, les images référencées ne reculent jamais d'un créneau au suivant : ni
    /// la plus petite ni la plus grande (le B d'un créneau interpolé est la source du créneau qui suit le trou).
    /// Les images rangées hors des créneaux (avant le premier ou après le dernier) sont ignorées, y compris
    /// comme A ou B. Une cadence ou une durée invalide (nulle, négative, non finie) ou un nombre de créneaux
    /// absurde donne un résultat vide.
    /// - Parameters:
    ///   - times: horodatage source en secondes de chaque image, croissant.
    ///   - verdicts: verdict de chaque image (même longueur que `times`).
    ///   - stats: statistiques de chaque image (même longueur que `times`).
    ///   - duration: durée de la vidéo en secondes.
    ///   - outputFPS: cadence de la vidéo de sortie.
    ///   - maxHoldSeconds: durée maximale (secondes) pendant laquelle on répète une bonne image ; nulle,
    ///     négative ou non numérique, on ne répète jamais.
    ///   - maxInterpolationGap: écart maximal (secondes) entre A et B pour interpoler, avec une tolérance de
    ///     1 µs ; nul, négatif ou non numérique, on n'interpole jamais.
    ///   - interpolationAvailable: faux quand la synthèse d'images n'est pas disponible : le plan est alors
    ///     exactement celui de `select` (ni interpolation, ni règle 3).
    /// - Returns: un `SlotPlan` par créneau (vide si `times` est vide) et le bilan.
    public static func plan(
        times: [Double],
        verdicts: [FrameVerdict],
        stats: [FrameStats],
        duration: Double,
        outputFPS: Double = 30,
        maxHoldSeconds: Double = 0.2,
        maxInterpolationGap: Double = 0.35,
        interpolationAvailable: Bool
    ) -> (slots: [SlotPlan], report: SelectionReport) {
        precondition(
            times.count == verdicts.count && times.count == stats.count,
            "times, verdicts et stats doivent avoir la même longueur"
        )

        let slotCount = slotCount(duration: duration, outputFPS: outputFPS)
        guard !times.isEmpty, slotCount > 0 else {
            return ([], SelectionReport(slots: 0, heldSlots: 0, fallbackSlots: 0))
        }

        // Répartit les images dans les créneaux, à une demi-image près.
        let shift = slotShift(times: times, outputFPS: outputFPS)
        var candidates = [SlotCandidates](repeating: SlotCandidates(), count: slotCount)
        for index in times.indices {
            let position = ((times[index] + shift) * outputFPS).rounded(.down)
            guard position >= 0, position < Double(slotCount) else { continue }
            candidates[Int(position)].add(index, isGood: verdicts[index] == .good, luma: stats[index].meanLuma)
        }

        // Nombre de créneaux qui séparent une bonne image de la dernière qu'on veut bien lui faire répéter.
        // Compté en créneaux et non en secondes : la position de l'image dans son créneau d'origine ne doit
        // pas rallonger le maintien (une image tardive dans son créneau serait répétée un créneau de trop).
        let holdSlots = maxHoldSeconds * outputFPS + epsilon
        let holdLimit = holdSlots > 0 ? Int(min(holdSlots.rounded(.down), Double(slotCount))) : 0

        var slots: [SlotPlan] = []
        slots.reserveCapacity(slotCount)
        var report = SelectionReport(slots: slotCount, heldSlots: 0, fallbackSlots: 0)
        // Dernière bonne image choisie et créneau où elle a été émise : seule une vraie bonne image est répétée.
        var lastGood: (index: Int, slot: Int)?
        // Image choisie au créneau précédent (l'image 0 avant le tout premier créneau), prolongée par un repli
        // sur un créneau vide.
        var previousChoice = 0

        var slot = 0
        while slot < slotCount {
            if let good = candidates[slot].firstGood {
                slots.append(.source(good))
                previousChoice = good
                lastGood = (good, slot)
                slot += 1
                continue
            }

            // Suite de créneaux sans bonne image, de `slot` inclus à `gapEnd` exclu : mêmes A et B pour tous.
            var gapEnd = slot + 1
            while gapEnd < slotCount, candidates[gapEnd].firstGood == nil { gapEnd += 1 }

            let after = gapEnd < slotCount ? candidates[gapEnd].firstGood : nil
            let bridge = interpolationAvailable
                ? interpolationBridge(
                    before: lastGood.flatMap { candidates[$0.slot].lastGood },
                    after: after,
                    times: times,
                    maxInterpolationGap: maxInterpolationGap
                )
                : nil
            // Début de vidéo éclairé : aucune bonne image avant, la première bonne image vient après le trou.
            let firstGood = interpolationAvailable && lastGood == nil ? after : nil
            // Fin de vidéo éclairée : aucune bonne image après, la dernière bonne image choisie précède le trou.
            // La même que le maintien de `select` : les images montrées ne reculent pas quand il prend le relais.
            let finalGood = interpolationAvailable && after == nil ? lastGood?.index : nil

            for gapSlot in slot..<gapEnd {
                let start = Double(gapSlot) / outputFPS
                if let bridge {
                    // L'instant de la scène que le créneau aurait montré : sa première image (retirée), sinon son début.
                    let shown = candidates[gapSlot].first.map { times[$0] } ?? start
                    let phase = (shown - bridge.fromTime) / bridge.span
                    slots.append(.interpolate(
                        from: bridge.from,
                        to: bridge.to,
                        phase: min(max(phase, phaseRange.lowerBound), phaseRange.upperBound)
                    ))
                    previousChoice = bridge.to
                    report.interpolatedSlots += 1
                } else if let firstGood,
                          // La comparaison est fausse pour une limite non numérique : règles de `select`.
                          times[firstGood] - start <= maxInterpolationGap + epsilon {
                    slots.append(.hold(firstGood))
                    previousChoice = firstGood
                    report.heldSlots += 1
                } else if let finalGood, start - times[finalGood] <= maxInterpolationGap + epsilon {
                    slots.append(.hold(finalGood))
                    previousChoice = finalGood
                    report.heldSlots += 1
                } else if let last = lastGood, gapSlot - last.slot < holdLimit {
                    slots.append(.hold(last.index))
                    previousChoice = last.index
                    report.heldSlots += 1
                } else {
                    // Créneau vide : on prolonge le choix précédent (l'image 0 au tout premier créneau).
                    let choice = candidates[gapSlot].leastBurnt ?? previousChoice
                    slots.append(.fallback(choice))
                    previousChoice = choice
                    report.fallbackSlots += 1
                }
            }
            slot = gapEnd
        }
        return (slots, report)
    }

    /// Les deux bonnes images entre lesquelles on interpole un trou, et l'écart de temps qui les sépare.
    private struct Bridge {
        var from: Int
        var to: Int
        /// Horodatage de `from`.
        var fromTime: Double
        /// `time(to) − time(from)`. Strictement positif : `from` et `to` sont dans deux créneaux différents, dont
        /// la position se déduit de leur horodatage.
        var span: Double
    }

    /// Le pont entre la bonne image `from` (avant le trou) et `to` (après), ou `nil` s'il manque l'une des deux
    /// ou si elles sont à plus de `maxInterpolationGap` l'une de l'autre.
    private static func interpolationBridge(
        before from: Int?,
        after to: Int?,
        times: [Double],
        maxInterpolationGap: Double
    ) -> Bridge? {
        guard let from, let to else { return nil }
        let span = times[to] - times[from]
        // La comparaison est fausse pour une limite non numérique : pas d'interpolation.
        guard span <= maxInterpolationGap + epsilon else { return nil }
        return Bridge(from: from, to: to, fromTime: times[from], span: span)
    }

    /// Avance (secondes) ajoutée aux horodatages pour les ranger dans les créneaux, calculée une fois pour toute
    /// la vidéo : la moitié de l'écart médian entre deux images, au plus la moitié d'un créneau (une image n'est
    /// jamais montrée plus d'un demi-créneau avant son instant), moins `epsilon` (une image pile à mi-chemin
    /// reste dans le créneau qui la contient).
    ///
    /// À 120, 60 ou 30 i/s, les images sont à une demi-image des débuts de créneau : leur rangement ne dépend
    /// plus ni des arrondis (492/120 × 30 vaut 122,99999999999999), ni de la gigue des horodatages. Sans écart
    /// mesurable (une seule image), `epsilon` seul couvre les arrondis.
    static func slotShift(times: [Double], outputFPS: Double) -> Double {
        guard let step = medianStep(of: times), step.isFinite, step > 0 else { return epsilon }
        return max(epsilon, min(step, 1 / outputFPS) / 2 - epsilon)
    }

    private static func slotCount(duration: Double, outputFPS: Double) -> Int {
        // Cadence ou durée nulle, négative, infinie ou non numérique, ou nombre de créneaux absurde : aucun
        // créneau. La cadence est testée seule : deux signes négatifs donneraient un produit positif.
        guard outputFPS > 0, outputFPS.isFinite else { return 0 }
        let slots = (duration * outputFPS).rounded()
        guard slots > 0, slots < maxSlotCount else { return 0 }
        return Int(slots)
    }
}

private extension SlotPlan {
    /// Image source de `select`, qui n'interpole jamais ; pour une interpolation (qu'elle ne produit pas),
    /// la bonne image d'avant.
    var singleSourceIndex: Int {
        switch self {
        case .source(let index), .hold(let index), .fallback(let index): index
        case .interpolate(let from, _, _): from
        }
    }
}

/// Images d'un créneau qui comptent pour le choix : la première, la première bonne, la dernière bonne, et la
/// moins lumineuse.
private struct SlotCandidates {
    /// Première image du créneau, bonne ou non : l'instant de la scène que le créneau montre.
    private(set) var first: Int?
    /// Première bonne image du créneau.
    private(set) var firstGood: Int?
    /// Dernière bonne image du créneau : la plus proche du créneau suivant, point de départ d'une interpolation.
    private(set) var lastGood: Int?
    /// Image de plus faible luma du créneau (la première en cas d'égalité).
    private(set) var leastBurnt: Int?
    private var leastBurntLuma = 0.0

    mutating func add(_ index: Int, isGood: Bool, luma: Double) {
        if first == nil { first = index }
        if isGood {
            if firstGood == nil { firstGood = index }
            lastGood = index
        }
        if leastBurnt == nil || luma < leastBurntLuma {
            leastBurnt = index
            leastBurntLuma = luma
        }
    }
}
