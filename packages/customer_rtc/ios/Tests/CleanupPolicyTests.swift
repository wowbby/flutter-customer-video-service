import Foundation

@main enum CleanupPolicyTests {
  static func main() {
    var clean = CleanupPolicy()
    precondition(clean.releaseStatus == nil, "release cannot be confirmed before void destroy returns")
    clean.stop(0)
    clean.destroyReturned()
    precondition(clean.releaseStatus == "released")
    var warnings = CleanupPolicy()
    warnings.stop(-7)
    warnings.stop(0)
    warnings.stop(1)
    precondition(warnings.releaseStatus == nil, "intermediate API results never confirm destruction")
    warnings.destroyReturned()
    precondition(warnings.releaseStatus == "releasedWithWarnings", "nonzero stop/unbind/leave become warnings")
    let gate = SessionGate()
    _ = gate.reserve("first"); _ = gate.beginLeave("first")
    precondition(gate.reserve("next") == nil)
    gate.finishLeave()
    precondition(gate.reserve("next") != nil, "destroy completion permits another engine despite warnings")
    print("CleanupPolicy: void destroy boundary and cleanup warnings passed")
  }
}
