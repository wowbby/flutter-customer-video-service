import { call, observer, sim } from '@kit.TelephonyKit';

function stateName(state: call.CallState): string {
  switch (state) {
    case call.CallState.CALL_STATE_IDLE: return 'idle';
    case call.CallState.CALL_STATE_RINGING: return 'ringing';
    case call.CallState.CALL_STATE_OFFHOOK:
    case call.CallState.CALL_STATE_ANSWERED: return 'active';
    default: return 'unknown';
  }
}

export class SystemCallMonitor {
  sessionId: string = '';
  state: string = 'unknown';
  private callbacks: Array<(info: observer.CallStateInfo) => void> = [];
  private slotStates: Map<number, string> = new Map();
  private poll?: number;
  private epoch: number = 0;

  // A query without a session is read-only, including on devices without telephony.
  read(): string {
    try { return stateName(call.getCallStateSync()); } catch (_) { return 'unknown'; }
  }

  watch(id: string, changed: (id: string, state: string) => void): void {
    if (id === this.sessionId) { return; }
    this.stop();
    const epoch = this.epoch;
    this.sessionId = id;
    this.state = this.read();
    const publish = (state: string): void => {
      if (this.epoch !== epoch || state === 'unknown' || state === this.state) { return; }
      this.state = state;
      changed(id, state);
    };
    let count = 1;
    try { count = Math.max(1, sim.getMaxSimCount()); } catch (_) {}
    for (let slot = 0; slot < count; slot++) {
      const onCallState = (info: observer.CallStateInfo): void => {
        if (this.epoch !== epoch) { return; }
        const state = stateName(info.state);
        if (state === 'unknown') { return; }
        this.slotStates.set(slot, state);
        const states = Array.from(this.slotStates.values());
        if (states.includes('active')) { publish('active'); }
        else if (states.includes('ringing')) { publish('ringing'); }
        else if (this.slotStates.size === count) { publish('idle'); }
        else {
          // The initial idle notification on one SIM can precede the
          // initial state of another SIM. Consult the device-wide status.
          const current = this.read();
          publish(current === 'unknown' ? state : current);
        }
      };
      try {
        observer.on('callStateChange', { slotId: slot }, onCallState);
        this.callbacks.push(onCallState);
      } catch (_) {}
    }
    if (this.callbacks.length < count) {
      // Some firmware exposes CallManager but not StateRegistry for all slots.
      this.poll = setInterval(() => publish(this.read()), 500);
    }
  }

  stop(): void {
    ++this.epoch;
    if (this.poll !== undefined) { clearInterval(this.poll); this.poll = undefined; }
    this.callbacks.forEach((callback) => {
      try { observer.off('callStateChange', callback); } catch (_) {}
    });
    this.callbacks = [];
    this.slotStates.clear();
    this.sessionId = '';
    this.state = 'unknown';
  }
}
