import SwiftUI
import MediaPlayer

/// A hidden MPVolumeView added directly to the UIWindow to suppress the system volume HUD.
///
/// IMPORTANT: The MPVolumeView must be added to the UIWindow directly (not through SwiftUI's
/// UIViewRepresentable layout system) for two reasons:
/// 1. SwiftUI's `.frame(width: 0, height: 0)` collapses the UIKit view, disconnecting the
///    internal slider from the system volume service.
/// 2. The MPVolumeView must not be hidden (`isHidden = true`) or it won't suppress the HUD.
///    Using very small alpha + offscreen position is the correct approach.
///
/// This struct is still a UIViewRepresentable so it participates in the SwiftUI lifecycle,
/// but the actual MPVolumeView is parented on the UIWindow, not on the SwiftUI-managed view.
struct HiddenVolumeView: UIViewRepresentable {

    let manager: VolumeButtonManager

    func makeUIView(context: Context) -> UIView {
        // Return an empty placeholder to SwiftUI — the real work is on the window
        let placeholder = UIView(frame: .zero)
        placeholder.isHidden = true

        // Add the MPVolumeView directly to the key window
        DispatchQueue.main.async {
            guard let window = UIApplication.shared
                .connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow })
            else {
                print("[HiddenVolumeView] ERROR: No key window found!")
                return
            }

            // Create MPVolumeView with a REAL frame (not zero) at an offscreen position.
            // CGFloat.greatestFiniteMagnitude positions it far offscreen.
            // The frame must be non-zero for the internal slider to connect to the volume service.
            let volumeView = MPVolumeView(
                frame: CGRect(
                    x: CGFloat.greatestFiniteMagnitude,
                    y: CGFloat.greatestFiniteMagnitude,
                    width: 120,
                    height: 40
                )
            )
            volumeView.alpha = 0.01  // Must be > 0 or HUD suppression fails
            volumeView.clipsToBounds = true
            volumeView.showsRouteButton = false
            volumeView.tag = 98765  // Tag so we can find/remove it later

            // Remove any previous instance (e.g., on SwiftUI re-render)
            window.viewWithTag(98765)?.removeFromSuperview()

            // Add directly to window — NOT through SwiftUI's layout
            window.addSubview(volumeView)

            // Force layout so UIKit creates the internal UISlider subview immediately
            volumeView.layoutIfNeeded()

            // Hand the volume view reference to the manager
            manager.setHiddenVolumeView(volumeView)
        }

        return placeholder
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // No updates needed — the MPVolumeView lives on the window
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        // Clean up the window-level MPVolumeView when this SwiftUI view is removed
        DispatchQueue.main.async {
            UIApplication.shared
                .connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first(where: { $0.isKeyWindow })?
                .viewWithTag(98765)?
                .removeFromSuperview()
        }
    }
}
