package dev.research.customer_rtc

import org.junit.Assert.*
import org.junit.Test

class CanvasBindingsTest {
    @Test fun retryReportsBothRolesAndReturnsOriginalSdkFailure() {
        val events = mutableListOf<Triple<String, Boolean, Int?>>()
        val bindings = CanvasBindings { role, ok, code -> events.add(Triple(role, ok, code)) }
        bindings.apply("local", true) { -7 }
        bindings.apply("remote", true) { 0 }
        assertEquals(listOf(Triple("local", false, -7), Triple("remote", true, null)), events)
        assertEquals(-7, (bindings.failure as RtcOperationException).code)
    }

    @Test fun surfaceUnbindDoesNotSignalSuccessfulRebind() {
        val events = mutableListOf<String>()
        val bindings = CanvasBindings { role, _, _ -> events.add(role) }
        bindings.apply("remote", false) { 0 }
        assertTrue(events.isEmpty())
        assertNull(bindings.failure)
    }
}
