import Foundation

/// Agora iOS destroy returns void. Completion is recorded only after that call returns.
struct CleanupPolicy {
  private var destroyed = false
  private var warnings = false
  mutating func stop(_ status: Int32) { if status != 0 { warnings = true } }
  mutating func destroyReturned() { destroyed = true }
  var releaseStatus: String? { destroyed ? (warnings ? "releasedWithWarnings" : "released") : nil }
}

// Agora destroys a process-wide singleton. All state below is main-thread owned;
// the worker calls only the blocking SDK function.
final class EngineRetirement {
  private let queue = DispatchQueue(label: "customer.rtc.destroy")
  private(set) var sessionId: String?
  private var waiters = [(String) -> Void]()

  func waitIfReleasing(_ id: String, completion: ((String) -> Void)?) -> Bool {
    precondition(Thread.isMainThread)
    guard id == sessionId else { return false }
    if let completion { waiters.append(completion) }
    return true
  }

  func start(_ id: String, destroy: @escaping () -> Void,
             finish: @escaping () -> String, completion: ((String) -> Void)?) {
    precondition(Thread.isMainThread && sessionId == nil)
    sessionId = id
    if let completion { waiters.append(completion) }
    queue.async {
      destroy()
      DispatchQueue.main.async {
        let callbacks = self.waiters
        self.waiters.removeAll()
        self.sessionId = nil
        let status = finish()
        callbacks.forEach { $0(status) }
      }
    }
  }
}
