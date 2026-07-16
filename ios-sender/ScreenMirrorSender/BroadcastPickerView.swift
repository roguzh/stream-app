import SwiftUI
import ReplayKit

// Wraps Apple's required system UI for starting a Broadcast Upload Extension —
// there is no way to start one programmatically, only via this picker view (a
// small round button that opens the system's broadcast-start sheet) or Control
// Center. No cancellation callback exists; see PairingViewModel's timeout handling.
struct BroadcastPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        // RPSystemBroadcastPickerView lays out its internal icon image view based
        // on the frame it's given at init time, and doesn't reliably re-layout it
        // afterward purely from SwiftUI applying constraints via .frame() — confirmed
        // on-device: initializing with .zero (even with a correct tintColor and a
        // SwiftUI-applied 60x60 frame) rendered as empty tappable-but-invisible
        // space. Giving it a real frame up front fixes this.
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        picker.preferredExtension = AppConstants.broadcastExtensionBundleID
        // Off by default — this app's scope is screen+system audio mirroring, not
        // mic-inclusive broadcasting. Flip to true if voice commentary is wanted later.
        picker.showsMicrophoneButton = false
        // The picker renders a template icon colored by tintColor — left unset,
        // it defaults to a dark color that's invisible against this app's black
        // background.
        picker.tintColor = .white
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
