/// Rythme du stroboscope observé sur une suite d'images jugées : sert à choisir la cadence de prise de vue
/// (chaque moment sans lumière doit contenir assez d'images à la nouvelle cadence).
public struct StrobeRhythm: Sendable, Equatable {
    /// Vrai si au moins deux moments sans lumière encadrés par des battements de strobe ont été vus : le rythme
    /// est mesuré. Un ou deux moments avec lumière (éclair isolé, début d'une ou deux marches d'éclairage
    /// annoncé en ligne) n'en encadrent qu'un au plus, et ne suffisent pas ; un changement d'éclairage (lumière
    /// qui atteint `maxFlashRunSeconds`) n'en encadre aucun.
    public var hasStrobe: Bool
    /// Durée (secondes) des moments sans lumière les plus courts : 20e centile des durées des moments sans
    /// lumière encadrés par deux battements. `.infinity` sans strobe (`hasStrobe` faux).
    public var shortestDarkGap: Double
    /// Part des images avec lumière, de 0 à 1.
    public var lightFraction: Double

    public init(hasStrobe: Bool, shortestDarkGap: Double, lightFraction: Double) {
        self.hasStrobe = hasStrobe
        self.shortestDarkGap = shortestDarkGap
        self.lightFraction = lightFraction
    }
}

/// Mesure le rythme du stroboscope à partir des verdicts du détecteur de lumière.
public enum StrobeRhythmEstimator {
    /// Moments sans lumière encadrés à voir avant de parler d'un strobe : deux éclairs isolés en donnent un, un
    /// strobe en donne un à chaque battement.
    private static let minimumDarkGaps = 2

    /// `verdicts[i]` est le verdict de l'image prise à `times[i]` (secondes, croissant).
    ///
    /// Un moment avec lumière est une suite maximale d'images `flash`, un moment sans lumière une suite
    /// maximale d'images `good` entre deux moments avec lumière : ceux du début et de la fin, dont on ne voit
    /// pas les deux bords, ne comptent pas. La durée d'un moment va de sa première image à la fin de sa
    /// dernière : `dernier − premier + intervalle`, où l'intervalle est l'écart médian entre deux horodatages
    /// (un trou isolé ne le fausse pas).
    ///
    /// Un moment avec lumière qui atteint `maxFlashRunSeconds` (à `FlashDetectorConfig.runLengthTolerance`
    /// près) n'est pas un battement de strobe mais un changement d'éclairage : le détecteur en ligne annonce la
    /// lumière d'un changement d'éclairage jusqu'à cette limite, puis la garde. Un moment sans lumière ne
    /// compte que s'il est bordé de deux battements. Il en faut au moins deux pour parler d'un strobe.
    ///
    /// Le 20e centile (rang le plus proche) plutôt que le minimum : une image sans lumière isolée au milieu
    /// d'un moment avec lumière, détection imparfaite, ne fait pas croire à un strobe bien plus rapide.
    /// - Parameter maxFlashRunSeconds: durée maximale d'une lumière (`FlashDetectorConfig.maxFlashRunSeconds`
    ///   du détecteur qui a jugé les images).
    public static func estimate(
        times: [Double],
        verdicts: [FrameVerdict],
        maxFlashRunSeconds: Double = FlashDetectorConfig().maxFlashRunSeconds
    ) -> StrobeRhythm {
        precondition(times.count == verdicts.count, "times et verdicts doivent avoir la même longueur")
        guard !verdicts.isEmpty else {
            return StrobeRhythm(hasStrobe: false, shortestDarkGap: .infinity, lightFraction: 0)
        }

        let lightFraction = Double(verdicts.count { $0 == .flash }) / Double(verdicts.count)
        let interval = medianStep(of: times) ?? 0

        // Moments avec lumière, de leur première à leur dernière image.
        var lightRuns: [(first: Int, last: Int)] = []
        for index in verdicts.indices where verdicts[index] == .flash {
            if let run = lightRuns.last, run.last == index - 1 {
                lightRuns[lightRuns.count - 1].last = index
            } else {
                lightRuns.append((index, index))
            }
        }
        /// Vrai pour un battement de strobe : un moment avec lumière qui n'atteint pas `maxFlashRunSeconds`.
        func isFlash(_ run: (first: Int, last: Int)) -> Bool {
            times[run.last] - times[run.first] + interval
                < maxFlashRunSeconds - FlashDetectorConfig.runLengthTolerance
        }

        var darkGaps: [Double] = []
        for (before, after) in zip(lightRuns, lightRuns.dropFirst()) where isFlash(before) && isFlash(after) {
            darkGaps.append(times[after.first - 1] - times[before.last + 1] + interval)
        }

        guard darkGaps.count >= minimumDarkGaps else {
            return StrobeRhythm(hasStrobe: false, shortestDarkGap: .infinity, lightFraction: lightFraction)
        }
        darkGaps.sort()
        // Rang le plus proche du 20e centile, ⌈n / 5⌉, compté à partir de 1.
        let percentile = darkGaps[(darkGaps.count - 1) / 5]
        return StrobeRhythm(hasStrobe: true, shortestDarkGap: percentile, lightFraction: lightFraction)
    }
}
