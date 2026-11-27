import Foundation

/// Main-thread-only identity guard; UUID also protects against session ID reuse.
final class SessionGate {
  struct Ticket: Equatable { let sessionId: String; let generation: UUID }
  private(set) var ticket: Ticket?
  private(set) var cleaning = false
  func reserve(_ sessionId: String) -> Ticket? {
    guard ticket == nil, !cleaning else { return nil }
    let value = Ticket(sessionId: sessionId, generation: UUID())
    ticket = value
    return value
  }
  func isCurrent(_ value: Ticket) -> Bool { !cleaning && ticket == value }
  func beginLeave(_ sessionId: String) -> Ticket? {
    guard !cleaning, let value = ticket, value.sessionId == sessionId else { return nil }
    ticket = nil
    cleaning = true
    return value
  }
  func finishLeave() { cleaning = false }
}
