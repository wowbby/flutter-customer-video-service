package dev.research.customer_rtc;

/** Confirms release only at the synchronous destroy boundary. */
final class CleanupPolicy {
    interface Step { int run() throws Exception; }
    interface Destroy { void run() throws Exception; }
    private boolean destroyed;
    private boolean warnings;
    void stop(Step action) { try { if (action.run() != 0) warnings = true; } catch (Exception ignored) { warnings = true; } }
    void destroy(Destroy action) {
        try { action.run(); destroyed = true; } catch (Exception ignored) {}
    }
    boolean released() { return destroyed; }
    String releaseStatus() { return destroyed ? (warnings ? "releasedWithWarnings" : "released") : null; }
}
