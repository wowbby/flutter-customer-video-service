import Foundation

@main enum SessionGateTests {
  static func main() {
    let gate = SessionGate()
    guard let first = gate.reserve("call") else { fatalError("first call must reserve") }
    precondition(gate.reserve("duplicate") == nil, "only one pending join")
    precondition(gate.beginLeave("old") == nil && gate.isCurrent(first), "stale leave must not end current call")
    precondition(gate.beginLeave("call") == first, "pending call can cancel")
    precondition(!gate.isCurrent(first), "cancel invalidates late permission and callbacks immediately")
    precondition(gate.reserve("next") == nil, "cleanup blocks new engine")
    gate.finishLeave()
    let reused = gate.reserve("call")!
    precondition(!gate.isCurrent(first) && gate.isCurrent(reused), "reused ID must not accept stale callback")
    precondition(gate.beginLeave("call") == reused)
    precondition(gate.beginLeave("call") == nil, "repeat leave is idempotent")
    gate.finishLeave()
    print("SessionGate: lifecycle assertions passed")
  }
}
