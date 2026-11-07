/// Choisit la cadence de prise de vue (images par seconde) quand la scène est trop sombre.
///
/// À 120 i/s, chaque image n'a droit qu'à 1/120 s de lumière. Une cadence plus basse allonge la pose permise
/// (1/60 s à 60 i/s, 1/30 s à 30 i/s), donc éclaircit les images, mais n'en met que moins dans chaque moment
/// sans lumière du stroboscope : or il faut en garder assez pour pouvoir retirer le strobe.
///
/// Logique pure, sans accès à la caméra.
public enum CadencePlanner {
    /// Marge de calcul sur `durée × cadence ≥ images minimales` : `0,1666… × 30` ne doit pas tomber à
    /// `4,9999…` et refuser les 5 images exactes.
    private static let roundingMargin = 1e-9

    /// La cadence à laquelle passer, ou `nil` pour rester à `current`.
    ///
    /// On ne descend que si `reachedMaximum` : l'exposition est déjà au maximum de la cadence actuelle et la
    /// scène y est encore trop sombre. Les candidates sont les cadences de `available` strictement sous
    /// `current` (doublons et ordre sans importance). Une candidate `c` est permise :
    /// - avec un strobe mesuré, si chaque moment sans lumière y garde au moins `minimumFramesPerDarkGap` images
    ///   propres : `rhythm.shortestDarkGap × c ≥ minimumFramesPerDarkGap + 1` (règle V2-R7 : selon la phase du
    ///   strobe, une image à cheval sur l'allumage ou l'extinction est perdue) ;
    /// - sans strobe, si `c ≥ minimumWithoutStrobe` : on ne descend pas plus bas pour pouvoir retirer un strobe
    ///   qui démarrerait pendant l'enregistrement.
    ///
    /// On prend la plus basse cadence permise, celle qui donne le plus de lumière.
    ///
    /// - Parameters:
    ///   - current: la cadence actuelle, en images par seconde.
    ///   - available: les cadences que l'appareil sait filmer.
    ///   - reachedMaximum: `ExposureMeter.reachedMaximum`.
    ///   - rhythm: `ExposureMeter.rhythm`.
    ///   - minimumFramesPerDarkGap: images propres à garder, au moins, dans le moment sans lumière le plus
    ///     court (il en faut une de plus en tout).
    ///   - minimumWithoutStrobe: cadence minimale quand aucun strobe n'a été vu.
    public static func nextCadence(
        current: Double,
        available: [Double],
        reachedMaximum: Bool,
        rhythm: StrobeRhythm,
        minimumFramesPerDarkGap: Int = 4,
        minimumWithoutStrobe: Double = 60
    ) -> Double? {
        guard reachedMaximum else { return nil }

        return available
            .filter { $0 < current }
            .filter { cadence in
                if rhythm.hasStrobe {
                    return rhythm.shortestDarkGap * cadence >= Double(minimumFramesPerDarkGap + 1) - roundingMargin
                }
                return cadence >= minimumWithoutStrobe
            }
            .min()
    }
}
