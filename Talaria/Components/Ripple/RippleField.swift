import MetalKit
import SwiftUI

/// The app's background: a fine, even field of particles with soft ripples rolling up and to the
/// right through it, behind every screen. It runs on the GPU (`RippleField.metal`); the CPU sends
/// only the clock and where the view sits.
///
/// Every screen draws its own copy, so a pushed screen slides in over an opaque background as
/// before, but they all share one clock and lay the ripples out in window space: copies side by
/// side (iPad columns) or swapped (push, pop, tabs) continue the same ripple. A copy is only
/// mounted while its screen is on show, so screens covered by a push or in another tab cost
/// nothing.
struct ScreenBackground: View {
  @Environment(\.palette) private var palette
  @State private var isShown = false

  var body: some View {
    ZStack {
      palette.screen
      if isShown { RippleField() }
    }
    .ignoresSafeArea()
    .onAppear { isShown = true }
    .onDisappear { isShown = false }
  }
}

extension View {
  /// The app's background (palette screen color plus the ripple field), edge to edge.
  func screenBackground() -> some View {
    background { ScreenBackground() }
  }
}

struct RippleField: View {
  @Environment(\.palette) private var palette
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    RippleMetalView(
      look: RippleLook(palette: palette, dark: scheme == .dark),
      animates: !reduceMotion && scenePhase == .active)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

/// Colors and blending for the current palette.
struct RippleLook: Equatable {
  var color: SIMD4<Float>
  var crest: SIMD4<Float>
  var sparkle: SIMD4<Float>
  /// Light adds up on a dark screen; on a light one particles are laid over it instead.
  var additive: Bool

  init(palette: Palette, dark: Bool) {
    color = Self.rgba(palette.primary)
    crest = dark ? [0.86, 0.86, 1.0, 1] : Self.rgba(palette.primaryText)
    sparkle = dark ? [1, 1, 1, 1] : [0.12, 0.1, 0.45, 1]
    additive = dark
  }

  private static func rgba(_ color: Color) -> SIMD4<Float> {
    let resolved = color.resolve(in: EnvironmentValues())
    return [resolved.red, resolved.green, resolved.blue, 1]
  }
}

private struct RippleMetalView: UIViewRepresentable {
  let look: RippleLook
  let animates: Bool

  func makeCoordinator() -> RippleRenderer { RippleRenderer() }

  func makeUIView(context: Context) -> MTKView {
    let view = MTKView(frame: .zero, device: RippleGPU.shared.device)
    view.isOpaque = false
    view.layer.isOpaque = false
    view.backgroundColor = .clear
    view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    view.colorPixelFormat = .bgra8Unorm
    view.framebufferOnly = true
    view.preferredFramesPerSecond = 60
    view.isUserInteractionEnabled = false
    view.delegate = context.coordinator
    return view
  }

  func updateUIView(_ view: MTKView, context: Context) {
    let renderer = context.coordinator
    renderer.look = look
    renderer.animates = animates
    // Without motion the field holds one frame, drawn again only when something changes.
    view.isPaused = !animates
    view.enableSetNeedsDisplay = !animates
    if !animates { view.setNeedsDisplay() }
  }
}

/// The Metal objects every copy of the field shares, made once.
@MainActor
final class RippleGPU {
  static let shared = RippleGPU()

  let device = MTLCreateSystemDefaultDevice()
  let queue: MTLCommandQueue?
  let additive: MTLRenderPipelineState?
  let over: MTLRenderPipelineState?
  /// The one clock all copies follow, so a screen swap never restarts the ripple.
  let epoch = CACurrentMediaTime()

  private init() {
    queue = device?.makeCommandQueue()
    additive = Self.pipeline(device: device, additive: true)
    over = Self.pipeline(device: device, additive: false)
  }

  private static func pipeline(device: MTLDevice?, additive: Bool) -> MTLRenderPipelineState? {
    guard let device, let library = device.makeDefaultLibrary() else { return nil }
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "ripple_vertex")
    descriptor.fragmentFunction = library.makeFunction(name: "ripple_fragment")
    let attachment = descriptor.colorAttachments[0]!
    attachment.pixelFormat = .bgra8Unorm
    attachment.isBlendingEnabled = true
    attachment.rgbBlendOperation = .add
    attachment.alphaBlendOperation = .add
    attachment.sourceRGBBlendFactor = .one
    attachment.sourceAlphaBlendFactor = .one
    attachment.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
    attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    return try? device.makeRenderPipelineState(descriptor: descriptor)
  }
}

@MainActor
final class RippleRenderer: NSObject, MTKViewDelegate {
  var look = RippleLook(palette: .hermesDark, dark: true)
  var animates = true {
    didSet {
      guard animates != oldValue else { return }
      if animates { RippleMotion.shared.retain() } else { RippleMotion.shared.release() }
    }
  }

  override init() {
    super.init()
    RippleMotion.shared.retain()
  }

  isolated deinit {
    if animates { RippleMotion.shared.release() }
  }

  /// Points between neighbouring particles (about 2,500 on an iPhone) and their size: well
  /// spread out, each dot big and bright enough to read on its own.
  private static let spacing: Float = 12
  private static let dotSize: Float = 2.3
  /// Where the clock rests when motion is off.
  private static let stillTime: Float = 7

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    if !animates { view.setNeedsDisplay() }
  }

  func draw(in view: MTKView) {
    let gpu = RippleGPU.shared
    let size = view.bounds.size
    guard size.width > 1, size.height > 1,
      let pipeline = look.additive ? gpu.additive : gpu.over,
      let queue = gpu.queue,
      let pass = view.currentRenderPassDescriptor,
      let drawable = view.currentDrawable,
      let commands = queue.makeCommandBuffer(),
      let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
    else { return }

    // The ripple is laid out over the whole window, so every copy shows its own part of it.
    let offset = view.convert(CGPoint.zero, to: nil)
    let canvas = view.window?.bounds.size ?? size
    let now = CACurrentMediaTime()
    let elapsed = Float(now - gpu.epoch)
    let motion = RippleMotion.shared
    motion.watch(view.window)
    // Held still (Reduce Motion), the ripple keeps its resting heading.
    let steer = animates
      ? motion.step(now: now)
      : RippleMotion.Frame(heading: simd_normalize(SIMD2<Float>(0.53, -0.85)), travel: 20 * Self.stillTime, flow: .zero, energy: 0)
    let columns = (Float(size.width) / Self.spacing).rounded(.up)
    let rows = (Float(size.height) / Self.spacing).rounded(.up)
    var uniforms = RippleUniforms(
      color: look.color, crestColor: look.crest, sparkleColor: look.sparkle,
      viewSize: [Float(size.width), Float(size.height)],
      offset: [Float(offset.x), Float(offset.y)],
      canvas: [Float(canvas.width), Float(canvas.height)],
      heading: steer.heading, flow: steer.flow, extent: [columns * Self.spacing, rows * Self.spacing],
      travel: steer.travel, energy: steer.energy,
      time: animates ? elapsed + 20 : Self.stillTime,
      scale: Float(view.drawableSize.width / size.width),
      spacing: Self.spacing, columns: columns,
      dotSize: Self.dotSize,
      intro: animates ? Self.ease(min(elapsed / 2.0, 1)) : 1)

    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBytes(&uniforms, length: MemoryLayout<RippleUniforms>.stride, index: 0)
    encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: Int(columns * rows))
    encoder.endEncoding()
    commands.present(drawable)
    commands.commit()
  }

  private static func ease(_ x: Float) -> Float { 1 - pow(1 - x, 3) }
}

/// Matches `Uniforms` in RippleField.metal.
private struct RippleUniforms {
  var color: SIMD4<Float>
  var crestColor: SIMD4<Float>
  var sparkleColor: SIMD4<Float>
  var viewSize: SIMD2<Float>
  var offset: SIMD2<Float>
  var canvas: SIMD2<Float>
  var heading: SIMD2<Float>
  var flow: SIMD2<Float>
  var extent: SIMD2<Float>
  var travel: Float
  var energy: Float
  var time: Float
  var scale: Float
  var spacing: Float
  var columns: Float
  var dotSize: Float
  var intro: Float
}
