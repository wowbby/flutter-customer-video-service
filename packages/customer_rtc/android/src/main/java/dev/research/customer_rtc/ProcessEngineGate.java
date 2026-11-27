package dev.research.customer_rtc;

/** RtcEngine.destroy() is process-global; a previous plugin can still be awaiting it. */
final class ProcessEngineGate {
    enum Acquisition { GRANTED, BUSY, RESTART_REQUIRED }
    static final ProcessEngineGate INSTANCE = new ProcessEngineGate();
    private Object owner;
    private boolean failed;

    synchronized Acquisition acquire(Object ticket) {
        if (ticket == null) throw new IllegalArgumentException("Missing ownership ticket");
        if (failed) return Acquisition.RESTART_REQUIRED;
        if (owner != null) return Acquisition.BUSY;
        owner = ticket;
        return Acquisition.GRANTED;
    }

    synchronized void finish(Object ticket, boolean destroyConfirmed) {
        if (ticket != owner || owner == null) return;
        if (destroyConfirmed) owner = null;
        else failed = true;
    }
}
