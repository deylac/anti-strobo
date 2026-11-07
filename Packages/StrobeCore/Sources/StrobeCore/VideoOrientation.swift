import CoreGraphics

/// Orientation d'affichage d'un film dont les images sont écrites dans le sens du capteur.
public enum VideoOrientation {
    /// Le nombre de quarts de tour dans le sens horaire (0…3) le plus proche de `degrees`.
    ///
    /// L'angle est d'abord ramené dans 0..<360 (−90° vaut 270°). Un demi-quart pile (45°, 135°, 225°, 315°)
    /// va au quart suivant dans le sens horaire (45° → 90°, 315° → 0°). Un angle non fini vaut 0.
    public static func quarterTurns(clockwiseDegrees degrees: Double) -> Int {
        guard degrees.isFinite else { return 0 }
        var normalized = degrees.truncatingRemainder(dividingBy: 360)
        if normalized < 0 { normalized += 360 }
        return Int((normalized / 90).rounded(.toNearestOrAwayFromZero)) % 4
    }

    /// La `preferredTransform` qui affiche droites des images de `width` × `height` à tourner de `degrees`
    /// dans le sens horaire (arrondi au quart de tour comme `quarterTurns`). La translation ramène l'image
    /// transformée en (0, 0), comme dans les films de l'appareil photo (portrait : `[0 1 −1 0 hauteur 0]`).
    public static func preferredTransform(rotatingClockwise degrees: Double, width: Int, height: Int) -> CGAffineTransform {
        let width = CGFloat(width)
        let height = CGFloat(height)
        switch quarterTurns(clockwiseDegrees: degrees) {
        case 1: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case 3: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        default: return .identity
        }
    }
}
