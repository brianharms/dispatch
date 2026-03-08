import SwiftUI
import MediaPlayer

/// A hidden MPVolumeView that suppresses the system volume HUD.
/// Place this in your view hierarchy (it renders nothing visible).
/// On appear, it locates the internal UISlider and hands it to VolumeButtonManager.
struct HiddenVolumeView: UIViewRepresentable {

    let manager: VolumeButtonManager

    func makeUIView(context: Context) -> MPVolumeView {
        let volumeView = MPVolumeView(frame: .zero)
        // Move off-screen and make invisible — but keep in hierarchy to suppress HUD
        volumeView.alpha = 0.001
        volumeView.clipsToBounds = true
        volumeView.frame = CGRect(x: -1000, y: -1000, width: 1, height: 1)

        // Hide the route button (AirPlay picker)
        volumeView.showsRouteButton = false

        // Find the UISlider inside MPVolumeView and hand it to the manager
        DispatchQueue.main.async {
            if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
                manager.setHiddenVolumeSlider(slider)
            }
        }

        return volumeView
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        // No updates needed
    }
}
