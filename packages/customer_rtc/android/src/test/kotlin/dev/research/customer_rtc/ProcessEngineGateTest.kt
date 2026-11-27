package dev.research.customer_rtc

import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import dev.research.customer_rtc.ProcessEngineGate.Acquisition.*

class ProcessEngineGateTest {
    @Test fun replacementEngineWaitsForPreviousPluginDestroy() {
        val gate = ProcessEngineGate()
        val old = Any(); val replacement = Any()
        assertEquals(GRANTED, gate.acquire(old))
        val destroyReturned = CountDownLatch(1)
        val cleanup = Thread {
            if (destroyReturned.await(2, TimeUnit.SECONDS)) gate.finish(old, true)
        }.apply { start() }
        assertEquals(BUSY, gate.acquire(replacement))
        gate.finish(replacement, true) // Another plugin canceling permissions never owned an engine.
        assertEquals(BUSY, gate.acquire(replacement))
        destroyReturned.countDown()
        cleanup.join()
        assertEquals(GRANTED, gate.acquire(replacement))
        gate.finish(old, true)
        assertEquals(BUSY, gate.acquire(Any()))
    }

    @Test fun failureBlocksFuturePluginInstances() {
        val gate = ProcessEngineGate()
        val old = Any()
        assertEquals(GRANTED, gate.acquire(old))
        gate.finish(old, false)
        assertEquals(RESTART_REQUIRED, gate.acquire(Any()))
        gate.finish(old, true)
        assertEquals(RESTART_REQUIRED, gate.acquire(Any()))
    }
}
