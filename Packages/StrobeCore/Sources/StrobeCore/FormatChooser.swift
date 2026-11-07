/// Un format de capture de la caméra, réduit à ce qui compte pour le choix : sans dépendance à AVFoundation,
/// pour que le choix reste testable. `index` est la position du format dans la liste de l'appareil.
public struct CameraFormatInfo: Sendable, Equatable {
    /// Position du format dans la liste fournie par l'appareil (renvoyée telle quelle par `FormatChooser`).
    public var index: Int
    public var width: Int
    public var height: Int
    /// Cadence maximale du format, en images par seconde.
    public var maxFPS: Double

    public init(index: Int, width: Int, height: Int, maxFPS: Double) {
        self.index = index
        self.width = width
        self.height = height
        self.maxFPS = maxFPS
    }
}

/// Une plage de cadences d'un format de caméra, en images par seconde (une `AVFrameRateRange`, sans
/// dépendance à AVFoundation).
public struct FrameRateRange: Sendable, Equatable {
    public var minFPS: Double
    public var maxFPS: Double

    public init(minFPS: Double, maxFPS: Double) {
        self.minFPS = minFPS
        self.maxFPS = maxFPS
    }

    /// Vrai si la plage permet `fps`, bornes et cadence arrondies à l'entier : un format à 119,88 i/s permet
    /// 120 i/s. Une borne ou une cadence non numérique (NaN) ne permet rien, une plage à l'envers non plus.
    public func allows(_ fps: Double) -> Bool {
        let wanted = fps.rounded()
        return minFPS.rounded() <= wanted && wanted <= maxFPS.rounded()
    }
}

/// Un format SDR 8 bits 4:2:0 où la mesure peut passer en changeant de cadence, réduit à ce qui compte pour ce
/// choix (voir `FormatChooser.formatForCadence`).
public struct CadenceFormat: Sendable, Equatable {
    /// Position du format dans la liste fournie par l'appareil.
    public var index: Int
    public var width: Int
    public var height: Int
    /// Pleine plage (420f, comme la sortie) plutôt que plage vidéo (420v).
    public var isFullRange: Bool
    public var frameRates: [FrameRateRange]
    /// ISO maximal du format : le gain que la caméra peut donner à une scène sombre.
    public var maxISO: Double

    public init(index: Int, width: Int, height: Int, isFullRange: Bool, frameRates: [FrameRateRange], maxISO: Double) {
        self.index = index
        self.width = width
        self.height = height
        self.isFullRange = isFullRange
        self.frameRates = frameRates
        self.maxISO = maxISO
    }
}

/// Choisit le format de capture et la cadence à demander à la caméra.
public enum FormatChooser {
    /// Les cadences entre lesquelles la mesure peut choisir (voir `CadencePlanner`), de la plus haute à la
    /// plus basse : à chaque pas, la pose permise double.
    public static let cadenceSteps: [Double] = [120, 60, 30]

    /// Les cadences de `cadenceSteps` permises par au moins une des plages (voir `FrameRateRange.allows`), de
    /// la plus haute à la plus basse, quel que soit l'ordre des plages.
    /// - Parameter ranges: plages de cadences d'un format, ou de tous les formats d'une même résolution.
    public static func availableCadences(in ranges: [FrameRateRange]) -> [Double] {
        cadenceSteps.filter { fps in ranges.contains { $0.allows(fps) } }
    }

    /// Hauteur visée : la 1080p.
    private static let targetHeight = 1080

    /// Cadence visée : 120 i/s. V1 n'utilise pas 240 i/s (image plus bruitée en salle sombre), même quand
    /// un format l'offre.
    private static let primaryFPS = 120.0

    /// Cadence de repli quand aucun format n'offre 120 i/s.
    private static let secondaryFPS = 60.0

    /// Cadence plafond du dernier recours.
    private static let lastResortFPS = 30.0

    /// Choisit un format et la cadence à lui demander.
    ///
    /// La cadence est choisie d'abord, puis la hauteur parmi les formats qui l'offrent :
    /// 1. au moins un format offre 120 i/s ou plus : cadence 120, parmi les formats qui l'offrent ;
    /// 2. sinon, au moins un format offre 60 i/s ou plus : cadence 60, parmi les formats qui l'offrent ;
    /// 3. sinon : cadence `min(maxFPS, 30)` du format choisi, parmi les formats d'au moins 30 i/s ou, faute
    ///    d'un seul, parmi tous les formats.
    ///
    /// Hauteur : 1080 si elle existe, sinon la plus grande hauteur inférieure à 1080, sinon la plus petite
    /// hauteur au-dessus. À hauteur égale, le format le plus large l'emporte (1920×1080 plutôt que le
    /// 1440×1080 en 4:3), puis l'`index` le plus bas, quel que soit l'ordre de la liste.
    ///
    /// Un format inutilisable (hauteur nulle ou négative, cadence maximale nulle, négative ou non finie) est
    /// ignoré.
    /// - Parameter formats: formats proposés par l'appareil.
    /// - Returns: l'`index` du format et la cadence à utiliser, ou `nil` s'il n'y a aucun format utilisable.
    public static func choose(_ formats: [CameraFormatInfo]) -> (index: Int, fps: Double)? {
        let usable = formats.filter { $0.height > 0 && $0.maxFPS.isFinite && $0.maxFPS > 0 }

        for fps in [primaryFPS, secondaryFPS] {
            if let best = bestHeight(in: usable.filter { $0.maxFPS >= fps }) {
                return (best.index, fps)
            }
        }

        let capable = usable.filter { $0.maxFPS >= lastResortFPS }
        guard let best = bestHeight(in: capable.isEmpty ? usable : capable) else { return nil }
        return (best.index, min(best.maxFPS, lastResortFPS))
    }

    /// L'`index` du format où filmer à `fps` sans changer de résolution, ou `nil` si aucun ne le permet.
    ///
    /// Parmi les `formats` de la taille de `current` qui permettent `fps` (`FrameRateRange.allows`), celui dont
    /// l'ISO maximal est le plus haut : la mesure ne baisse la cadence que pour une scène trop sombre, et sur
    /// l'iPhone 17 Pro Max les formats 1080p qui ne vont pas au-delà de 60 i/s montent à ISO 5184, contre 3456 pour
    /// ceux qui vont jusqu'à 120. À ISO maximal égal : `current` (seule la durée d'image change, la session n'est
    /// pas reconfigurée), puis la pleine plage, puis l'`index` le plus bas.
    public static func formatForCadence(_ fps: Double, current: CadenceFormat, among formats: [CadenceFormat]) -> Int? {
        formats
            .filter { format in
                format.width == current.width && format.height == current.height
                    && format.frameRates.contains { $0.allows(fps) }
            }
            .min { lhs, rhs in
                (-lhs.maxISO, lhs.index == current.index ? 0 : 1, lhs.isFullRange ? 0 : 1, lhs.index)
                    < (-rhs.maxISO, rhs.index == current.index ? 0 : 1, rhs.isFullRange ? 0 : 1, rhs.index)
            }?
            .index
    }

    /// Le format de meilleure hauteur (voir `choose`), ou `nil` si `candidates` est vide.
    private static func bestHeight(in candidates: [CameraFormatInfo]) -> CameraFormatInfo? {
        candidates.min(by: isPreferred)
    }

    /// `true` si `lhs` est un meilleur choix que `rhs` : sous la hauteur visée avant au-dessus, la plus
    /// grande hauteur en dessous, la plus petite au-dessus, puis la plus grande largeur, puis l'`index` le
    /// plus bas.
    private static func isPreferred(_ lhs: CameraFormatInfo, over rhs: CameraFormatInfo) -> Bool {
        let lhsAbove = lhs.height > targetHeight
        let rhsAbove = rhs.height > targetHeight
        if lhsAbove != rhsAbove { return !lhsAbove }
        if lhs.height != rhs.height { return lhsAbove ? lhs.height < rhs.height : lhs.height > rhs.height }
        if lhs.width != rhs.width { return lhs.width > rhs.width }
        return lhs.index < rhs.index
    }
}
