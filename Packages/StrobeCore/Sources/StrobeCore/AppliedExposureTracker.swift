import CoreMedia

/// Dit avec quelle exposition chaque image a été prise, d'après les demandes faites à la caméra et le moment
/// où chacune s'applique : l'horodatage de la première image prise avec elle (le `syncTime` d'AVFoundation,
/// ramené à l'horloge des images).
///
/// L'exposition attribuée est exactement celle qui a été demandée (la cible du mesureur) : la correspondance
/// à 5 % d'`ExposureMeter` ne dépend ainsi ni des arrondis de l'appareil ni de ceux de l'EXIF. Seules la
/// dernière demande appliquée et la précédente sont gardées ; avant la première demande appliquée, c'est
/// l'exposition lue sur l'appareil au début de la mesure. Les instants sont comparés en `CMTime`, sans
/// passer par des secondes arrondies.
public struct AppliedExposureTracker: Sendable {
    private var latest: (exposure: Exposure, syncTime: CMTime)?
    private var previous: Exposure

    /// - Parameter deviceExposure: exposition lue sur l'appareil au début de la mesure.
    public init(deviceExposure: Exposure) {
        previous = deviceExposure
    }

    /// Une demande s'applique à partir de l'image d'horodatage `syncTime`.
    ///
    /// Ignorée si `syncTime` n'est pas un instant fini, ou s'il précède celui de la dernière demande connue
    /// (arrivée trop tard). Deux demandes appliquées à la même image : la plus récente l'emporte.
    public mutating func requestApplied(_ exposure: Exposure, syncTime: CMTime) {
        guard syncTime.isNumeric else { return }
        if let latest {
            let order = CMTimeCompare(syncTime, latest.syncTime)
            if order < 0 { return }
            if order > 0 { previous = latest.exposure }
        }
        latest = (exposure, syncTime)
    }

    /// L'exposition de l'image d'horodatage `time` : la dernière demande si l'image est prise à partir de
    /// son `syncTime` (bornes comprises), sinon la précédente.
    public func exposure(at time: CMTime) -> Exposure {
        if let latest, CMTimeCompare(time, latest.syncTime) >= 0 { return latest.exposure }
        return previous
    }
}
