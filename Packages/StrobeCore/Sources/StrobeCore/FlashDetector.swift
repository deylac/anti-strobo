/// Verdict sur une image : sans la lumière du stroboscope (`good`, gardée) ou avec (`flash`, retirée).
public enum FrameVerdict: Sendable, Equatable, Codable {
    case good
    case flash
}

/// Seuils du détecteur de lumière. Ce sont des points de départ : le réglage fin se fait avec `strobe-tune`.
public struct FlashDetectorConfig: Sendable, Codable, Equatable {
    /// Rapport minimal entre deux lumas pour que la plus claire soit « avec lumière » à côté de l'autre :
    /// `claire ≥ sombre × relativeJump + absoluteMargin`. Sert entre les deux niveaux d'une fenêtre, entre une
    /// image et la médiane de sa fenêtre, et entre une image avec lumière et ses voisines.
    ///
    /// Nom hérité de la V1 (saut d'une image au-dessus de la ligne de base) : c'est toujours le saut relatif
    /// entre « sans lumière » et « avec lumière » (option `strobe-tune --jump`).
    public var relativeJump = 1.6
    /// Marge absolue ajoutée au rapport (évite de prendre le bruit d'une scène très sombre pour de la lumière).
    public var absoluteMargin = 0.04
    /// Part de pixels saturés au-delà de laquelle une image est brûlée, si le niveau bas ne l'est pas déjà.
    public var saturatedFractionMax = 0.25
    /// Durée (secondes) de la fenêtre où l'on cherche deux niveaux de lumière : précédente en ligne,
    /// centrée hors ligne.
    public var baselineWindowSeconds = 0.5
    /// Durée maximale (secondes) d'une période avec lumière : au-delà, c'est un changement d'éclairage, gardé.
    public var maxFlashRunSeconds = 0.3
    /// Quand une fenêtre a deux niveaux de lumière : part de l'écart entre le niveau sans lumière et le niveau
    /// avec lumière au-dessus de laquelle une image est avec lumière (règle V2-R9, entre 0 et 0,5). Une image à
    /// moitié éclairée (lampe qui s'allume ou s'éteint pendant la pose) part ainsi avec la lumière au lieu de
    /// laisser une lueur dans la vidéo nettoyée (option `strobe-tune --edge`).
    public var edgeShare = 0.2
    /// Juge aussi chaque zone de l'image (`FrameStats.zoneLumas`) : une image est avec lumière si l'image entière ou
    /// l'une de ses zones l'est. Une lampe qui clignote dans un coin d'une pièce claire est ainsi retirée, alors que la
    /// luma moyenne bouge à peine (option `strobe-tune --no-zones` pour s'en passer).
    public var watchesZones = true
    /// `relativeJump` des zones (règle des deux niveaux, en ligne comme hors ligne). 1,6, comme l'image entière : elle
    /// y rattrape un stroboscope vif dans un coin, même à pleine vitesse (20 à 30 Hz filmés à 60 i/s, où presque tous
    /// les voisins d'un saut sont des sauts et les paires n'y suffisent pas). À 1,4, une zone qui oscille avec la
    /// main (bord net qui tremble) lui faisait voir deux niveaux et des lumières courtes ; les lampes faibles sont
    /// laissées aux paires de sauts (option `strobe-tune --zone-jump`).
    public var zoneRelativeJump = 1.6
    /// `absoluteMargin` des zones (option `strobe-tune --zone-margin`).
    public var zoneAbsoluteMargin = 0.04
    /// Hors ligne, une zone (et chaque bloc de 2 × 2 zones) est aussi avec lumière d'après ses paires de sauts
    /// (`StepPairDetector`) : un saut vers le haut, puis un saut vers le bas au plus `maxFlashRunSeconds` plus tard,
    /// au rythme d'une lumière qui clignote. Une lampe faible sur une zone qui bouge avec la main échappe aux deux
    /// niveaux, pas à ses sauts (option `strobe-tune --no-steps`).
    public var watchesZoneSteps = true
    /// Un saut de zone s'écarte du pas du mouvement d'au moins ce multiple de sa dispersion, de chaque côté : 4 suit
    /// la lampe de test image après image en la filmant à la main ; 3 joint davantage de phases éteintes, 6 en perd
    /// (option `strobe-tune --step-factor`).
    public var stepMotionFactor = 4.0
    /// …et d'au moins cette luma (4 / 255 : au-dessus du bruit d'une zone, moyenne de milliers de pixels).
    public var stepMinimum = 4.0 / 255
    /// Une paire de sauts ne compte que si la zone en montre une autre, d'ampleur voisine, à moins de ce délai
    /// (secondes) : le rythme d'une lumière qui clignote, pas un faisceau qui passe une fois.
    public var stepRhythmSeconds = 2.0

    public init() {}

    /// Réglages du détecteur d'une zone, sans zones elle-même : rapport `zoneRelativeJump`, marge
    /// `zoneAbsoluteMargin`.
    var forZone: FlashDetectorConfig {
        var config = self
        config.relativeJump = zoneRelativeJump
        config.absoluteMargin = zoneAbsoluteMargin
        config.watchesZones = false
        return config
    }

    /// Vrai si la luma `brighter` est nettement plus claire que `darker` : `brighter ≥ darker × relativeJump +
    /// absoluteMargin`.
    func isDistinctlyBrighter(_ brighter: Double, than darker: Double) -> Bool {
        brighter >= darker * relativeJump + absoluteMargin
    }

    /// Tolérance (secondes) sur la durée d'une période avec lumière : à 30 i/s, une lumière de 10 images
    /// s'étend sur 9/30 = 0,3 s, mais (i + 9)/30 − i/30 vaut parfois 0,30000000000000004 en flottant.
    static let runLengthTolerance = 1e-6

    /// Vrai si une période avec lumière qui s'étend sur `extent` secondes (dernier horodatage moins premier)
    /// dépasse `maxFlashRunSeconds` (à `runLengthTolerance` près) : c'est un changement d'éclairage.
    func isLightingChange(extent: Double) -> Bool {
        extent > maxFlashRunSeconds + Self.runLengthTolerance
    }
}

/// Détecteur de lumière en temps réel : chaque image est jugée à son arrivée, avec les seules images passées.
///
/// La fenêtre contient toutes les images des `baselineWindowSeconds` qui précèdent, avec ou sans lumière,
/// plus l'image jugée : une lumière allumée la moitié du temps y apparaît comme deux niveaux (voir
/// `LightLevels`), et non comme l'éclairage normal. Tant que la fenêtre a trop peu d'images (6, moins à basse
/// cadence : début de flux, après `reset()` ou après un trou), l'image est `good`.
///
/// Sans voir la suite, l'image la plus récente d'une montée de luminosité est toujours la plus claire de sa
/// fenêtre. Une période avec lumière ne commence donc que sur un allumage franc : une image nettement plus
/// claire que la plus sombre des 3 dernières images sans lumière (voir `LightLevels.isSwitchOn`), ou brûlée
/// alors que l'une d'elles ne l'est pas. Elle se poursuit ensuite tant que la fenêtre juge les images avec
/// lumière.
///
/// Une période avec lumière dont l'étendue (dernier horodatage moins premier) dépasse `maxFlashRunSeconds`
/// (voir `FlashDetectorConfig.isLightingChange`) est un changement d'éclairage : les images déjà annoncées `flash` ne peuvent plus être corrigées, mais la
/// fenêtre repart de cette période et l'image courante est `good`.
///
/// Avec `watchesZones`, chaque zone de l'image a son propre détecteur, nourri de chaque image (sa fenêtre reste
/// continue) avec la luma de la zone : l'image est `flash` si l'image entière ou l'une des zones l'est.
public struct OnlineFlashDetector: Sendable {
    private struct Sample: Sendable {
        var time: Double
        var stats: FrameStats
    }

    private let config: FlashDetectorConfig
    /// Images de la fenêtre, de la plus ancienne à la plus récente.
    private var window: [Sample] = []
    /// Période avec lumière en cours, de la plus ancienne à la plus récente image.
    private var lightRun: [Sample] = []
    /// Dernières images jugées `good`, de la plus ancienne à la plus récente : une lumière s'allume par
    /// rapport à elles.
    private var recentUnlit: [FrameStats] = []
    /// Un détecteur par zone (sans zones lui-même), créés à la première image qui en porte ; recréés si leur
    /// nombre change.
    private var zoneDetectors: [OnlineFlashDetector] = []

    public init(config: FlashDetectorConfig = .init()) {
        self.config = config
    }

    /// Juge l'image `s` captée à l'instant `time` (secondes, croissant) : sur toute l'image, puis sur chaque zone.
    public mutating func classify(_ s: FrameStats, at time: Double) -> FrameVerdict {
        var verdict = classifyWholeImage(s, at: time)
        guard config.watchesZones, !s.zoneLumas.isEmpty else { return verdict }

        if zoneDetectors.count != s.zoneLumas.count {
            zoneDetectors = Array(
                repeating: OnlineFlashDetector(config: config.forZone),
                count: s.zoneLumas.count
            )
        }
        // Toutes les zones, même après une première zone avec lumière : chaque fenêtre doit rester continue.
        for zone in zoneDetectors.indices where zoneDetectors[zone].classifyWholeImage(s.zone(zone), at: time) == .flash {
            verdict = .flash
        }
        return verdict
    }

    /// Juge l'image `s` sur sa luma moyenne et sa part saturée seulement.
    private mutating func classifyWholeImage(_ s: FrameStats, at time: Double) -> FrameVerdict {
        // Les zones ont leurs propres détecteurs : la fenêtre n'en garde pas de copie.
        let s = s.withoutZones
        let sample = Sample(time: time, stats: s)

        let windowStart = time - config.baselineWindowSeconds
        window.removeAll { $0.time < windowStart }
        window.append(sample)

        // Fenêtre calme : aucune de ses images ne peut être avec lumière (`LightLevels.cannotLightAnyFrame`). Même
        // verdict que le chemin complet, sans trier la fenêtre ; c'est le cas de presque toutes les zones.
        var lowest = Double.infinity
        var highest = -Double.infinity
        var mostSaturated = 0.0
        for entry in window {
            lowest = min(lowest, entry.stats.meanLuma)
            highest = max(highest, entry.stats.meanLuma)
            mostSaturated = max(mostSaturated, entry.stats.saturatedFraction)
        }
        if LightLevels.cannotLightAnyFrame(
            lowest: lowest, highest: highest, mostSaturated: mostSaturated, config: config
        ) {
            lightRun.removeAll(keepingCapacity: true)
            noteUnlit(s)
            return .good
        }

        let minimumFrames = LightLevels.minimumFrames(
            windowSeconds: config.baselineWindowSeconds,
            frameStep: medianStep(of: window.map(\.time))
        )
        guard let levels = LightLevels(of: window.map(\.stats), minimumFrames: minimumFrames, config: config),
              levels.isLitByLuma(s) || levels.isLitBySaturation(s),
              !lightRun.isEmpty || switchesLightOn(s, levels: levels)
        else {
            lightRun.removeAll(keepingCapacity: true)
            noteUnlit(s)
            return .good
        }

        let runStart = lightRun.first?.time ?? time
        guard !config.isLightingChange(extent: time - runStart) else {
            // Trop long pour un strobe : c'est le nouvel éclairage. Sans cela, l'ancien niveau, encore dans la
            // fenêtre, ferait passer toutes les images suivantes pour de la lumière.
            window = lightRun + [sample]
            lightRun.removeAll(keepingCapacity: true)
            noteUnlit(s)
            return .good
        }

        lightRun.append(sample)
        return .flash
    }

    /// Images sans lumière gardées pour juger un allumage. Plusieurs, et la plus sombre compte : une ou deux
    /// images à moitié éclairées au début d'un allumage (obturateur roulant), trop peu claires pour être de la
    /// lumière, ne doivent pas servir de référence à la lumière qui suit. Sur 3 images, une montée douce ne
    /// bouge presque pas.
    private static let unlitReferenceFrames = 3

    /// Une lumière s'allume d'un coup : la première image d'une période avec lumière doit être nettement plus
    /// claire que la plus sombre des dernières images sans lumière (`LightLevels.isSwitchOn`), ou brûlée alors
    /// que l'une d'elles ne l'est pas. Une lumière qui monte doucement (projecteur qui « respire ») n'est donc
    /// jamais allumée, même si l'image la plus récente d'une montée est toujours la plus claire de sa fenêtre.
    private func switchesLightOn(_ s: FrameStats, levels: LightLevels) -> Bool {
        guard let darkest = recentUnlit.min(by: { $0.meanLuma < $1.meanLuma }) else { return true }
        if levels.isLitByLuma(s), levels.isSwitchOn(from: darkest.meanLuma, to: s.meanLuma) { return true }
        return levels.isLitBySaturation(s) && recentUnlit.contains { !levels.isBurnt($0) }
    }

    private mutating func noteUnlit(_ s: FrameStats) {
        recentUnlit.append(s)
        if recentUnlit.count > Self.unlitReferenceFrames { recentUnlit.removeFirst() }
    }

    /// Ramène les images déjà vues à une nouvelle exposition, choisie volontairement : leurs lumas sont
    /// multipliées par `factor` (rapport des lumas attendu entre la nouvelle exposition et l'ancienne) et
    /// bornées à 0…1, comme le serait une vraie image. Les deux niveaux d'une lumière qui clignote survivent
    /// ainsi au changement, au lieu de repartir de rien comme après `reset()`. La part de pixels saturés n'est
    /// pas recalculée : elle ne peut pas l'être à partir de la seule luma moyenne.
    public mutating func rescale(by factor: Double) {
        func rescaled(_ stats: FrameStats) -> FrameStats {
            var stats = stats
            stats.meanLuma = min(1, max(0, stats.meanLuma * factor))
            return stats
        }
        window = window.map { Sample(time: $0.time, stats: rescaled($0.stats)) }
        lightRun = lightRun.map { Sample(time: $0.time, stats: rescaled($0.stats)) }
        recentUnlit = recentUnlit.map(rescaled)
        for zone in zoneDetectors.indices { zoneDetectors[zone].rescale(by: factor) }
    }

    /// Oublie tout l'historique, zones comprises : le prochain appel repart comme sur un détecteur neuf.
    public mutating func reset() {
        window.removeAll(keepingCapacity: true)
        lightRun.removeAll(keepingCapacity: true)
        recentUnlit.removeAll(keepingCapacity: true)
        zoneDetectors.removeAll()
    }
}

/// Détecteur de lumière hors ligne : toutes les images sont connues, la fenêtre est centrée sur chacune.
public enum OfflineFlashDetector {
    /// Juge chaque image de `stats` (`times[i]` est l'horodatage en secondes de `stats[i]`, croissant).
    ///
    /// La fenêtre d'une image contient toutes les images dans les `baselineWindowSeconds` centrées sur elle
    /// (elle comprise). L'image est `flash` si sa fenêtre la juge avec lumière (voir `LightLevels`), sauf si
    /// cette lumière dure plus de `maxFlashRunSeconds` (c'est alors un changement d'éclairage), ou si l'image est
    /// un moment sans lumière entre deux lumières, que le mouvement a éclairci (`isDarkMomentBetweenLights`).
    ///
    /// La durée de la lumière se mesure sur les images elles-mêmes, au niveau de l'image jugée, et non sur la
    /// suite des verdicts : ses voisines contiguës gardent la lumière allumée tant qu'elles ne sont pas
    /// nettement plus sombres qu'elle (même rapport et même marge) ni, avec deux niveaux, sans lumière (sous la
    /// part `edgeShare` de l'écart, règle V2-R9), ou, pour une image retenue par sa saturation, tant qu'elles
    /// sont brûlées. Ainsi :
    /// - après une marche de luminosité, la fenêtre centrée ne voit l'ancien niveau que pendant une
    ///   demi-fenêtre (0,25 s) et la suite de verdicts resterait sous 0,3 s, alors que la nouvelle lumière dure ;
    /// - un éclair posé sur le niveau haut d'une marche (la marche impose la coupure) ne dure qu'une image,
    ///   même si ce niveau haut, lui, dure.
    ///
    /// Avec `watchesZones`, quand toutes les images portent le même nombre de zones, chaque zone est jugée sur sa luma
    /// (sans part saturée) par les mêmes règles que l'image entière (rapport `zoneRelativeJump`) et, avec
    /// `watchesZoneSteps`, par ses paires de sauts (voir `StepPairDetector`), comme chaque bloc de 2 × 2 zones. Une
    /// image est `flash` si l'image entière ou l'une de ses zones (ou l'un de ses blocs) l'est.
    ///
    /// Sauf quand la lumière de la zone est celle de la pièce (règles V2-R24 et V2-R26) : l'image est sans lumière pour
    /// la pièce (gardée par l'image entière, pas même à moitié éclairée, et hors des éclairs de `RoomLight`) entre deux
    /// éclairs de la pièce (de l'image entière ou de `RoomLight`) à moins de `maxFlashRunSeconds` de chaque côté, plus
    /// sombre qu'eux, et la zone n'y est pas nettement plus claire (rapport `zoneRelativeJump`, marge
    /// `zoneAbsoluteMargin`) que ce que la lampe allumée éclairait à ces deux éclairs dans la zone et dans ses voisines
    /// (décalées d'une zone, dans la grille de `LumaSampler` ; un bloc, dans les blocs décalés d'une zone). La lampe
    /// qui éclaire la pièce est alors éteinte : le mouvement (la main, les pas, la caméra qui bouge) fait à la zone des
    /// niveaux et des sauts, y amène même d'un coup un fond clair ou un reflet, mais ils viennent d'à côté, où ils
    /// étaient au moins aussi clairs aux éclairs ; un reflet à cheval sur deux zones aux éclairs, ramené dans une
    /// seule, y monte sans doubler. Une autre lumière qui s'allume dans la zone pendant que la pièce est éteinte la
    /// rend nettement plus claire que la lampe ne rendait ses alentours : elle reste vue, sauf à côté d'un endroit que
    /// la lampe rendait déjà presque aussi clair. Une autre lumière déjà allumée à l'éclair de la pièce, sans monter
    /// ensuite, n'est plus vue pendant cette extinction. Cette image ne sert pas non plus de bord à la zone, sauf si
    /// elle touche un éclair de la pièce : la lampe qui s'éteint ou s'allume pendant la pose y laisse ses diodes
    /// allumées dans une pièce déjà sombre (essais du 7 novembre à 15 h 45). La lentille de la lampe ne couvre qu'une
    /// petite part de sa zone : sa lueur n'y pèse pas plus que le mouvement, qui fait aussi partir quelques premières
    /// images éteintes.
    ///
    /// Enfin, les bords (règle V2-R9 étendue) : une image gardée, collée à une image `flash`, part aussi si l'image
    /// entière ou l'une de ses zones (les 64 premières) la voit à moitié éclairée : sa fenêtre la juge avec
    /// lumière, sa luma est sous celle de l'image `flash` et dépasse d'au moins `absoluteMargin` celle de sa voisine
    /// de l'autre côté, gardée. C'est une lampe qui s'allume ou s'éteint pendant la pose, ou qui passe d'une zone à
    /// l'autre. Sa propre période avec lumière, mesurée depuis elle, pouvait sembler trop longue : les images
    /// éteintes qui suivent ne sont pas nettement plus sombres qu'une image à moitié éclairée, surtout quand le
    /// mouvement fait remonter leur niveau ; et la lumière qu'elle borde peut n'être confirmée que dans une zone
    /// voisine. Une image au niveau de sa voisine gardée (palier d'une marche d'éclairage à côté d'un éclair) n'est
    /// pas un bord. Une seule image de chaque côté : le bord ajouté ne sert pas de point de départ à un autre.
    public static func classify(
        _ stats: [FrameStats],
        times: [Double],
        config: FlashDetectorConfig = .init()
    ) -> [FrameVerdict] {
        classify(stats, times: times, config: config) { _, _ in }
    }

    /// Comme `classify(_:times:config:)`, en appelant `afterEachZone(finies, total)` après chaque zone jugée :
    /// avancement, et occasion d'annuler (une erreur levée arrête le jugement et remonte à l'appelant).
    public static func classify(
        _ stats: [FrameStats],
        times: [Double],
        config: FlashDetectorConfig = .init(),
        afterEachZone: (_ finished: Int, _ total: Int) throws -> Void
    ) rethrows -> [FrameVerdict] {
        precondition(stats.count == times.count, "stats et times doivent avoir la même longueur")

        let whole = classifyWholeImages(stats, times: times, config: config, mayBeSaturated: true)
        var verdicts = whole.verdicts
        /// Bit `z` : la fenêtre de la zone `z` juge l'image avec lumière (zones 0 à 63).
        var zonesLitByLuma = [UInt64](repeating: 0, count: stats.count)
        let zoneConfig = config.forZone
        let zoneCount = config.watchesZones ? (stats.first?.zoneLumas.count ?? 0) : 0
        let watchesZones = zoneCount > 0 && stats.allSatisfy { $0.zoneLumas.count == zoneCount }

        // Blocs de 2 × 2 zones voisines, qui se chevauchent (grille de LumaSampler seulement) : une lampe à cheval sur
        // deux zones, ou qui passe de l'une à l'autre pendant qu'elle est allumée, monte dans l'une et redescend dans
        // l'autre ; un bloc qui les couvre toutes les deux voit les deux sauts. Jugés par leurs sauts seulement.
        let columns = LumaSampler.zoneColumns
        let rows = LumaSampler.zoneRows
        let isGrid = zoneCount == columns * rows
        let blocks = watchesZones && config.watchesZoneSteps && isGrid
            ? (0..<(rows - 1)).flatMap { row in (0..<(columns - 1)).map { row * columns + $0 } }
            : []
        let total = (watchesZones ? zoneCount : 0) + blocks.count

        if watchesZones {
            let roomLit = RoomLight.litFrames(stats, times: times, config: zoneConfig)
            let roomOff = roomOffMoments(
                lights: stats.indices.map { whole.verdicts[$0] == .flash || roomLit[$0] },
                halfLit: whole.litByLuma,
                lumas: stats.map(\.meanLuma),
                times: times,
                config: config
            )
            /// Vrai si l'image `index`, sans lumière pour la pièce, touche l'un de ses éclairs.
            func isNextToRoomLight(_ index: Int) -> Bool {
                guard let lights = roomOff[index] else { return false }
                return lights.before == index - 1 || lights.after == index + 1
            }
            /// Luma moyenne, à l'image `frame`, du carré de `size` × `size` zones dont `corner` est le coin en haut à
            /// gauche (une zone seule pour `size` 1).
            func squareLuma(at frame: Int, corner: Int, size: Int) -> Double {
                let zones = stats[frame].zoneLumas
                var sum = 0
                for row in 0..<size {
                    for column in 0..<size { sum += Int(zones[corner + row * columns + column]) }
                }
                return Double(sum) / Double(size * size)
            }
            /// Le carré de `size` × `size` zones de coin `corner` et ceux décalés d'une zone autour de lui, dans la
            /// grille ; le carré seul hors de la grille de `LumaSampler`.
            func nearbySquares(_ corner: Int, size: Int) -> [Int] {
                guard isGrid else { return [corner] }
                let row = corner / columns
                let column = corner % columns
                return (max(0, row - 1)...min(rows - size, row + 1)).flatMap { row in
                    (max(0, column - 1)...min(columns - size, column + 1)).map { row * columns + $0 }
                }
            }
            /// Vrai si, à l'image `index`, le carré de `size` × `size` zones de coin `corner` suit la lampe de la
            /// pièce, éteinte (V2-R26) : il n'est pas nettement plus clair que ce que la lampe allumée éclairait là et
            /// autour, aux deux éclairs de la pièce qui encadrent l'image.
            func followsTheRoom(_ index: Int, corner: Int, size: Int) -> Bool {
                guard let lights = roomOff[index] else { return false }
                let lamp = nearbySquares(corner, size: size).flatMap { square in
                    [lights.before, lights.after].map { squareLuma(at: $0, corner: square, size: size) }
                }.max() ?? 0
                let luma = squareLuma(at: index, corner: corner, size: size)
                return !zoneConfig.isDistinctlyBrighter(luma / 255, than: lamp / 255)
            }
            // Une zone à la fois : une seule série de lumas en mémoire, même pour une longue vidéo.
            for zone in 0..<zoneCount {
                let judged = classifyWholeImages(
                    stats.map { $0.zone(zone) }, times: times, config: zoneConfig, mayBeSaturated: false
                )
                let steps = config.watchesZoneSteps
                    ? StepPairDetector.litFrames(stats.map { $0.zoneLumas[zone] }, times: times, config: zoneConfig)
                    : nil
                for index in stats.indices {
                    let lit = judged.verdicts[index] == .flash || steps?[index] == true
                    guard lit || judged.litByLuma[index] else { continue }
                    let follows = followsTheRoom(index, corner: zone, size: 1)
                    if lit, !follows { verdicts[index] = .flash }
                    if zone < 64, judged.litByLuma[index], !follows || isNextToRoomLight(index) {
                        zonesLitByLuma[index] |= 1 << UInt64(zone)
                    }
                }
                try afterEachZone(zone + 1, total)
            }
            for (number, corner) in blocks.enumerated() {
                let lumas = stats.map { frame in
                    let zones = frame.zoneLumas
                    let sum = Int(zones[corner]) + Int(zones[corner + 1])
                        + Int(zones[corner + columns]) + Int(zones[corner + columns + 1])
                    return UInt8((Double(sum) / 4).rounded())
                }
                let lit = StepPairDetector.litFrames(lumas, times: times, config: zoneConfig)
                for index in stats.indices where lit[index] && !followsTheRoom(index, corner: corner, size: 2) {
                    verdicts[index] = .flash
                }
                try afterEachZone(zoneCount + number + 1, total)
            }
        }

        let confirmed = verdicts
        for index in stats.indices.dropFirst().dropLast() where confirmed[index] == .good {
            if whole.litByLuma[index],
               isEdge(index, confirmed: confirmed, margin: config.absoluteMargin, luma: { stats[$0].meanLuma }) {
                verdicts[index] = .flash
                continue
            }
            var zones = zonesLitByLuma[index]
            while zones != 0 {
                let zone = zones.trailingZeroBitCount
                zones &= zones - 1
                if isEdge(index, confirmed: confirmed, margin: zoneConfig.absoluteMargin, luma: {
                    Double(stats[$0].zoneLumas[zone]) / 255
                }) {
                    verdicts[index] = .flash
                    break
                }
            }
        }
        return verdicts
    }

    /// Pour chaque image sans lumière pour la pièce (ni dans `lights`, ni à moitié éclairée pour l'image entière,
    /// `halfLit`) entre deux images de `lights` à moins de `maxFlashRunSeconds` de chaque côté, et plus sombre
    /// qu'elles (luma de l'image entière, `lumas`) : les plus proches de ces deux images ; `nil` sinon. Une image plus
    /// claire que les éclairs qui l'entourent n'est pas éteinte : c'est un éclair que ni l'image entière ni
    /// `RoomLight` n'a vu (essai sur iPhone du 7 novembre à 15 h, images 925 à 931).
    static func roomOffMoments(
        lights: [Bool],
        halfLit: [Bool],
        lumas: [Double],
        times: [Double],
        config: FlashDetectorConfig
    ) -> [(before: Int, after: Int)?] {
        let count = lights.count
        let reach = config.maxFlashRunSeconds + FlashDetectorConfig.runLengthTolerance
        var before = [Int?](repeating: nil, count: count)
        var last: Int?
        for index in 0..<count {
            if lights[index] { last = index }
            before[index] = last
        }
        var moments = [(before: Int, after: Int)?](repeating: nil, count: count)
        var next: Int?
        for index in (0..<count).reversed() {
            if lights[index] { next = index }
            guard !lights[index], !halfLit[index],
                  let previous = before[index], let following = next,
                  times[index] - times[previous] <= reach, times[following] - times[index] <= reach,
                  lumas[index] < min(lumas[previous], lumas[following])
            else { continue }
            moments[index] = (previous, following)
        }
        return moments
    }

    /// Vrai si l'image `index` (gardée) est le bord d'une lumière dans la série `luma` : d'un côté une image `flash`
    /// plus claire qu'elle, de l'autre une image gardée plus sombre d'au moins `margin`.
    private static func isEdge(
        _ index: Int,
        confirmed: [FrameVerdict],
        margin: Double,
        luma: (Int) -> Double
    ) -> Bool {
        let own = luma(index)
        return [(index - 1, index + 1), (index + 1, index - 1)].contains { flash, other in
            confirmed[flash] == .flash && luma(flash) > own && confirmed[other] == .good && own - luma(other) >= margin
        }
    }

    /// Juge chaque image sur sa luma moyenne et sa part saturée seulement. `litByLuma` : la fenêtre de l'image la
    /// juge avec lumière par sa luma, que cette lumière dure trop ou non.
    ///
    /// Sans part saturée (`mayBeSaturated` faux : les zones), une fenêtre calme ne peut juger aucune image avec
    /// lumière (`LightLevels.cannotLightAnyFrame`) : le minimum et le maximum glissants de ses lumas, tenus dans deux
    /// files monotones, suffisent, sans la trier. C'est le cas de presque toutes les zones, presque tout le temps.
    private static func classifyWholeImages(
        _ stats: [FrameStats],
        times: [Double],
        config: FlashDetectorConfig,
        mayBeSaturated: Bool
    ) -> (verdicts: [FrameVerdict], litByLuma: [Bool]) {
        let count = stats.count
        var verdicts = [FrameVerdict](repeating: .good, count: count)
        let halfWindow = config.baselineWindowSeconds / 2
        let minimumFrames = LightLevels.minimumFrames(
            windowSeconds: config.baselineWindowSeconds,
            frameStep: medianStep(of: times)
        )

        var litByLuma = [Bool](repeating: false, count: count)
        var lowest = SlidingExtreme(of: stats) { $0 <= $1 }
        var highest = SlidingExtreme(of: stats) { $0 >= $1 }

        // Fenêtre glissante [lower, upper) : toujours bornée par l'image courante, même si `times` n'est pas trié.
        var lower = 0
        var upper = 0
        for index in 0..<count {
            while lower < index, times[lower] < times[index] - halfWindow { lower += 1 }
            upper = max(upper, index + 1)
            while upper < count, times[upper] <= times[index] + halfWindow { upper += 1 }

            if !mayBeSaturated,
               LightLevels.cannotLightAnyFrame(
                   lowest: lowest.value(in: lower..<upper),
                   highest: highest.value(in: lower..<upper),
                   mostSaturated: 0,
                   config: config
               ) {
                continue
            }

            guard let levels = LightLevels(of: stats[lower..<upper], minimumFrames: minimumFrames, config: config)
            else { continue }
            let frame = stats[index]
            litByLuma[index] = levels.isLitByLuma(frame)

            let lumaLight = litByLuma[index]
                && !levels.isDarkMomentBetweenLights(index, times: times) { stats[$0].meanLuma }
                && !lightLastsTooLong(around: index, times: times, config: config) { neighbour in
                    levels.keepsLumaLightOn(stats[neighbour], litFrame: frame)
                }
            let burntLight = levels.isLitBySaturation(frame)
                && !lightLastsTooLong(around: index, times: times, config: config) { neighbour in
                    levels.isBurnt(stats[neighbour])
                }
            if lumaLight || burntLight {
                verdicts[index] = .flash
            }
        }
        return (verdicts, litByLuma)
    }

    /// Minimum (ou maximum) glissant des lumas d'une série, pour des fenêtres dont les deux bornes ne reculent jamais :
    /// file monotone d'indices, chaque image y entre et en sort au plus une fois.
    private struct SlidingExtreme {
        private let lumas: [Double]
        /// Vrai si la luma de gauche l'emporte sur celle de droite (`<=` : minimum ; `>=` : maximum).
        private let wins: (Double, Double) -> Bool
        private var queue: [Int] = []
        private var head = 0
        private var next = 0

        init(of stats: [FrameStats], wins: @escaping (Double, Double) -> Bool) {
            lumas = stats.map(\.meanLuma)
            self.wins = wins
        }

        /// L'extrême des lumas de `window` (non vide), dont les bornes ne reculent pas d'un appel à l'autre.
        mutating func value(in window: Range<Int>) -> Double {
            while next < window.upperBound {
                while queue.count > head, wins(lumas[next], lumas[queue[queue.count - 1]]) { queue.removeLast() }
                queue.append(next)
                next += 1
            }
            while queue[head] < window.lowerBound { head += 1 }
            if head > 4_096, head * 2 > queue.count {
                queue.removeFirst(head)
                head = 0
            }
            return lumas[queue[head]]
        }
    }

    /// Vrai si la période avec lumière qui contient l'image `index` (elle et ses voisines contiguës pour
    /// lesquelles `isOn` est vrai) s'étend sur plus de `maxFlashRunSeconds` (`isLightingChange`).
    private static func lightLastsTooLong(
        around index: Int,
        times: [Double],
        config: FlashDetectorConfig,
        isOn: (Int) -> Bool
    ) -> Bool {
        var first = index
        var last = index
        while first > 0, isOn(first - 1) {
            first -= 1
            if config.isLightingChange(extent: times[last] - times[first]) { return true }
        }
        while last + 1 < times.count, isOn(last + 1) {
            last += 1
            if config.isLightingChange(extent: times[last] - times[first]) { return true }
        }
        return false
    }
}
