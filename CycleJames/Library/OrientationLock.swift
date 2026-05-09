import UIKit

final class OrientationLock {
    static let shared = OrientationLock()
    private(set) var mask: UIInterfaceOrientationMask = .portrait

    func lock(_ mask: UIInterfaceOrientationMask) {
        self.mask = mask
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .forEach { scene in
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
                scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
    }
}
