import Foundation
import Observation

/// Its task belongs to the visible view, not to a chat turn. Cancel on departure/background.
@MainActor @Observable
public final class BackgroundWorkModel {
  public private(set) var state = BackgroundWorkState()
  public private(set) var hasChecked = false
  public private(set) var isPaused = true
  private var scope: BackgroundWorkScope?
  private var generation = UUID()

  public init() {}

  /// Invalidates even transports whose pending RPC cannot be cancelled immediately.
  public func pause() {
    generation = UUID()
    isPaused = true
  }

  public func run(
    scope: BackgroundWorkScope,
    fetch: @Sendable () async throws -> BackgroundWorkSnapshot,
    wait: @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(3)) }
  ) async {
    let token = UUID()
    generation = token
    if self.scope != scope {
      self.scope = scope
      state = BackgroundWorkState()
      hasChecked = false
    }
    isPaused = false
    while !Task.isCancelled, generation == token {
      do {
        let snapshot = try await fetch()
        guard !Task.isCancelled, generation == token else { return }
        state.apply(snapshot)
        hasChecked = true
      } catch {
        guard !Task.isCancelled, generation == token else { return }
        // A failed read never changes task outcomes or erases last known work.
        state.markUnavailable()
      }
      do { try await wait() } catch { return }
    }
  }
}
