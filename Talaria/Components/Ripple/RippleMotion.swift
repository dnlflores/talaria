import CoreMotion
import simd
import UIKit

/// Moves the ripple like a slow shore break: it washes in and draws back a little, over and
/// over, and drifts up and to the right on its own. Tilting the phone (gravity from the gyro,
/// relative to the way a phone is usually held) and swiping only lean on it: a tilt held for a
/// few seconds slowly turns the waves that way, a quick wobble does nothing, and the waves never
/// give up their own direction entirely.
///
/// One shared state for every copy of the field, stepped once per frame from whichever copy
/// draws first. Motion updates run only while a copy is on screen.
@MainActor
final class RippleMotion: NSObject, UIGestureRecognizerDelegate {
  static let shared = RippleMotion()

  struct Frame {
    /// The way the ripples travel, a unit vector in screen space (y down).
    var heading: SIMD2<Float>
    /// How far the main ripple has travelled, points; drives its phase.
    var travel: Float
    /// How far the water has carried the particles, points.
    var flow: SIMD2<Float>
    /// 0 at rest, toward 1 while tilted hard or just swiped.
    var energy: Float
  }

  private(set) var frame = Frame(heading: RippleMotion.restHeading, travel: 0, flow: .zero, energy: 0)

  /// Up and to the right.
  private static let restHeading = simd_normalize(SIMD2<Float>(0.53, -0.85))
  /// Gravity along the phone's own y axis when held normally (about 45 degrees back).
  private static let restGravityY: Float = -0.72

  private let motion = CMMotionManager()
  private var users = 0
  private var lastStep: CFTimeInterval = 0
  private var swipe = SIMD2<Float>.zero
  /// The tilt as it builds up over a few seconds: a held tilt counts, a passing one hardly does.
  private var leaning = SIMD2<Float>.zero
  private var energy: Float = 0
  private var clock: Float = 0
  private weak var window: UIWindow?
  private var pan: UIPanGestureRecognizer?

  /// A copy of the field came on screen or went away.
  func retain() {
    users += 1
    if users == 1, motion.isDeviceMotionAvailable {
      motion.deviceMotionUpdateInterval = 1.0 / 30
      motion.startDeviceMotionUpdates()
    }
  }

  func release() {
    users = max(users - 1, 0)
    if users == 0 { motion.stopDeviceMotionUpdates() }
  }

  /// Watches the window's touches without taking them: scrolling, taps and other gestures go on
  /// exactly as before.
  func watch(_ window: UIWindow?) {
    guard let window, window !== self.window else { return }
    if let pan { pan.view?.removeGestureRecognizer(pan) }
    let recognizer = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    recognizer.cancelsTouchesInView = false
    recognizer.delaysTouchesBegan = false
    recognizer.delaysTouchesEnded = false
    recognizer.delegate = self
    window.addGestureRecognizer(recognizer)
    self.window = window
    pan = recognizer
  }

  @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
    guard recognizer.state == .changed || recognizer.state == .ended else { return }
    let velocity = recognizer.velocity(in: recognizer.view)
    let push = SIMD2(Float(velocity.x), Float(velocity.y)) / 2200
    // The newest movement wins, while a fast flick still outweighs a slow drag.
    swipe = swipe * 0.6 + push * 0.4
    let length = simd_length(swipe)
    if length > 0.9 { swipe *= 0.9 / length }
  }

  nonisolated func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool { true }

  /// Advances the shared state to `now`, once per frame however many copies draw.
  func step(now: CFTimeInterval) -> Frame {
    guard now - lastStep > 0.002 else { return frame }
    let dt = Float(lastStep == 0 ? 1.0 / 60 : min(now - lastStep, 0.1))
    lastStep = now

    clock += dt

    // Tilt away from the usual hold, as "downhill" on the screen: tip the right edge down and
    // the waves lean right; lay the phone back and they lean up.
    var tilt = SIMD2<Float>.zero
    if let gravity = motion.deviceMotion?.gravity {
      tilt = SIMD2(Float(gravity.x), Float(-gravity.y) + Self.restGravityY)
      let size = simd_length(tilt)
      // A wide dead zone for a hand that is never quite still, and a cap so a hard tilt leans
      // no harder than a moderate one.
      let counted = min(max(size - 0.12, 0), 0.45)
      tilt = size > 0 ? tilt * (counted / size) : .zero
    }
    leaning += (tilt - leaning) * (1 - exp(-dt / 2.5))
    swipe *= exp(-dt / 2.5)

    // Their own direction wanders a few degrees over half a minute, and always pulls hardest.
    let wander = 0.1 * sin(clock * 2 * .pi / 23)
    let rest = SIMD2(
      Self.restHeading.x * cos(wander) - Self.restHeading.y * sin(wander),
      Self.restHeading.x * sin(wander) + Self.restHeading.y * cos(wander))
    let target = rest + leaning * 2.2 + swipe
    let aim = simd_length(target) < 1e-4 ? frame.heading : simd_normalize(target)
    // Turning takes seconds, like a swell coming round.
    let blend = 1 - exp(-dt / 3)
    var heading = frame.heading + (aim - frame.heading) * blend
    heading = simd_length(heading) < 1e-3 ? frame.heading : simd_normalize(heading)

    let push = min(simd_length(swipe) * 0.8, 1)
    energy += (push - energy) * (1 - exp(-dt / (push > energy ? 0.4 : 2)))
    // Washing in and drawing back: forward on average, at an uneven rhythm.
    let surge = sin(clock * 2 * .pi / 9) + 0.35 * sin(clock * 2 * .pi / 4.1 + 1)
    let speed = 20 + 10 * surge + 8 * energy
    // Each wash brightens the crests a little as it comes in.
    let swell = max(energy, 0.3 * max(surge, 0))
    // The water itself drifts the same way, slower than the waves running through it.
    let flow = frame.flow + heading * (0.4 * speed * dt)
    frame = Frame(heading: heading, travel: frame.travel + speed * dt, flow: flow, energy: swell)
    return frame
  }
}
