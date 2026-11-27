package dev.research.customer_rtc

import org.junit.Assert.*
import org.junit.Test

class HostVisibilityTest {
    @Test fun allSessionsInterruptedInOneCycleReplayOnceAndRemainBlocked() {
        var listener = false
        val events = mutableListOf<String>()
        val host = HostVisibility({ id -> if (listener) events.add(id); listener }, {})
        host.updatePresentation("A")
        host.background("A")
        host.updatePresentation("B")
        host.updatePresentation("A")
        host.foreground()
        host.updatePresentation(null)
        assertEquals("host_background", host.joinBlockReason("A"))
        assertEquals("host_background", host.joinBlockReason("B"))
        host.background(null)
        host.foreground()
        listener = true
        host.replay()
        host.replay()
        assertEquals(listOf("A", "B"), events)
        assertEquals("host_background", host.joinBlockReason("A"))
        assertEquals("host_background", host.joinBlockReason("B"))
        assertNull(host.joinBlockReason("C"))

        host.background(null)
        host.foreground()
        assertFalse(host.isInterrupted("A"))
        assertFalse(host.isInterrupted("B"))
    }

    @Test fun absentListenerThenQuickForegroundReplaysOriginalAndRejectsOldJoin() {
        val events = mutableListOf<String>()
        var listener = false
        val releases = mutableListOf<String>()
        val host = HostVisibility({ id ->
            if (listener) events.add(id)
            listener
        }, releases::add)
        host.updatePresentation("old")
        val permissionEpoch = host.epoch
        host.background("old")
        assertEquals(listOf("old"), releases)
        host.foreground()
        assertEquals("host_background", host.joinBlockReason("old"))
        assertEquals("host_background", host.joinBlockReason("old", permissionEpoch))
        listener = true
        host.replay()
        host.replay()
        assertEquals(listOf("old"), events)
        host.updatePresentation("new")
        assertNull(host.joinBlockReason("new"))
        assertEquals("host_background", host.joinBlockReason("old"))
    }

    @Test fun oldEventDeliveredAfterRedialRetainsItsId() {
        var listener = false
        val delivered = mutableListOf<String>()
        val host = HostVisibility({ id -> if (listener) delivered.add(id); listener }, {})
        host.updatePresentation("old")
        host.background(null)
        host.foreground()
        host.updatePresentation(null)
        assertEquals("host_background", host.joinBlockReason("old"))
        assertNull(host.joinBlockReason("flutter-only"))
        host.updatePresentation("replacement")
        listener = true
        host.replay()
        assertEquals(listOf("old"), delivered)
        assertNull(host.joinBlockReason("replacement"))
        assertEquals("cancelled", host.joinBlockReason("unrelated"))
    }

    @Test fun presentationArrivingInBackgroundIsInterruptedBeforeJoin() {
        val events = mutableListOf<String>()
        val host = HostVisibility({ events.add(it); true }, {})
        host.background(null)
        host.updatePresentation("pending-credentials")
        host.foreground()
        assertEquals(listOf("pending-credentials"), events)
        assertEquals("host_background", host.joinBlockReason("pending-credentials"))
    }

    @Test fun pendingPermissionCannotCreateEngineAfterCrossingABackgroundEpoch() {
        var active: String? = "pending"
        var releases = 0
        val host = HostVisibility({ false }, { if (active == it) { active = null; releases++ } })
        val permissionEpoch = host.epoch
        host.background(active)
        host.foreground()
        host.background(active)
        host.foreground()
        assertNull(active)
        assertEquals(1, releases)
        assertEquals("host_background", host.joinBlockReason("pending", permissionEpoch))
        assertNull(host.joinBlockReason("new"))
    }
}
