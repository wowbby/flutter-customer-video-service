package dev.research.customer_rtc;

/** Runs with javac/java without an Android runtime. */
public final class SessionGateCheck {
    public static void main(String[] args) {
        SessionGate gate = new SessionGate();
        Object first = gate.begin("first");
        check(first != null && gate.begin("duplicate") == null, "only one pending join");
        check(!gate.close("older"), "old leave cannot close current");
        check(gate.isCurrent(first), "old leave preserves callbacks");
        check(gate.close("first") && !gate.isCurrent(first), "cancel invalidates callbacks");
        check(gate.begin("second") == null, "new join waits for cleanup");
        gate.cleaned();
        Object second = gate.begin("second");
        check(second != null && !gate.isCurrent(first), "late permission cannot start new call");
        check(!gate.close("first") && gate.isCurrent(second), "late leave preserves new call");
        gate.close("second");
        gate.cleaned();
        Object reused = gate.begin("first");
        check(reused != null && !gate.isCurrent(first), "identity distinguishes reused session id");
        System.out.println("PASS: session isolation, pending cancel, cleanup exclusion, reused id");
    }
    private static void check(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }
}
