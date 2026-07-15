import SwiftUI
import ReplayKit

// Wraps Apple's required system UI for starting a Broadcast Upload Extension —
// there is no way to start one programmatically, only via this picker view (a
// small round button that opens the system's broadcast-start sheet) or Control
// Center. No cancellation callback exists; see PairingViewModel's timeout handling.
struct BroadcastPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: .zero)
        picker.preferredExtension = AppConstants.broadcastExtensionBundleID
        // Off by default — this app's scope is screen+system audio mirroring, not
        // mic-inclusive broadcasting. Flip to true if voice commentary is wanted later.
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
