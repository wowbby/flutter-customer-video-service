package dev.research.customer_rtc;

final class SessionGate {
    private Object ticket;
    private String sessionId;
    private boolean cleaning;
    private boolean cleanupFailure;
    Object begin(String id) {
        if (ticket != null || cleaning) return null;
        sessionId = id;
        ticket = new Object();
        return ticket;
    }
    boolean close(String id) {
        if (ticket == null || !sessionId.equals(id)) return false;
        ticket = null;
        cleaning = true;
        return true;
    }
    boolean isCurrent(Object candidate) { return candidate != null && candidate == ticket; }
    void cleaned() { cleaned(true); }
    void cleaned(boolean success) {
        cleanupFailure = !success;
        if (success) { cleaning = false; sessionId = null; }
    }
    boolean cleanupFailed(String id) { return cleanupFailure && id.equals(sessionId); }
}
