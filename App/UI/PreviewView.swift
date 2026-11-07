import AVFoundation
import SwiftUI

/// Aperçu de la caméra en plein cadre (`AVCaptureVideoPreviewLayer`, mode remplissage), qui suit
/// l'orientation de l'interface.
struct PreviewView: UIViewRepresentable {
    let camera: CameraController

    func makeUIView(context: Context) -> PreviewLayerView {
        let view = PreviewLayerView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = camera.session
        camera.attachPreview(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewLayerView, context: Context) {}
}

/// Vue dont la couche est l'aperçu : la couche suit la taille de la vue sans code de mise en page.
final class PreviewLayerView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // `layerClass` garantit le type de la couche.
        layer as! AVCaptureVideoPreviewLayer
    }
}
