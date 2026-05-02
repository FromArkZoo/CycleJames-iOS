import SwiftUI
import UIKit

/// SwiftUI wrapper around UIActivityViewController so we can present the
/// system share sheet from anywhere we have a file URL or string.
/// Used by ride history + ride completion to share TCX exports to
/// Strava, Garmin Connect, AirDrop, email, etc.
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
