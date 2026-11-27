package dev.research.customer_rtc

import org.junit.Assert.*
import org.junit.Test

class PhoneAudioSettingsTest {
    @Test fun missedCallKeepsMutedMicAndRestoresSelectedEarpiece() {
        val audio = PhoneAudioSettings()
        audio.setMuted(true, false, { error("No capture restart expected") }) { 0 }
        audio.setSpeaker(false, false) { 0 }
        val mic = mutableListOf<Boolean>()
        val volume = mutableListOf<Int>()
        val speaker = mutableListOf<Boolean>()
        for (ringing in listOf(true, false)) {
            assertTrue(audio.adjust(ringing, { mic.add(it); 0 }, { volume.add(it); 0 },
                { false }, { speaker.add(it); 0 }))
        }
        assertEquals(listOf(true, true), mic)
        assertEquals(listOf(0, 100), volume)
        assertEquals(listOf(false), speaker)
    }

    @Test fun unmuteRequestedWhileRingingWaitsForIdleAndKeepsExternalAudioRoute() {
        val audio = PhoneAudioSettings()
        audio.setMuted(true, false, { error("No capture restart expected") }) { 0 }
        audio.setMuted(false, true, { error("No capture restart expected") }) { assertTrue(it); 0 }
        audio.setSpeaker(false, true) { error("Dialer owns the route") }
        assertTrue(audio.adjust(false, { assertFalse(it); 0 }, { assertEquals(100, it); 0 },
            { assertFalse(it); true }, { error("Keep attached headset") }))
    }

    @Test fun failedControlKeepsPreviousPreferenceAndRecoveryAttemptsAllAudioControls() {
        val audio = PhoneAudioSettings()
        audio.setMuted(true, false, { error("No capture restart expected") }) { 0 }
        audio.setMuted(false, false, { error("No capture restart expected") }) { -1 }
        var restoredPlayback = false
        var restoredRoute = false
        assertFalse(audio.adjust(false, { assertTrue(it); throw IllegalStateException() },
            { restoredPlayback = it == 100; 0 }, { false }, { restoredRoute = it; 0 }))
        assertTrue(restoredPlayback)
        assertTrue(restoredRoute)
    }

    @Test fun onlyPhoneAssociatedCaptureFailuresCanRestartCapture() {
        val audio = PhoneAudioSettings()
        var starts = 0
        val enable = { starts++; 0 }
        audio.observeCapture(failed = true, recording = false)
        assertTrue(audio.restoreCapture(enable))
        assertEquals(0, starts)
        audio.beginRing()
        assertTrue(audio.restoreCapture(enable))
        audio.observeCapture(failed = false, recording = true)
        assertTrue(audio.restoreCapture(enable))
        audio.observeCapture(failed = true, recording = false) // late SDK failure after IDLE
        assertTrue(audio.restoreCapture(enable))
        assertEquals(2, starts)
        audio.observeCapture(failed = false, recording = true)
        audio.endRecoveryWindow()
        audio.observeCapture(failed = true, recording = false) // unrelated microphone failure
        assertTrue(audio.restoreCapture(enable))
        assertEquals(2, starts)
    }

    @Test fun failedCaptureStaysMutedUntilExplicitUnmuteAndSuccessfulRestart() {
        val audio = PhoneAudioSettings()
        audio.setMuted(true, false, { error("No capture restart expected") }) { 0 }
        audio.beginRing()
        audio.observeCapture(failed = true, recording = false)
        assertTrue(audio.restoreCapture { error("Do not capture for muted user") })
        audio.endRecoveryWindow()
        assertEquals(-3, audio.setMuted(false, false, { -3 }) { error("Do not publish on failed restart") })
        assertTrue(audio.restoreCapture { error("Failed unmute did not change preference") })
        assertEquals(0, audio.setMuted(false, false, { 0 }) { assertFalse(it); 0 })
    }
}
