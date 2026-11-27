package dev.research.customer_rtc;

/** Pure teardown policy checks; no Android runtime or RTC credentials. */
public final class CleanupPolicyCheck {
    public static void main(String[] args) {
        CleanupPolicy clean = new CleanupPolicy();
        clean.stop(() -> 0);
        clean.destroy(() -> {});
        check("released".equals(clean.releaseStatus()), "clean destroy confirms release");

        CleanupPolicy warnings = new CleanupPolicy();
        int[] calls = {0};
        warnings.stop(() -> { calls[0]++; return -7; });
        warnings.stop(() -> { calls[0]++; throw new IllegalStateException("private SDK text"); });
        warnings.stop(() -> { calls[0]++; return 0; });
        warnings.destroy(() -> calls[0]++);
        check(calls[0] == 4, "stop failure must not prevent later stop or destroy");
        check("releasedWithWarnings".equals(warnings.releaseStatus()), "destroy wins over intermediate warnings");
        SessionGate gate = new SessionGate();
        gate.begin("first"); gate.close("first"); gate.cleaned(warnings.released());
        check(gate.begin("next") != null, "warnings must permit the next engine");

        CleanupPolicy failed = new CleanupPolicy();
        check(!failed.released(), "release is unconfirmed until destroy completes");
        failed.destroy(() -> { throw new IllegalStateException("private destroy text"); });
        check(!failed.released() && failed.releaseStatus() == null, "failed destroy cannot report release");
        gate.close("next"); gate.cleaned(failed.released());
        check(gate.begin("blocked") == null && gate.cleanupFailed("next"), "destroy failure stays blocked");
        System.out.println("PASS: release, intermediate failures, destroy boundary, next-session exclusion");
    }
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
}
