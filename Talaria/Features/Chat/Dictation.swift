import AVFoundation
import Observation
import Speech

/// Dictation into the composer: the microphone's audio through Apple's speech recognizer, on the
/// phone when it can do that. Tap to start, tap again (or send) to stop.
@MainActor @Observable
final class Dictation {
  enum State { case idle, starting, listening }

  private(set) var state: State = .idle
  /// Counts listening sessions, so a late result from one already stopped is dropped (it would
  /// put words back into a composer that has just sent them).
  @ObservationIgnored private var session = 0
  @ObservationIgnored private var engine: AVAudioEngine?
  @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
  @ObservationIgnored private var task: SFSpeechRecognitionTask?

  var isActive: Bool { state != .idle }

  /// Starts listening. `heard` gets the whole transcription so far each time it changes.
  func start(heard: @escaping @MainActor (String) -> Void, failed: @escaping @MainActor (String) -> Void) async {
    guard state == .idle else { return }
    state = .starting
    session += 1
    let current = session
    guard await Self.speechAllowed() else {
      state = .idle
      failed("Dictation needs speech recognition. Turn it on for Talaria in Settings > Privacy & Security.")
      return
    }
    guard await AVAudioApplication.requestRecordPermission() else {
      state = .idle
      failed("Dictation needs the microphone. Turn it on for Talaria in Settings > Privacy & Security.")
      return
    }
    guard state == .starting, session == current else { return }  // stopped while asking
    guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
      state = .idle
      failed("Dictation is not available right now.")
      return
    }
    do {
      let audio = AVAudioSession.sharedInstance()
      try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
      try audio.setActive(true, options: .notifyOthersOnDeactivation)

      let engine = AVAudioEngine()
      let input = engine.inputNode
      let format = input.outputFormat(forBus: 0)
      guard format.channelCount > 0, format.sampleRate > 0 else {
        finish()
        failed("No microphone is available.")
        return
      }
      let request = SFSpeechAudioBufferRecognitionRequest()
      request.shouldReportPartialResults = true
      request.addsPunctuation = true
      if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
      input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(AudioFeed(request)))
      engine.prepare()
      try engine.start()
      self.engine = engine
      self.request = request
      task = recognizer.recognitionTask(
        with: request,
        resultHandler: Self.results { [weak self] text, done in
          guard let self, self.session == current, self.state != .idle else { return }
          if let text, !text.isEmpty { heard(text) }
          if done { self.finish() }
        })
      state = .listening
    } catch {
      finish()
      failed("Could not start dictation: \(error.localizedDescription)")
    }
  }

  /// Stops listening. Words already heard stay in the composer.
  func stop() {
    guard state != .idle else { return }
    finish()
  }

  private func finish() {
    if let engine {
      engine.stop()
      engine.inputNode.removeTap(onBus: 0)
    }
    engine = nil
    request?.endAudio()
    request = nil
    task?.finish()
    task = nil
    state = .idle
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  /// Built outside the main actor: the engine calls the tap on its audio thread, and a closure
  /// made in a main-actor method would be main-actor isolated and trap there.
  private nonisolated static func tap(_ feed: AudioFeed) -> AVAudioNodeTapBlock {
    { buffer, _ in feed.append(buffer) }
  }

  /// The recognizer's callback, likewise built outside the main actor; it hops there itself.
  private nonisolated static func results(
    _ deliver: @escaping @MainActor (String?, Bool) -> Void
  ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
    { result, error in
      let text = result?.bestTranscription.formattedString
      let done = error != nil || (result?.isFinal ?? false)
      Task { @MainActor in deliver(text, done) }
    }
  }

  /// Nonisolated for the same reason: iOS answers the permission prompt on a background queue.
  private nonisolated static func speechAllowed() async -> Bool {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized: return true
    case .notDetermined:
      return await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
      }
    default: return false
    }
  }
}

/// Hands microphone buffers, which arrive on the audio thread, to the recognition request.
/// The request takes buffers from any thread.
private final class AudioFeed: @unchecked Sendable {
  private let request: SFSpeechAudioBufferRecognitionRequest

  init(_ request: SFSpeechAudioBufferRecognitionRequest) {
    self.request = request
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    request.append(buffer)
  }
}
