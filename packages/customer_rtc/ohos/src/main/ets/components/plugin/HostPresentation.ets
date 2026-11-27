import { systemDateTime } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { MethodCall } from '@ohos/flutter_ohos';

// App/Engine scope. Only the foreground native route mounts an overlay.
// Store a sanitized snapshot so a newly mounted route can restore it immediately.
export function monotonicMs(): number {
  return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP);
}

export function formatCallDuration(ms: number): string {
  const seconds = Math.floor(Math.max(0, ms) / 1000);
  const minutes = Math.floor(seconds / 60);
  const clock = (minutes % 60).toString().padStart(2, '0') + ':' + (seconds % 60).toString().padStart(2, '0');
  return minutes < 60 ? clock : Math.floor(minutes / 60).toString().padStart(2, '0') + ':' + clock;
}

export class HostSnapshot {
  sessionId: string = '';
  mode: string = 'mini';
  phase: string = '';
  probe: boolean = false;
  primaryVideo: string = 'remote';
  localAvatarPath: string = '';
  canSwapVideo: boolean = false;
  localWeak: boolean = false;
  remoteWeak: boolean = false;
  restartRequired: boolean = false;
  errorCode: string = '';
  needsToken: boolean = false;
  canRefreshToken: boolean = false;
  canControl: boolean = false;
  muted: boolean = false;
  cameraEnabled: boolean = true;
  speaker: boolean = true;
  quality: string = '';
  bindingFailed: boolean = false;

  awaitingAnswer: boolean = false;
  answeredMiniCard: boolean = false;
  previewMiniCard: boolean = false;
  showsCallSurface: boolean = false;
  rotated: boolean = false;
  canToggleOrientation: boolean = false;
  queueLabel: string = '';
  remoteVideo: boolean = false;
  miniRemoteVideo: boolean = false;
  audioRoute: string = '';
  connectedDurationMs: number = -1;
  miniElapsedMs: number = -1;
  sampledAt: number = monotonicMs();

  // An authoritative business duration replaces the media preview sample as
  // soon as the host accepts the call. Both surfaces use the same clock.
  get displayDurationMs(): number {
    return this.connectedDurationMs >= 0 ? this.connectedDurationMs : this.miniElapsedMs;
  }

  private elapsedAt(now: number): number {
    const delta = this.phase === 'ending' ? 0 : Math.max(0, now - this.sampledAt);
    return this.displayDurationMs + delta;
  }

  durationLabel(now: number): string { return formatCallDuration(this.elapsedAt(now)); }

  nextTickMs(now: number): number {
    return 1000 - Math.floor(this.elapsedAt(now)) % 1000;
  }

  get weakNotice(): string {
    if (!this.sessionId || this.probe || this.phase === 'ending') { return ''; }
    if (this.localWeak && this.remoteWeak) { return '当前双方网络不佳'; }
    if (this.localWeak) { return '当前你的网络不佳'; }
    return this.remoteWeak ? '当前对方网络不佳' : '';
  }

  get compactCard(): boolean {
    if (this.timedCard) { return true; }
    return this.mode === 'mini' && (this.previewMiniCard || (!this.probe && this.awaitingAnswer)) &&
      !this.restartRequired && !this.bindingFailed && !this.errorCode &&
      this.phase !== 'ending' && this.phase !== 'reconnecting';
  }

  get timedCard(): boolean {
    return this.mode === 'mini' && !this.probe && this.miniElapsedMs >= 0;
  }

  get cardShowsVideo(): boolean {
    return this.timedCard && this.miniRemoteVideo;
  }

  constructor(call?: MethodCall) {
    if (!call) { return; }
    this.sessionId = call.argument('sessionId') as string ?? '';
    this.mode = call.argument('mode') === 'full' ? 'full' : 'mini';
    this.phase = call.argument('phase') as string ?? '';
    this.probe = call.argument('probe') === true;
    this.primaryVideo = call.argument('primaryVideo') === 'local' ? 'local' : 'remote';
    const path = call.argument('localAvatarPath') as string | null;
    this.localAvatarPath = typeof path === 'string' && path.startsWith('/') ? path : '';
    this.canSwapVideo = call.argument('canSwapVideo') === true;
    this.awaitingAnswer = call.argument('awaitingAnswer') === true;
    this.answeredMiniCard = call.argument('answeredMiniCard') === true;
    this.previewMiniCard = call.argument('previewMiniCard') === true;
    this.showsCallSurface = call.argument('showsCallSurface') === true;
    this.rotated = call.argument('rotated') === true;
    this.canToggleOrientation = call.argument('canToggleOrientation') === true;
    this.queueLabel = call.argument('queueLabel') as string ?? '';
    this.remoteVideo = call.argument('remoteVideo') === true;
    this.miniRemoteVideo = call.argument('miniRemoteVideo') as boolean ?? this.remoteVideo;
    this.connectedDurationMs = call.argument('connectedDurationMs') as number ?? -1;
    this.miniElapsedMs = call.argument('miniElapsedMs') as number ?? (this.answeredMiniCard ? this.connectedDurationMs : -1);
    this.audioRoute = call.argument('audioRoute') as string ?? '';
    this.localWeak = call.argument('localWeak') === true;
    this.remoteWeak = call.argument('remoteWeak') === true;
    this.restartRequired = call.argument('restartRequired') === true;
    this.canControl = call.argument('canControl') === true;
    this.muted = call.argument('muted') === true;
    this.cameraEnabled = call.argument('cameraEnabled') !== false;
    this.speaker = call.argument('speaker') !== false;
    this.quality = call.argument('quality') as string ?? '';
    this.bindingFailed = call.argument('bindingFailed') === true;
    this.needsToken = call.argument('needsToken') === true;
    this.canRefreshToken = call.argument('canRefreshToken') === true;
    this.errorCode = call.argument('errorCode') as string ?? '';
  }
}

export interface HostDelegate {
  presentationAction(sessionId: string, action: string): void;
  readonly activeSessionId: string;
  readonly establishedSessionId: string;
  protectsPhoneBackground(sessionId: string): boolean;
  resumePhoneAudio(): void;
  stopForBackground(): void;
  didBackground(sessionId: string): boolean;
  handoff(role: string, renderId: string): void;
}

export class CustomerRtcHost {
  static readonly shared: CustomerRtcHost = new CustomerRtcHost();
  private delegate: HostDelegate | null = null;
  private observer: ((snapshot: HostSnapshot) => void) | null = null;
  private localId: string = '';
  private remoteId: string = '';
  private appBackground: boolean = false;
  private backgroundTransitions: number = 0;
  private phoneBackgroundId: string = '';
  private checkingBackgroundId: string = '';
  private backgroundTimer?: number;
  private interruptedSessions: Set<string> = new Set();
  private pendingBackground: Set<string> = new Set();
  private sequence: number = 0;
  private full: boolean = false;
  private presenter?: window.Window;
  private fullObservers: Set<(full: boolean, presenter?: window.Window) => void> = new Set();
  observeFullscreen(observer: (full: boolean, presenter?: window.Window) => void): () => void {
    this.fullObservers.add(observer);
    observer(this.full, this.presenter);
    return () => { this.fullObservers.delete(observer); };
  }
  setFullscreen(full: boolean): void {
    this.full = full;
    this.fullObservers.forEach((observer) => observer(full, this.presenter));
  }
  snapshot: HostSnapshot = new HostSnapshot();
  private weakNoticeUntil: number = 0;
  get weakNoticeRemainingMs(): number { return Math.max(0, this.weakNoticeUntil - monotonicMs()); }

  connect(delegate: HostDelegate): void { this.delegate = delegate; }
  disconnect(delegate: HostDelegate): void {
    if (this.delegate !== delegate) { return; }
    this.clearBackgroundCheck();
    this.phoneBackgroundId = '';
    this.delegate = null;
    this.pendingBackground.clear();
    this.update(new HostSnapshot());
  }
  update(snapshot: HostSnapshot): void {
    const newSession = snapshot.sessionId !== this.snapshot.sessionId;
    if (newSession) { this.clearSurfaces(); }
    if (newSession || snapshot.weakNotice !== this.snapshot.weakNotice) {
      const newWeakSide = newSession || (snapshot.localWeak && !this.snapshot.localWeak) ||
        (snapshot.remoteWeak && !this.snapshot.remoteWeak);
      this.weakNoticeUntil = newWeakSide && snapshot.weakNotice && this.observer && !this.appBackground ? monotonicMs() + 3000 : 0;
    }
    this.snapshot = snapshot;
    this.setFullscreen(!!snapshot.sessionId && snapshot.mode === 'full');
    this.observer?.(snapshot);
    if (this.appBackground && snapshot.sessionId && this.phoneBackgroundId !== snapshot.sessionId &&
        this.checkingBackgroundId !== snapshot.sessionId) {
      this.interrupt(snapshot.sessionId);
    }
  }

  attach(observer: (snapshot: HostSnapshot) => void, presenter?: window.Window): number {
    this.clearSurfaces();
    this.observer?.(new HostSnapshot());
    this.observer = observer;
    this.presenter = presenter;
    this.setFullscreen(this.full);
    observer(this.snapshot);
    return ++this.sequence;
  }
  detach(ticket: number): void {
    if (ticket !== this.sequence) { return; }
    this.weakNoticeUntil = 0;
    this.observer = null;
    this.presenter = undefined;
    this.setFullscreen(this.full);
    this.clearSurfaces();
  }
  private clearSurfaces(): void {
    if (this.localId) { this.localId = ''; this.delegate?.handoff('local', ''); }
    if (this.remoteId) { this.remoteId = ''; this.delegate?.handoff('remote', ''); }
  }
  surface(ticket: number, session: string, role: string, id: string, ready: boolean): void {
    if (ticket !== this.sequence || !this.observer || !session || session !== this.snapshot.sessionId) { return; }
    const current = role === 'local' ? this.localId : this.remoteId;
    if (!ready && current !== id) { return; }
    const next = ready ? id : '';
    if (next === current) { return; }
    if (role === 'local') { this.localId = next; } else { this.remoteId = next; }
    this.delegate?.handoff(role, next);
  }
  renderId(role: string, session: string): string {
    if (this.snapshot.sessionId !== session) { return ''; }
    return role === 'local' ? this.localId : this.remoteId;
  }
  action(ticket: number, session: string, action: string): void {
    if (ticket === this.sequence && this.observer && session && this.snapshot.sessionId === session) {
      this.delegate?.presentationAction(session, action);
    }
  }
  back(): boolean {
    if (!this.observer || !this.snapshot.sessionId || this.snapshot.mode !== 'full') { return false; }
    this.action(this.sequence, this.snapshot.sessionId, 'minimize');
    return true;
  }
  get isBackground(): boolean { return this.appBackground; }
  get backgroundEpoch(): number { return this.backgroundTransitions; }
  blocksJoin(id: string): boolean {
    return this.appBackground || this.interruptedSessions.has(id);
  }
  replayBackground(): void {
    const delegate = this.delegate;
    if (!delegate) { return; }
    Array.from(this.pendingBackground).forEach((id: string) => {
      this.pendingBackground.delete(id);
      if (!delegate.didBackground(id)) { this.pendingBackground.add(id); }
    });
  }
  private interrupt(id: string): void {
    if (!id || this.interruptedSessions.has(id)) { return; }
    this.interruptedSessions.add(id);
    this.pendingBackground.add(id);
    this.replayBackground();
  }
  private clearBackgroundCheck(): void {
    if (this.backgroundTimer !== undefined) { clearTimeout(this.backgroundTimer); this.backgroundTimer = undefined; }
    this.checkingBackgroundId = '';
  }
  phoneOwnsBackground(id: string): void {
    if (this.appBackground && id && (id === this.checkingBackgroundId ||
        id === this.delegate?.activeSessionId || id === this.snapshot.sessionId)) {
      this.phoneBackgroundId = id;
      this.clearBackgroundCheck();
    }
  }
  private finishBackgroundCheck(id: string): void {
    if (id !== this.checkingBackgroundId) { return; }
    this.clearBackgroundCheck();
    if (id === this.phoneBackgroundId || this.delegate?.protectsPhoneBackground(id)) {
      this.phoneBackgroundId = id;
    } else if (id === (this.delegate?.activeSessionId || this.snapshot.sessionId)) {
      this.stopForBackground();
    }
  }
  foreground(): void {
    if (this.checkingBackgroundId) { this.finishBackgroundCheck(this.checkingBackgroundId); }
    this.appBackground = false;
    this.phoneBackgroundId = '';
    this.observer?.(this.snapshot);
    this.delegate?.resumePhoneAudio();
  }
  background(): void {
    if (this.appBackground) { return; }
    ++this.backgroundTransitions;
    this.interruptedSessions.clear();
    this.appBackground = true;
    this.weakNoticeUntil = 0;
    this.observer?.(this.snapshot);
    const id = this.delegate?.activeSessionId || this.snapshot.sessionId;
    if (id && this.delegate?.protectsPhoneBackground(id)) {
      this.phoneBackgroundId = id;
    } else if (id && (this.delegate?.establishedSessionId === id ||
        (this.snapshot.sessionId === id && !this.snapshot.probe && this.snapshot.phase === 'waiting'))) {
      // A queued call already owns its waiting window before an RTC engine exists.
      // The dialer can hide that window, or an established call, before TelephonyKit reports ringing.
      this.checkingBackgroundId = id;
      this.backgroundTimer = setTimeout(() => this.finishBackgroundCheck(id), 400);
    } else { this.stopForBackground(); }
  }
  destroy(): void {
    this.clearBackgroundCheck();
    this.phoneBackgroundId = '';
    this.appBackground = true;
    this.stopForBackground();
  }
  private stopForBackground(): void {
    try {
      this.interrupt(this.snapshot.sessionId);
      this.interrupt(this.delegate?.activeSessionId ?? '');
    } finally {
      this.delegate?.stopForBackground();
    }
  }
}
