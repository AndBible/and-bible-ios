// TiltScrollService.swift — CoreMotion pitch-based auto-scroll (iOS only)
//
// Uses device pitch angle to scroll Bible text forward, matching Android's
// PageTiltScrollControl.kt behavior. Calibrates on start and re-calibrates
// on touch events.

#if os(iOS)
import CoreMotion

@Observable
class TiltScrollService {
    private let motionManager = CMMotionManager()
    private var referenceAngle: Double = 0
    private var isCalibrated = false
    private(set) var isActive = false

    // Android-matching constants (PageTiltScrollControl.kt)
    private let deadZoneDegrees: Double = 2.0
    private let maxDegrees: Double = 45.0
    private let baseScrollPixels: Int = 2

    /// Callback invoked on the main queue with pixel count to scroll.
    var onScroll: ((Int) -> Void)?

    func start() {
        guard motionManager.isDeviceMotionAvailable else { return }
        isActive = true
        isCalibrated = false
        motionManager.deviceMotionUpdateInterval = 1.0 / 30 // 30 Hz
        motionManager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.handleMotionUpdate(motion)
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        isActive = false
        isCalibrated = false
    }

    /// Re-calibrate so the current angle becomes the "no scroll" reference.
    func calibrate() {
        isCalibrated = false
    }

    private func handleMotionUpdate(_ motion: CMDeviceMotion) {
        let pitchDegrees = motion.attitude.pitch * 180.0 / .pi

        if !isCalibrated {
            referenceAngle = pitchDegrees
            isCalibrated = true
            return
        }

        let delta = pitchDegrees - referenceAngle

        // Dead zone — no scroll for small tilts
        if abs(delta) < deadZoneDegrees { return }

        // Only scroll forward (down) — matching Android
        guard delta > 0 else { return }

        let normalizedSpeed = min((delta - deadZoneDegrees) / (maxDegrees - deadZoneDegrees), 1.0)
        let pixels = Int(Double(baseScrollPixels) + normalizedSpeed * 8.0)
        onScroll?(pixels)
    }
}
#endif
