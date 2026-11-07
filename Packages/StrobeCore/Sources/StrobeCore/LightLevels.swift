// Règle commune aux détecteurs en ligne et hors ligne : les deux niveaux de lumière d'une fenêtre.

/// Ce qu'une fenêtre d'images dit de la lumière : un seul niveau, ou deux niveaux nettement distincts,
/// « sans lumière » en bas et « avec lumière » en haut, quelle que soit leur proportion.
///
/// Les lumas moyennes de la fenêtre sont triées puis coupées en deux groupes à l'endroit qui sépare le plus
/// les groupes (méthode d'Otsu : `n_bas × n_haut × (moyenne haute − moyenne basse)²` maximal). Il y a deux
/// niveaux si la moyenne haute est nettement plus claire que la moyenne basse (`relativeJump`,
/// `absoluteMargin`). Une image n'est alors sans lumière que si sa luma ne dépasse pas
/// `bas + edgeShare × (haut − bas)`, `bas` et `haut` étant les lumas médianes des deux groupes (règle V2-R9) :
/// une image à moitié éclairée, la lampe s'allumant ou s'éteignant pendant la pose (obturateur roulant), part
/// avec la lumière au lieu de laisser une lueur dans la vidéo. Les médianes, et non les moyennes : les images
/// à moitié éclairées sont dans l'un des groupes et tireraient sa moyenne vers elles.
///
/// Sinon (un seul niveau, ou une coupure imposée par une marche trop faible pour faire deux niveaux), la règle
/// de la V1 s'applique : une image nettement plus claire que la médiane de la fenêtre est un éclair. Un éclair
/// court non saturé reste ainsi détecté à côté d'une petite marche d'éclairage.
///
/// La coupure se cherche sur les lumas elles-mêmes (pas sur leur logarithme), dans la même unité que le test
/// des deux niveaux : un éclair de 0,25 à 0,95 écrase alors les petits écarts du bruit, et le bruit d'une scène
/// très sombre (0,01 contre 0,02, un rapport 2 en logarithme) ne pèse presque rien.
///
/// Une rampe lente ne se coupe pas : coupée en son milieu, une rampe d'amplitude `r` donne deux groupes séparés
/// de `r / 2`, et un fondu de 0,1 à 0,5 en 3 s ne bouge que de 0,07 en 0,5 s (écart 0,03, sous la seule marge
/// de 0,04). Un fondu bien plus rapide peut se couper, mais sa lumière dure : c'est un changement d'éclairage.
///
/// Limite connue : avec deux lumières différentes en plus du fond (trois niveaux), seule la coupure la plus
/// nette est faite ; la lumière la plus faible peut alors rester dans le niveau bas.
struct LightLevels {
    /// Ce que dit la luma de la fenêtre.
    private enum LumaRule {
        /// Deux niveaux, de lumas médianes `low` (sans lumière) et `high` (avec lumière).
        case twoLevels(low: Double, high: Double)
        /// Un seul niveau : au-delà de `flashLuma` (médiane de la fenêtre × `relativeJump` + `absoluteMargin`),
        /// une image est un éclair.
        case oneLevel(flashLuma: Double)
    }

    /// Nombre d'images exigé dans une fenêtre pour juger : 6, ou moins à basse cadence quand la fenêtre ne
    /// peut pas en contenir autant (jamais moins de 3). `frameStep` est l'écart typique entre deux images.
    static func minimumFrames(windowSeconds: Double, frameStep: Double?) -> Int {
        guard let frameStep, frameStep > 0 else { return 6 }
        let framesInWindow = Int((windowSeconds / frameStep + 1e-9).rounded(.down))
        return min(6, max(3, framesInWindow))
    }

    /// Vrai si une fenêtre dont les lumas vont de `lowest` à `highest`, et dont aucune image n'a plus de
    /// `mostSaturated` de pixels saturés, ne peut juger aucune de ses images avec lumière : `highest` n'est pas
    /// nettement plus clair que `lowest`, et aucune image n'est brûlée. En effet, deux niveaux demandent une moyenne
    /// haute (au plus `highest`) nettement plus claire que la moyenne basse (au moins `lowest`) ; un seul niveau
    /// demande une luma au-delà de médiane × rapport + marge, donc au-delà de `highest` ; la saturation demande une
    /// image brûlée.
    static func cannotLightAnyFrame(
        lowest: Double,
        highest: Double,
        mostSaturated: Double,
        config: FlashDetectorConfig
    ) -> Bool {
        !config.isDistinctlyBrighter(highest, than: lowest) && mostSaturated <= config.saturatedFractionMax
    }

    private let lumaRule: LumaRule
    /// Vrai si le niveau bas (toute la fenêtre s'il n'y a qu'un niveau) n'est pas saturé : une image brûlée
    /// l'est alors par la lumière. Une scène saturée en permanence n'a pas d'images « avec lumière ».
    private let lowLevelIsUnsaturated: Bool
    private let config: FlashDetectorConfig

    /// `nil` si `frames` a moins de `minimumFrames` images.
    init?(of frames: some Collection<FrameStats>, minimumFrames: Int, config: FlashDetectorConfig) {
        guard frames.count >= max(1, minimumFrames) else { return nil }
        self.config = config

        let lumas = frames.map(\.meanLuma)
        let lowLevel: [FrameStats]
        if let split = Self.otsuSplit(of: lumas), config.isDistinctlyBrighter(split.highMean, than: split.lowMean) {
            lumaRule = .twoLevels(low: split.lowMedian, high: split.highMedian)
            lowLevel = frames.filter { $0.meanLuma < split.cut }
        } else {
            lumaRule = .oneLevel(flashLuma: Self.median(lumas) * config.relativeJump + config.absoluteMargin)
            lowLevel = Array(frames)
        }
        lowLevelIsUnsaturated = Self.median(lowLevel.map(\.saturatedFraction)) <= config.saturatedFractionMax
    }

    /// Vrai si la luma de `stats` dit qu'elle est avec lumière : au-dessus de la part `edgeShare` de l'écart
    /// entre les deux niveaux, ou, s'il n'y a qu'un niveau, nettement plus claire que la médiane.
    func isLitByLuma(_ stats: FrameStats) -> Bool {
        isLitByLuma(stats.meanLuma)
    }

    private func isLitByLuma(_ luma: Double) -> Bool {
        switch lumaRule {
        case let .twoLevels(low, high): luma > low + config.edgeShare * (high - low)
        case let .oneLevel(flashLuma): luma > flashLuma
        }
    }

    /// Vrai si l'image `index`, que sa luma dit avec lumière, est en fait un moment sans lumière entre deux
    /// lumières (règle V2-R21) : avec deux niveaux, le premier saut franc avant elle est une extinction depuis la
    /// lumière d'avant, et le premier saut franc après elle une montée vers celle d'après. Franc : de la même part
    /// `edgeShare` de l'écart que pour un allumage (`isSwitchOn`), d'une image à la suivante ; extinction : une
    /// descente d'au moins la moitié de l'écart. Le niveau sans lumière d'une zone suit le mouvement : dans une pièce
    /// noire où la lampe éclaire tout, il remonte peu à peu pendant un moment éteint, assez pour passer la part
    /// `edgeShare`, et ce moment se joindrait aux deux lumières qui l'entourent. Entre les deux sauts, la luma peut
    /// repasser sous la part `edgeShare` : seuls les sauts comptent.
    ///
    /// Les sauts se cherchent à moins de `maxFlashRunSeconds` de l'image, et le moment éteint dure au moins deux
    /// images. Ne sont pas de tels moments : une lumière (le premier saut avant elle est son allumage), son bord à
    /// moitié éclairé (après lui, la luma descend d'un coup vers le niveau éteint), une lumière qui s'allume pendant
    /// un moment éteint (son allumage vient avant), une lumière qui vacille (sa descente n'atteint pas la moitié de
    /// l'écart), l'image à moitié allumée seule entre les deux éclairs d'un double éclair (une image).
    func isDarkMomentBetweenLights(
        _ index: Int,
        times: [Double],
        luma: (Int) -> Double
    ) -> Bool {
        guard case let .twoLevels(low, high) = lumaRule else { return false }
        let jump = config.edgeShare * (high - low)
        let reach = config.maxFlashRunSeconds + FlashDetectorConfig.runLengthTolerance

        /// Le premier saut franc en partant de `index` dans le sens `step` (−1 vers le passé, +1 vers l'avenir) :
        /// `change`, positif si l'image au-delà du saut est plus claire, et `frames`, le nombre d'images parcourues
        /// avant lui ; `nil` s'il n'y en a pas à moins de `reach`.
        func firstSwitch(step: Int) -> (change: Double, frames: Int)? {
            var frame = index
            var frames = 0
            while times.indices.contains(frame + step), abs(times[frame + step] - times[index]) <= reach {
                let next = frame + step
                let change = luma(next) - luma(frame)
                if abs(change) >= jump { return (change, frames) }
                frame = next
                frames += 1
            }
            return nil
        }
        guard let before = firstSwitch(step: -1), before.change >= (high - low) / 2,
              let after = firstSwitch(step: 1), after.change > 0
        else { return false }
        return before.frames + after.frames >= 1
    }

    /// Vrai si passer de la luma `darker` (image récente sans lumière) à `brighter` est un allumage franc. Avec
    /// deux niveaux, le saut doit atteindre la même part de l'écart que pour juger l'image (`edgeShare`) : le
    /// bord à moitié éclairé d'un allumage l'atteint d'une image à l'autre, une lumière qui monte doucement
    /// non. Avec un seul niveau : nettement plus claire (rapport et marge).
    func isSwitchOn(from darker: Double, to brighter: Double) -> Bool {
        switch lumaRule {
        case let .twoLevels(low, high): brighter - darker >= config.edgeShare * (high - low)
        case .oneLevel: config.isDistinctlyBrighter(brighter, than: darker)
        }
    }

    /// Vrai si `stats` est brûlée alors que le niveau bas ne l'est pas.
    func isLitBySaturation(_ stats: FrameStats) -> Bool {
        lowLevelIsUnsaturated && isBurnt(stats)
    }

    /// Vrai si plus de `saturatedFractionMax` des pixels de `stats` sont saturés.
    func isBurnt(_ stats: FrameStats) -> Bool {
        stats.saturatedFraction > config.saturatedFractionMax
    }

    /// Vrai si, sur `neighbour`, voisine de l'image avec lumière `litFrame`, la lumière est encore allumée :
    /// elle n'est pas nettement plus sombre que `litFrame`. Le rapport et la marge absorbent aussi le bruit
    /// d'une image à l'autre : sur une rampe, la fenêtre centrée d'une image est coupée juste à sa luma, et une
    /// voisine à peine plus sombre ne doit pas couper sa période avec lumière.
    ///
    /// Avec deux niveaux, une voisine sans lumière (sous la part `edgeShare` de l'écart) éteint aussi la
    /// lumière : une image à moitié éclairée n'est pas nettement plus claire, au sens du rapport, que les images
    /// éteintes qui la bordent, et sa lumière semblerait durer sans fin (règle V2-R9).
    func keepsLumaLightOn(_ neighbour: FrameStats, litFrame: FrameStats) -> Bool {
        if case .twoLevels = lumaRule, !isLitByLuma(neighbour) { return false }
        return !config.isDistinctlyBrighter(litFrame.meanLuma, than: neighbour.meanLuma)
    }

    /// Coupure d'Otsu des lumas, entre deux valeurs différentes seulement, avec la moyenne et la médiane (haute)
    /// de chaque groupe ; `nil` si toutes sont égales.
    private static func otsuSplit(
        of lumas: [Double]
    ) -> (cut: Double, lowMean: Double, highMean: Double, lowMedian: Double, highMedian: Double)? {
        let sorted = lumas.sorted()
        let total = sorted.reduce(0, +)
        var lowSum = 0.0
        var best: (score: Double, split: Int, lowMean: Double, highMean: Double)?

        for split in 1..<sorted.count {
            lowSum += sorted[split - 1]
            guard sorted[split] > sorted[split - 1] else { continue }

            let lowCount = Double(split)
            let highCount = Double(sorted.count - split)
            let lowMean = lowSum / lowCount
            let highMean = (total - lowSum) / highCount
            let score = lowCount * highCount * (highMean - lowMean) * (highMean - lowMean)
            if score > (best?.score ?? -1) {
                best = (score, split, lowMean, highMean)
            }
        }
        return best.map { best in
            (
                cut: (sorted[best.split - 1] + sorted[best.split]) / 2,
                lowMean: best.lowMean,
                highMean: best.highMean,
                lowMedian: sorted[best.split / 2],
                highMedian: sorted[best.split + (sorted.count - best.split) / 2]
            )
        }
    }

    /// Médiane haute (l'élément du milieu, le plus grand des deux si le nombre de valeurs est pair).
    private static func median(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }
}

/// Écart médian entre deux horodatages consécutifs ; `nil` s'il y a moins de deux images.
func medianStep(of times: [Double]) -> Double? {
    let steps = zip(times, times.dropFirst()).map { $1 - $0 }.sorted()
    return steps.isEmpty ? nil : steps[steps.count / 2]
}
