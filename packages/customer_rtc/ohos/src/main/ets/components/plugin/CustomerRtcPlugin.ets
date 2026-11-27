import { AbilityAware, AbilityPluginBinding, Any, FlutterManager, EventChannel, EventSink, FlutterPlugin,
  FlutterPluginBinding, MethodCall, MethodCallHandler, MethodChannel, MethodResult, StreamHandler } from '@ohos/flutter_ohos';
import { abilityAccessCtrl, ApplicationStateChangeCallback, common, Permissions } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { audio } from '@kit.AudioKit';
import { HostDelegate, HostSnapshot, CustomerRtcHost } from './HostPresentation';
import { CameraCapturerConfiguration, CaptureFormat, VideoEncoderConfiguration, VideoDimensions, ChannelMediaOptions, Constants, IRtcEngineEventHandler, LogConfig, RtcEngine,
  RtcEngineConfig, VideoCanvas } from '@shengwang/rtc-full';
import { CustomerVideoFactory, CustomerVideoView, VideoViewOwner } from './CustomerViews';
import { DEBUG } from '../../../../../BuildProfile';
import { CallWindowBars } from './CallWindowBars';
import { SystemCallMonitor } from './SystemCallMonitor';
import { CleanupPolicy } from './CleanupPolicy';

class RtcOperationError extends Error {
  readonly sdkCode: number;
  constructor(code: number) { super('Native RTC operation failed'); this.sdkCode = code; }
}

/** One native engine per active session. Views never own the engine or leave the channel. */
export default class CustomerRtcPlugin implements FlutterPlugin, MethodCallHandler, StreamHandler, AbilityAware, VideoViewOwner, HostDelegate {
  // Agora's destroy is process-global and asynchronous. Keep the lease until
  // it fulfills, even when Flutter has already constructed the next plugin.
  private static owner: CustomerRtcPlugin | null = null;
  private static releaseUnconfirmed: boolean = false;
  private releaseLease(confirmed: boolean): void {
    if (CustomerRtcPlugin.owner === this) {
      CustomerRtcPlugin.releaseUnconfirmed = !confirmed;
      CustomerRtcPlugin.owner = null;
    }
  }
  private channel: MethodChannel | null = null;
  private events: EventChannel | null = null;
  private sink: EventSink | null = null;
  private context: common.UIAbilityContext | null = null;
  private engine: RtcEngine | null = null;
  private session: string | null = null;
  private pending: MethodResult | null = null;
  private generation: number = 0;
  private remoteUid: number = 0;
  private expectedPeerUid: number = 0;
  private lastAudioRoute: string = '';
  private phone: SystemCallMonitor = new SystemCallMonitor();
  private phoneEndedId: string = '';
  private pendingPhoneEnd: string = '';
  private phoneRang: boolean = false;
  private audioRestorePending: boolean = false;
  private audioAppBackground: boolean = false;
  private audioAppContext?: common.ApplicationContext;
  // Flutter-only hosts need this even when they do not wire CustomerRtcHost.
  private audioLifecycle: ApplicationStateChangeCallback = {
    onApplicationBackground: () => { this.audioAppBackground = true; },
    onApplicationForeground: () => {
      this.audioAppBackground = false;
      this.resumePhoneAudio();
    }
  };
  private captureInterrupted: boolean = false;
  private userMuted: boolean = false;
  private userSpeaker: boolean = true;
  private host: CustomerRtcHost = CustomerRtcHost.shared;
  private cleanup: Promise<string> | null = null;
  private cleanupSession: string | null = null;
  private lastReleasedId: string | null = null;
  private lastReleaseStatus: string = 'released';
  private cleanupFailed: boolean = false;
  private videos: Map<number, CustomerVideoView> = new Map();

  private callBars: CallWindowBars = new CallWindowBars();
  private stopWindowObserver?: () => void;
  getUniqueClassName(): string { return 'CustomerRtcPlugin'; }
  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.host.connect(this);
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'customer_rtc');
    this.channel.setMethodCallHandler(this);
    this.events = new EventChannel(binding.getBinaryMessenger(), 'customer_rtc/events');
    this.events.setStreamHandler(this);
    binding.getPlatformViewRegistry().registerViewFactory('customer_rtc/video', new CustomerVideoFactory(this));
  }
  onAttachedToAbility(binding: AbilityPluginBinding): void {
    const ability = binding.getAbility();
    this.context = ability.context;
    if (!this.audioAppContext) {
      try {
        const app = ability.context.getApplicationContext();
        app.on('applicationStateChange', this.audioLifecycle);
        this.audioAppContext = app;
      } catch (_) {} // An explicitly wired native host also supplies visibility.
    }
    this.stopWindowObserver?.();
    this.stopWindowObserver = this.host.observeFullscreen((full: boolean, presenter?: window.Window) => {
      if (full) {
        try {
          const stage = FlutterManager.getInstance().getWindowStage(ability);
          if (stage) { this.callBars.show(stage.getMainWindowSync(), presenter); }
        } catch (_) { /* The window stage can disappear during Ability teardown. */ }
      } else { this.callBars.show(); }
    });
  }
  onDetachedFromAbility(): void {
    this.stopWindowObserver?.();
    this.stopWindowObserver = undefined;
    this.callBars.show();
    this.context = null;
    // Permission results belong to the detached Ability. Established engines survive host handoff.
    if (this.pending !== null && this.engine === null) { this.stopSession().catch(() => {}); }
  }
  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.events?.setStreamHandler(null);
    this.sink = null;
    this.stopWindowObserver?.();
    this.stopWindowObserver = undefined;
    this.callBars.show();
    try { this.audioAppContext?.off('applicationStateChange', this.audioLifecycle); } catch (_) {}
    this.audioAppContext = undefined;
    this.phone.stop();
    this.host.disconnect(this);
    this.stopSession().catch(() => {});
    this.videos.clear();
  }
  onListen(args: Any, events: EventSink): void {
    this.sink = events;
    if (this.pendingPhoneEnd) { this.sendPhoneEnd(this.pendingPhoneEnd); }
    this.host.replayBackground();
  }
  onCancel(args: Any): void { this.sink = null; }
  emit(event: Map<string, Object>): void { this.sink?.success(event); }
  private rtcEvent(id: string, generation: number, type: string, extra?: Map<string, Object>): void {
    // SDK callbacks arrive through its ArkTS dispatcher. Queue onto this UI JS loop and recheck identity.
    setTimeout(() => {
      if (this.session !== id || this.generation !== generation) { return; }
      const event = extra ?? new Map<string, Object>();
      event.set('type', type); event.set('sessionId', id);
      this.emit(event);
    }, 0);
  }
  private current(id: string, generation: number): boolean { return this.session === id && this.generation === generation; }
  private check(code: number): void { if (code !== 0) { throw new RtcOperationError(code); } }
  private errorDetails(operation: string, recovery: string, sdkCode?: number): Map<string, Object> {
    const operations = ['setVideoQuality', 'rebindVideo', 'join', 'leave', 'setMuted', 'setCameraEnabled', 'switchCamera', 'setSpeaker', 'renewToken', 'event'];
    const details = new Map<string, Object>([['operation', operations.indexOf(operation) >= 0 ? operation : 'event'], ['recovery', recovery]]);
    if (sdkCode !== undefined) { details.set('sdkCode', sdkCode); }
    return details;
  }
  private releaseResult(status: string): Map<string, Object> {
    return new Map<string, Object>([['releaseStatus', status]]);
  }
  // Debug-only numeric media telemetry. No SDK objects, identities or credentials.
  private mediaDiagnostic(id: string, generation: number, message: string): void {
    if (DEBUG && this.current(id, generation)) { console.info(`CustomerRtcDiag ${message}`); }
  }
  private handlers(id: string, generation: number): IRtcEngineEventHandler {
    return {
      onNetworkQuality: (uid, txQuality, rxQuality) => {
        if (uid === 0 || uid === this.remoteUid) {
          this.rtcEvent(id, generation, 'networkQuality', new Map<string, Object>([['uid', uid], ['txQuality', txQuality], ['rxQuality', rxQuality]]));
        }
      },
      onRtcStats: () => { if (this.current(id, generation)) { this.reportAudioRoute(id, generation); } },
      onLocalVideoStateChanged: (source, state, reason) => {
        if (source === Constants.VideoSourceType.CAMERA_PRIMARY) {
          this.rtcEvent(id, generation, 'mediaTrackState', new Map<string, Object>([['track', 'localVideo'], ['state', state], ['reason', reason]]));
        }
      },
      onLocalAudioStateChanged: (state, reason) => {
        if (this.current(id, generation)) {
          this.captureInterrupted = reason === Constants.LocalAudioStreamReason.INTERRUPTED ||
            reason === Constants.LocalAudioStreamReason.DEVICE_BUSY;
        }
        this.rtcEvent(id, generation, 'mediaTrackState', new Map<string, Object>([['track', 'localAudio'], ['state', state], ['reason', reason]]));
      },
      onRemoteVideoStateChanged: (uid, state, reason) => {
        if (uid !== 0 && this.remoteUid === uid) {
          this.rtcEvent(id, generation, 'mediaTrackState', new Map<string, Object>([['track', 'remoteVideo'], ['uid', uid], ['state', state], ['reason', reason]]));
        }
      },
      onLocalVideoStats: (_source, stats) => {
        this.mediaDiagnostic(id, generation, `localStats capture=${stats.captureFrameRate} encode=${stats.encoderOutputFrameRate} send=${stats.sentFrameRate} kbps=${stats.sentBitrate} loss=${stats.txPacketLossRate}`);
      },
      onRemoteVideoStats: (stats) => {
        if (this.current(id, generation) && this.remoteUid === stats.uid) {
          this.mediaDiagnostic(id, generation, `remoteStats kbps=${stats.receivedBitrate} decode=${stats.decoderOutputFrameRate} render=${stats.rendererOutputFrameRate} loss=${stats.packetLossRate}`);
          this.rtcEvent(id, generation, 'remoteVideoStats', new Map<string, Object>([['uid', stats.uid], ['rendererOutputFrameRate', stats.rendererOutputFrameRate]]));
        }
      },
      onJoinChannelSuccess: (_channel: string, uid: number) => {
        this.rtcEvent(id, generation, 'joined', new Map<string, Object>([['uid', uid]]));
      },
      onUserJoined: (uid: number) => {
        if (!this.current(id, generation) || !this.engine || this.remoteUid !== 0 || uid <= 0 ||
          (this.expectedPeerUid !== 0 && uid !== this.expectedPeerUid)) { return; }
        try {
          this.check(this.engine.muteRemoteAudioStream(uid, false));
          const video = this.engine.muteRemoteVideoStream(uid, false);
          if (video !== 0) {
            this.engine.muteRemoteAudioStream(uid, true);
            throw new RtcOperationError(video);
          }
        } catch (error) {
          const code = error instanceof RtcOperationError ? error.sdkCode : undefined;
          // Notify before invalidating the original session, then close immediately:
          // another peer callback must not be able to subscribe before Dart handles the error.
          try {
            this.emit(new Map<string, Object>([['type', 'error'], ['sessionId', id], ['code', 'sdkError'],
              ['details', this.errorDetails('event', 'retryCall', code)]]));
          } finally {
            this.stopSession().catch(() => {});
          }
          return;
        }
        this.remoteUid = uid;
        this.bindVideos();
        this.rtcEvent(id, generation, 'remoteJoined', new Map<string, Object>([['uid', uid]]));
      },
      onUserOffline: (uid: number) => {
        if (!this.current(id, generation) || this.remoteUid !== uid) { return; }
        this.remoteUid = 0;
        // A departing UID can rejoin after we have selected another member.
        // The SDK may already have removed its streams; attempt both releases independently.
        try { this.engine?.muteRemoteAudioStream(uid, true); } catch (_) {}
        try { this.engine?.muteRemoteVideoStream(uid, true); } catch (_) {}
        this.unbindRemote(uid);
        this.rtcEvent(id, generation, 'remoteLeft', new Map<string, Object>([['uid', uid]]));
      },
      onFirstRemoteVideoFrame: (uid: number) => {
        if (this.current(id, generation) && this.remoteUid === uid) {
          this.rtcEvent(id, generation, 'remoteVideo', new Map<string, Object>([['uid', uid]]));
        }
      },
      onConnectionStateChanged: (state: Constants.ConnectionState, reason: Constants.ConnectionChangedReason) => {
        const states: string[] = ['disconnected', 'disconnected', 'connecting', 'connected', 'reconnecting', 'failed'];
        this.rtcEvent(id, generation, 'connection', new Map<string, Object>([['state', states[state] ?? 'failed'], ['reason', reason]]));
      },
      onTokenPrivilegeWillExpire: () => this.rtcEvent(id, generation, 'tokenRequired'),
      onRequestToken: () => this.rtcEvent(id, generation, 'tokenRequired'),
      onError: (code: Constants.ErrorCode) => {
        this.rtcEvent(id, generation, 'error', new Map<string, Object>([['code', 'sdkError'], ['message', 'RTC SDK reported an error.'], ['details', this.errorDetails('event', 'retryCall', code)]]));
      }
    };
  }
  presentationAction(id: string, action: string): void {
    if (this.host.snapshot.sessionId === id) {
      this.emit(new Map<string, Object>([['type', 'presentationAction'], ['sessionId', id], ['action', action]]));
    }
  }
  get activeSessionId(): string { return this.session ?? ''; }
  get establishedSessionId(): string { return this.engine && !this.pending ? this.activeSessionId : ''; }
  stopForBackground(): void {
    if (this.session !== null) { this.stopSession('host_background').catch(() => {}); }
  }
  didBackground(id: string): boolean {
    if (!this.sink) { return false; }
    try {
      this.emit(new Map<string, Object>([['type', 'hostBackground'], ['sessionId', id]]));
      return true;
    } catch (_) {
      // A torn-down messenger can reject a send before onCancel is delivered.
      return false;
    }
  }
  private watchPhone(id: string): void {
    if (id !== this.phone.sessionId) { this.phoneRang = false; }
    this.phone.watch(id, (sessionId, state) => this.phoneChanged(sessionId, state));
  }
  private phoneEvent(id: string, state: string): void {
    this.emit(new Map<string, Object>([['type', 'systemCallState'], ['sessionId', id], ['state', state]]));
  }
  private sendPhoneEnd(id: string): void {
    this.pendingPhoneEnd = id;
    try {
      if (this.sink) { this.phoneEvent(id, 'active'); this.pendingPhoneEnd = ''; }
    } catch (_) {}
  }
  private phoneChanged(id: string, state: string): void {
    if (state === 'active' || state === 'ringing') { this.host.phoneOwnsBackground(id); }
    if (state === 'active') {
      this.phoneEndedId = id;
      try { this.sendPhoneEnd(id); }
      finally {
        if (this.session === id) { this.stopSession('system_call_busy').catch(() => {}); }
        else { this.phone.stop(); }
      }
    } else if (state === 'ringing') {
      this.phoneRang = true;
      if (this.session === id && this.pending) {
        this.stopSession('system_call_busy').catch(() => {});
      } else {
        this.applyPhoneAudio(id, this.generation, true, 2);
        this.phoneEvent(id, state);
      }
    } else if (state === 'idle' && this.phoneRang) {
      this.phoneRang = false;
      this.applyPhoneAudio(id, this.generation, false, 2);
      this.phoneEvent(id, state);
    }
  }
  resumePhoneAudio(): void {
    const id = this.session;
    if (!this.audioRestorePending || !id || this.audioAppBackground || this.host.isBackground) { return; }
    const state = this.phone.read();
    if (state === 'active' || state === 'ringing') {
      if (state !== this.phone.state) {
        this.phone.state = state;
        this.phoneChanged(id, state);
      }
      return;
    }
    if (!this.phoneRang) { this.applyPhoneAudio(id, this.generation, false, 2); }
  }
  private applyPhoneAudio(id: string, generation: number, ringing: boolean, retries: number): void {
    const engine = this.engine;
    if (!engine || !this.current(id, generation) || this.phoneRang !== ringing) { return; }
    if (!ringing) {
      this.audioRestorePending = this.audioAppBackground || this.host.isBackground;
      if (this.audioRestorePending) { return; }
    }
    // Focus can return just after the phone's idle event. Never open capture
    // for a muted user, or override a connected headset during a route change.
    let retry = false;
    try {
      if (!ringing && this.captureInterrupted && !this.userMuted) {
        if (engine.enableLocalAudio(true) === 0) { this.captureInterrupted = false; }
        else { retry = true; }
      }
      if (engine.muteLocalAudioStream(ringing || this.userMuted) !== 0) { retry = true; }
    } catch (_) { retry = true; }
    try { if (engine.adjustPlaybackSignalVolume(ringing ? 0 : 100) !== 0) { retry = true; } }
    catch (_) { retry = true; }
    if (!ringing) { this.reportAudioRoute(id, generation); }
    if (!ringing && ((this.lastAudioRoute === 'speaker' && !this.userSpeaker) ||
        (this.lastAudioRoute === 'earpiece' && this.userSpeaker))) {
      try {
        const devices = audio.getAudioManager().getRoutingManager().getDevicesSync(audio.DeviceFlag.OUTPUT_DEVICES_FLAG);
        const builtInOnly = devices.length > 0 && devices.every(device =>
          device.deviceType === audio.DeviceType.SPEAKER || device.deviceType === audio.DeviceType.EARPIECE);
        if (builtInOnly && engine.setEnableSpeakerphone(this.userSpeaker) !== 0) { retry = true; }
      } catch (_) { retry = true; }
    }
    if (retry && retries > 0) {
      setTimeout(() => this.applyPhoneAudio(id, generation, ringing, retries - 1), 400);
    }
  }
  protectsPhoneBackground(id: string): boolean {
    if (id === '') { return false; }
    if (id === this.phoneEndedId) { return true; }
    if (id !== this.phone.sessionId) { return false; }
    const state = this.phone.read();
    if (state === 'active') { this.phoneChanged(id, state); return true; }
    if (state === 'ringing' && !this.phoneRang) {
      this.phone.state = state;
      this.phoneChanged(id, state);
    }
    return state === 'ringing' || this.phoneRang;
  }
  private reportAudioRoute(id: string, generation: number): void {
    // This HAR has no routing delegate. Query the OS's current communication renderers;
    // report a route only when their output device is unambiguous.
    try {
      const streams = audio.getAudioManager().getStreamManager().getCurrentAudioRendererInfoArraySync()
        .filter((stream) => stream.rendererInfo.usage === audio.StreamUsage.STREAM_USAGE_VOICE_COMMUNICATION ||
          stream.rendererInfo.usage === audio.StreamUsage.STREAM_USAGE_VIDEO_COMMUNICATION);
      let route = '';
      for (const stream of streams) {
        for (const device of stream.deviceDescriptors) {
          let next = 'other';
          switch (device.deviceType) {
            case audio.DeviceType.SPEAKER: next = 'speaker'; break;
            case audio.DeviceType.EARPIECE: next = 'earpiece'; break;
            case audio.DeviceType.WIRED_HEADPHONES:
            case audio.DeviceType.WIRED_HEADSET:
            case audio.DeviceType.USB_HEADSET: next = 'wired'; break;
            case audio.DeviceType.BLUETOOTH_A2DP:
            case audio.DeviceType.BLUETOOTH_SCO: next = 'bluetooth'; break;
          }
          if (route && next !== route) { route = 'other'; break; }
          route = next;
        }
      }
      if (!route) { route = 'other'; }
      if (route !== this.lastAudioRoute) {
        this.lastAudioRoute = route;
        this.rtcEvent(id, generation, 'audioRoute', new Map<string, Object>([['route', route]]));
      }
    } catch (_) { this.lastAudioRoute = ''; } // Route introspection is optional on older OS versions.
  }
  private encoder(quality: string): VideoEncoderConfiguration {
    if (quality !== 'hd' && quality !== 'sd') { throw new Error('invalid_arguments'); }
    const encoder = new VideoEncoderConfiguration();
    encoder.dimensions = quality === 'hd' ? new VideoDimensions(1280, 720) : new VideoDimensions(640, 360);
    encoder.frameRate = 15;
    return encoder;
  }
  onMethodCall(call: MethodCall, result: MethodResult): void {
    if (call.method === 'setFlutterCallFullscreen') {
      this.host.setFullscreen(call.argument('fullscreen') === true);
      result.success(null); return;
    }
    if (call.method === 'updatePresentation') {
      const snapshot = new HostSnapshot(call);
      if (!snapshot.sessionId && !this.session && this.host.snapshot.sessionId === this.phone.sessionId) {
        this.phone.stop();
      }
      this.host.update(snapshot);
      result.success(null); return;
    }
    if (call.method === 'endSystemCallObservation') {
      const id = call.argument('sessionId') as string;
      if (id && id === this.phone.sessionId && this.session !== id) { this.phone.stop(); }
      result.success(null); return;
    }
    if (call.method === 'getSystemCallState') {
      const id = call.argument('sessionId') as string;
      let state = this.phone.read();
      if (id && state !== 'active' && state !== 'ringing' && (!this.session || this.session === id)) {
        this.watchPhone(id);
        if (this.phone.state === 'active' || this.phone.state === 'ringing') { state = this.phone.state; }
      }
      result.success(state); return;
    }
    if (call.method === 'getPlatformVersion') { result.success('HarmonyOS / Agora 4.4.2'); return; }
    if (call.method === 'join') { this.join(call, result); return; }
    if (call.method === 'leave') {
      const id = call.argument('sessionId') as string;
      if (typeof id !== 'string' || id.length === 0) { result.error('invalid_arguments', 'sessionId is required.', null); return; }
      if (id === this.phone.sessionId) { this.phone.stop(); }
      if (this.cleanupFailed || CustomerRtcPlugin.releaseUnconfirmed) {
        result.error('cleanup_failed', 'RTC cleanup remains unconfirmed; restart the app.', this.errorDetails('leave', 'restartRequired')); return;
      }
      if (this.session !== id) {
        // A second leave during cleanup must await that cleanup, but may never touch a new session.
        if (this.cleanupSession === id && this.cleanup !== null) {
          this.cleanup.then((status) => result.success(this.releaseResult(status))).catch(() => result.error('cleanup_failed', 'RTC cleanup failed.', this.errorDetails('leave', 'restartRequired')));
        } else { result.success(this.releaseResult(this.lastReleasedId === id ? this.lastReleaseStatus : 'released')); }
        return;
      }
      this.stopSession().then((status) => result.success(this.releaseResult(status))).catch(() => result.error('cleanup_failed', 'RTC cleanup failed.', this.errorDetails('leave', 'restartRequired')));
      return;
    }
    const methods = ['rebindVideo', 'setVideoQuality', 'setMuted', 'setCameraEnabled', 'switchCamera', 'setSpeaker', 'renewToken'];
    if (methods.indexOf(call.method) < 0) { result.notImplemented(); return; }
    const id = call.argument('sessionId') as string;
    const engine = this.engine;
    if (id !== this.session || !engine || this.cleanup !== null) {
      result.error('no_active_session', 'No matching active session.', null); return;
    }
    try {
      switch (call.method) {
        case 'rebindVideo': {
          const failure = this.bindVideos();
          if (failure !== undefined) { throw failure; }
          break;
        }
        case 'setVideoQuality': this.check(engine.setVideoEncoderConfiguration(this.encoder(call.argument('quality') as string))); break;
        case 'setMuted': {
          const muted = this.booleanArgument(call, 'muted');
          const held = this.phoneRang || this.audioRestorePending;
          if (!muted && this.captureInterrupted && !held) { this.check(engine.enableLocalAudio(true)); }
          this.check(engine.muteLocalAudioStream(held || muted));
          this.userMuted = muted;
          break;
        }
        case 'setCameraEnabled':
          this.check(engine.enableLocalVideo(this.booleanArgument(call, 'enabled'))); break;
        case 'switchCamera': this.check(engine.switchCamera()); break;
        case 'setSpeaker': {
          const speaker = this.booleanArgument(call, 'enabled');
          if (!this.phoneRang && !this.audioRestorePending) { this.check(engine.setEnableSpeakerphone(speaker)); }
          this.userSpeaker = speaker;
          break;
        }
        case 'renewToken': {
          const token = call.argument('token') as string;
          if (typeof token !== 'string' || token.length === 0) { throw new Error('invalid_arguments'); }
          this.check(engine.renewToken(token)); break;
        }
      }
      result.success(null);
    } catch (error) {
      if (error instanceof RtcOperationError) {
        result.error('sdkError', 'RTC operation failed.', this.errorDetails(call.method, 'retryOperation', error.sdkCode));
      } else {
        result.error('rtc_operation_failed', 'RTC operation failed or arguments were invalid.', this.errorDetails(call.method, 'retryOperation'));
      }
    }
  }
  private booleanArgument(call: MethodCall, key: string): boolean {
    const value = call.argument(key) as boolean;
    if (typeof value !== 'boolean') { throw new Error('invalid_arguments'); }
    return value;
  }
  private async join(call: MethodCall, result: MethodResult): Promise<void> {
    if (CustomerRtcPlugin.releaseUnconfirmed) {
      result.error('cleanup_failed', 'RTC cleanup remains unconfirmed; restart the app.', this.errorDetails('join', 'restartRequired'));
      return;
    }
    const id = call.argument('sessionId') as string;
    if (id && this.host.blocksJoin(id)) {
      const state = this.phone.read();
      if (this.phoneEndedId === id || state === 'active' || state === 'ringing') {
        result.error('system_call_busy', 'A system phone call is in progress.', null);
      } else {
        result.error('host_background', 'App backgrounded during this session.', null);
      }
      return;
    }
    if (this.session !== null || this.cleanup !== null || this.cleanupFailed || CustomerRtcPlugin.owner !== null) {
      result.error('busy', 'An active session or native cleanup is pending.', null); return;
    }
    const appId = call.argument('appId') as string;
    const room = call.argument('channel') as string;
    const token = call.argument('token') as string;
    const uid = call.argument('uid') as number;
    const expected = call.argument('expectedPeerUid') as number;
    const camera = call.argument('cameraFacing') as string;
    const quality = call.argument('videoQuality') as string;
    if (typeof id !== 'string' || !id || typeof appId !== 'string' || !/^[0-9a-fA-F]{32}$/.test(appId) ||
      typeof room !== 'string' || !room.trim() || typeof token !== 'string' ||
      (expected != null && (!Number.isInteger(expected) || expected <= 0 || expected > 4294967295 || expected === uid)) ||
      (camera != null && camera !== 'front' && camera !== 'rear') ||
      (quality != null && quality !== 'sd' && quality !== 'hd') ||
      typeof uid !== 'number' || !Number.isInteger(uid) || uid < 1 || uid > 4294967295) {
      result.error('invalid_arguments', 'Invalid session, App ID, channel, token or UID.', null); return;
    }
    this.watchPhone(id);
    const state = this.phone.read();
    if (id === this.phoneEndedId || state === 'active' || state === 'ringing' ||
        this.phone.state === 'active' || this.phone.state === 'ringing') {
      this.phone.stop();
      result.error('system_call_busy', 'A system phone call is in progress.', null); return;
    }
    const backgroundEpoch = this.host.backgroundEpoch;
    const context = this.context;
    if (!context) { this.phone.stop(); result.error('missing_activity', 'No foreground ability.', null); return; }
    if (this.lastReleasedId === id) { this.lastReleasedId = null; }
    this.session = id;
    CustomerRtcPlugin.owner = this;
    this.expectedPeerUid = expected ?? 0;
    this.lastAudioRoute = '';
    this.userMuted = false;
    this.userSpeaker = true;
    this.phoneRang = false;
    this.captureInterrupted = false;
    this.audioRestorePending = false;
    const generation = ++this.generation;
    this.pending = result;
    try {
      const permissions: Permissions[] = ['ohos.permission.CAMERA', 'ohos.permission.MICROPHONE'];
      const permission = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, permissions);
      if (!this.current(id, generation)) { return; }
      const afterPermission = this.phone.read();
      if (afterPermission === 'ringing' || afterPermission === 'active') {
        await this.stopSession('system_call_busy');
        return;
      }
      if (this.host.blocksJoin(id) || this.host.backgroundEpoch !== backgroundEpoch) {
        await this.stopSession('host_background');
        return;
      }
      if (permission.authResults.length !== 2 || permission.authResults.some((value) => value !== 0)) {
        this.phone.stop();
        this.pending = null; this.session = null; ++this.generation; this.releaseLease(true);
        result.error('permission_denied', 'Camera and microphone permissions are required.', null); return;
      }
      const config = new RtcEngineConfig();
      config.mContext = context;
      config.mAppId = appId;
      config.mEventHandler = this.handlers(id, generation);
      const logs = new LogConfig(); logs.level = Constants.LogLevel.NONE; config.mLogConfig = logs;
      const engine = RtcEngine.create(config);
      this.engine = engine;
      if (quality) { this.check(engine.setVideoEncoderConfiguration(this.encoder(quality))); }
      if (camera) {
        const capture = new CameraCapturerConfiguration();
        capture.cameraDirection = camera === 'rear' ? Constants.CameraDirection.REAR : Constants.CameraDirection.FRONT;
        capture.cameraFormat = new CaptureFormat();
        // SDK 4.4.2 requires this call before enabling local video. Capture
        // enough detail for either encoder preset without restarting the camera.
        capture.cameraFormat.width = 1280;
        capture.cameraFormat.height = 720;
        capture.cameraFormat.fps = 15;
        capture.followEncodeDimensionRatio = true;
        this.check(engine.setCameraCapturerConfiguration(capture));
      }
      this.check(engine.enableVideo());
      this.check(engine.setDefaultAudioRoutetoSpeakerphone(true));
      this.bindVideos();
      this.check(engine.startPreview());
      const options = new ChannelMediaOptions();
      options.channelProfile = Constants.ChannelProfile.COMMUNICATION;
      options.publishCameraTrack = true; options.publishMicrophoneTrack = true;
      options.autoSubscribeAudio = false; options.autoSubscribeVideo = false;
      this.check(engine.joinChannelWithOptions(token, room, uid, options));
      if (!this.current(id, generation)) { return; }
      this.pending = null;
      result.success(null);
    } catch (error) {
      if (!this.current(id, generation)) { return; }
      this.pending = null;
      try { await this.stopSession(); } catch (_) {}
      if (error instanceof RtcOperationError) {
        result.error('sdkError', 'RTC initialization failed.', this.errorDetails('join', 'retryCall', error.sdkCode));
      } else {
        result.error('join_failed', 'Permission request or RTC initialization failed.', this.errorDetails('join', 'retryCall'));
      }
    }
  }
  private async stopSession(pendingCode: string = 'cancelled'): Promise<string> {
    if (this.cleanupFailed) { throw new Error('cleanup_failed'); }
    if (this.cleanup !== null) { return this.cleanup; }
    const id = this.session;
    if (id === this.phone.sessionId) { this.phone.stop(); }
    ++this.generation;
    this.session = null;
    this.audioRestorePending = false;
    this.pending?.error(pendingCode, 'Join was cancelled.', null);
    this.pending = null;
    const engine = this.engine;
    this.engine = null;
    const remoteUid = this.remoteUid;
    this.remoteUid = 0;
    if (!engine) {
      this.releaseLease(true);
      if (id !== null) { this.lastReleasedId = id; this.lastReleaseStatus = 'released'; }
      return 'released';
    }
    this.cleanupSession = id;
    const cleanup = this.destroyEngine(engine, remoteUid);
    this.cleanup = cleanup;
    try {
      const status = await cleanup;
      this.lastReleasedId = id;
      this.lastReleaseStatus = status;
      this.releaseLease(true);
      return status;
    } catch (_) {
      this.cleanupFailed = true;
      this.releaseLease(false);
      throw new Error('cleanup_failed');
    } finally {
      this.cleanup = null;
      this.cleanupSession = null;
    }
  }
  private async destroyEngine(engine: RtcEngine, remoteUid: number): Promise<string> {
    const policy = new CleanupPolicy();
    // Intermediate failures are warnings once async destruction has fulfilled.
    policy.stop(() => engine.stopPreview());
    policy.stop(() => engine.enableLocalVideo(false));
    policy.stop(() => engine.enableLocalAudio(false));
    policy.stop(() => engine.setupLocalVideo(new VideoCanvas('')));
    if (remoteUid !== 0) {
      policy.stop(() => {
        const canvas = new VideoCanvas(''); canvas.uid = remoteUid;
        return engine.setupRemoteVideo(canvas);
      });
    }
    policy.stop(() => engine.leaveChannel());
    return policy.destroy(() => RtcEngine.destroy());
  }
  addVideo(view: CustomerVideoView): void { this.videos.set(view.id, view); }
  videoReady(view: CustomerVideoView): void {
    if (view.probe || view.disposed) { return; }
    this.videos.set(view.id, view);
    this.bindVideo(view);
  }
  removeVideo(view: CustomerVideoView): void {
    if (!this.videos.has(view.id)) { return; }
    this.videos.delete(view.id);
    this.bindRole(view.role);
  }
  handoff(role: string, _renderId: string): void { this.bindRole(role); }
  private unbindRemote(uid: number): void {
    if (uid === 0) { return; }
    const canvas = new VideoCanvas(''); canvas.uid = uid;
    try { this.engine?.setupRemoteVideo(canvas); } catch (_) {}
  }
  private bindVideos(): Error | undefined {
    const localError = this.bindRole('local');
    const remoteError = this.bindRole('remote');
    return localError ?? remoteError;
  }
  private bindVideo(view: CustomerVideoView): void { this.bindRole(view.role); }
  private bindRole(role: string): Error | undefined {
    const engine = this.engine, id = this.session;
    if (!engine || !id || (role === 'remote' && this.remoteUid === 0)) { return undefined; }
    let renderId = this.host.renderId(role, id);
    if (!renderId) {
      this.videos.forEach((view) => {
        if (view.role === role && view.ready && !view.disposed && !view.probe) { renderId = view.renderId; }
      });
    }
    const canvas = new VideoCanvas(renderId);
    canvas.uid = role === 'local' ? 0 : this.remoteUid;
    canvas.renderMode = VideoCanvas.RENDER_MODE_HIDDEN;
    try {
      this.check(role === 'local' ? engine.setupLocalVideo(canvas) : engine.setupRemoteVideo(canvas));
      if (renderId) { this.rtcEvent(id, this.generation, 'videoBound', new Map<string, Object>([['role', role]])); }
    } catch (error) {
      const code = error instanceof RtcOperationError ? error.sdkCode : undefined;
      this.rtcEvent(id, this.generation, 'videoBindingError', new Map<string, Object>([['role', role],
        ['details', this.errorDetails('rebindVideo', 'retryOperation', code)]]));
      return error instanceof RtcOperationError ? error : new Error('canvas_binding_failed');
    }
    return undefined;
  }
}
