package dev.research.customer_rtc

import org.junit.Test

class CleanupPolicyTest {
    @Test fun cleanupPolicyPreservesWarningsAndDestroyBoundary() {
        CleanupPolicyCheck.main(emptyArray())
    }
}
