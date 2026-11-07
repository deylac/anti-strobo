import AVFoundation
import os

private let log = Logger(subsystem: "app.camantistrobo.ios", category: "Formats")

/// Relevé des caméras arrière et de leurs formats, pour choisir sur pièces ce qui éclaire le plus une scène sombre
/// (ISO maximal, binning, 10 bits, Apple Log, HDR, multi-caméra). Lancé avec l'argument `-logCameraFormats` ;
/// une ligne par format dans le journal, rien d'autre ne change.
enum FormatReport {
    static func logIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-logCameraFormats") else { return }
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera,
        ]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back)
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        log.notice("Système \(system, privacy: .public), multi-caméra : \(AVCaptureMultiCamSession.isMultiCamSupported, privacy: .public)")
        for device in discovery.devices {
            log.notice("Caméra \(device.localizedName, privacy: .public) : \(device.formats.count) formats, \(lens(of: device), privacy: .public)")
            for (index, format) in device.formats.enumerated() {
                log.notice("\(describe(format, index: index), privacy: .public)")
            }
        }
        if let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            logConnectionSupport(of: wide)
        }
        log.notice("Fin du relevé des formats")
    }

    private static func lens(of device: AVCaptureDevice) -> String {
        var text = "ouverture f/\(device.lensAperture)"
        if #available(iOS 27.0, *) {
            let format = device.activeFormat
            text += " (format actif : f/\(format.minLensAperture) à f/\(format.maxLensAperture))"
        }
        return text
    }

    /// Ce que la sortie d'images de l'app (comme dans `SessionConfigurator`) permet au format que l'app choisit :
    /// la réduction de bruit en basse lumière d'iOS 27 ne dépend pas que du format.
    private static func logConnectionSupport(of device: AVCaptureDevice) {
        guard #available(iOS 27.0, *) else { return }
        let session = AVCaptureSession()
        session.beginConfiguration()
        guard let choice = try? SessionConfigurator.chooseFormat(of: device),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input)
        else {
            session.commitConfiguration()
            log.notice("Connexion : configuration impossible")
            return
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            log.notice("Connexion : sortie refusée")
            return
        }
        session.addOutput(output)
        for fps in [120.0, 60.0, 30.0] {
            guard (try? device.lockForConfiguration()) != nil else { continue }
            device.activeFormat = choice.format
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            let supported = output.connection(with: .video)?.isLowLightVideoNoiseReductionSupported ?? false
            let index = device.formats.firstIndex(of: choice.format) ?? -1
            log.notice("Connexion format #\(index) à \(Int(fps)) i/s : réduction de bruit basse lumière \(supported, privacy: .public)")
        }
        session.commitConfiguration()
    }

    private static func describe(_ format: AVCaptureDevice.Format, index: Int) -> String {
        let description = format.formatDescription
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let rates = format.videoSupportedFrameRateRanges
            .map { "\(Int($0.minFrameRate.rounded()))-\(Int($0.maxFrameRate.rounded()))" }
            .joined(separator: ",")
        let spaces = format.supportedColorSpaces.map { "\($0.rawValue)" }.joined(separator: ",")
        return [
            "#\(index)",
            "\(dimensions.width)x\(dimensions.height)",
            fourCC(CMFormatDescriptionGetMediaSubType(description)),
            "ips=\(rates)",
            "iso=\(Int(format.minISO))-\(Int(format.maxISO))",
            "pose=\(milliseconds(format.minExposureDuration))-\(milliseconds(format.maxExposureDuration))ms",
            "binning=\(format.isVideoBinned)",
            "hdr=\(format.isVideoHDRSupported)",
            "couleurs=\(spaces)",
            "multicam=\(format.isMultiCamSupported)",
            "tonemap=\(format.isGlobalToneMappingSupported)",
            "llnr=\(lowLightNoiseReduction(format))",
        ].joined(separator: " ")
    }

    private static func lowLightNoiseReduction(_ format: AVCaptureDevice.Format) -> String {
        if #available(iOS 27.0, *) { return "\(format.isLowLightVideoNoiseReductionSupported)" }
        return "?"
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func milliseconds(_ time: CMTime) -> String {
        String(format: "%.3f", time.seconds * 1000)
    }
}
