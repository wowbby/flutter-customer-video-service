package dev.research.customer_rtc

import org.junit.Assert.*
import org.junit.Test

class SessionGateTest {
    @Test fun failedCleanupRemainsBlockedAndRepeatLeaveReportsFailure() {
        val gate = SessionGate()
        gate.begin("failed")
        gate.close("failed")
        gate.cleaned(false)
        assertNull(gate.begin("new"))
        assertTrue(gate.cleanupFailed("failed"))
        assertFalse(gate.cleanupFailed("older"))
    }
    @Test fun cancelRejectsLatePermissionAndSdkCallbacks() {
        val gate = SessionGate()
        val first = gate.begin("first")
        assertTrue(gate.close("first"))
        assertFalse(gate.isCurrent(first))
        gate.cleaned()
        val next = gate.begin("next")
        assertFalse(gate.isCurrent(first))
        assertTrue(gate.isCurrent(next))
    }
    @Test fun cleanupMustCompleteBeforeAnotherJoin() {
        val gate = SessionGate()
        gate.begin("first")
        assertNull(gate.begin("duplicate"))
        gate.close("first")
        assertNull(gate.begin("second"))
        gate.cleaned()
        assertNotNull(gate.begin("second"))
    }
    @Test fun lateLeaveCannotCloseANewerSession() {
        val gate = SessionGate()
        gate.begin("first")
        gate.close("first")
        gate.cleaned()
        val second = gate.begin("second")
        assertFalse(gate.close("first"))
        assertTrue(gate.isCurrent(second))
    }
    @Test fun reusedSessionIdStillRejectsOldCallbacks() {
        val gate = SessionGate()
        val old = gate.begin("same")
        gate.close("same")
        gate.cleaned()
        val new = gate.begin("same")
        assertFalse(gate.isCurrent(old))
        assertTrue(gate.isCurrent(new))
    }
}
