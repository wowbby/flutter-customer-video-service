const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.CUSTOMER_RTC_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/arktsdoc/node_modules/typescript');

function load(name, dependencies = {}) {
  const file = path.resolve(__dirname, `../src/main/ets/components/plugin/${name}.ets`);
  const js = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const mod = { exports: {} };
  new Function('exports', 'module', 'require', js)(mod.exports, mod, key => {
    assert.ok(key in dependencies, `unexpected runtime dependency ${key}`);
    return dependencies[key];
  });
  return mod.exports;
}

// Replace only platform/SDK boundaries. The actual plugin owns lifecycle and result serialization.
let destroy = async () => {};
let create;
let requestPermissions = async () => ({ authResults: [0, 0] });
let testTime;
const hostTypes = load('HostPresentation', {
  '@kit.BasicServicesKit': { systemDateTime: { TimeType: { STARTUP: 0 }, getUptime: () => testTime ?? performance.now() } }
});
const phoneStates = {CALL_STATE_UNKNOWN:-1, CALL_STATE_IDLE:0, CALL_STATE_RINGING:1,
  CALL_STATE_OFFHOOK:2, CALL_STATE_ANSWERED:3};
let currentPhoneState = 0;
const slots = new Map();
const telephony = {
  call: {CallState:phoneStates, getCallStateSync: () => currentPhoneState},
  sim: {getMaxSimCount: () => 2},
  observer: {
    on: (_event, options, callback) => { slots.set(options.slotId, callback); },
    off: (_event, callback) => { for (const [slot, cb] of slots) if (cb === callback) slots.delete(slot); }
  }
};
let routeDevice = 2;
const audio = {DeviceFlag:{OUTPUT_DEVICES_FLAG:1}, StreamUsage:{STREAM_USAGE_VOICE_COMMUNICATION:1}, DeviceType:{SPEAKER:1, EARPIECE:2, BLUETOOTH_SCO:3},
  getAudioManager: () => ({getRoutingManager: () => ({getDevicesSync: () => [{deviceType:routeDevice}]}), getStreamManager: () => ({getCurrentAudioRendererInfoArraySync: () => [
    {rendererInfo:{usage:1}, deviceDescriptors:[{deviceType:routeDevice}]}
  ]})})};
const native = {
  RtcEngine: { destroy: () => destroy(), create: config => create(config) },
  ChannelMediaOptions: class {}, LogConfig: class {}, RtcEngineConfig: class {},
  CameraCapturerConfiguration: class {}, CaptureFormat: class {}, VideoEncoderConfiguration: class {},
  VideoDimensions: class { constructor(width, height) { this.width = width; this.height = height; } },
  VideoCanvas: class { constructor(id) { this.id = id; } },
  Constants: { LocalAudioStreamReason: {INTERRUPTED:8, DEVICE_BUSY:3}, VideoSourceType: { CAMERA_PRIMARY: 0 }, CameraDirection: { REAR: 0, FRONT: 1 }, LogLevel: { NONE: 0 }, ChannelProfile: { COMMUNICATION: 0 } }
};
const { default: Plugin } = load('CustomerRtcPlugin', {
  '@ohos/flutter_ohos': { FlutterManager: { getInstance: () => ({getWindowStage: () => undefined}) } }, '@kit.AbilityKit': { abilityAccessCtrl: { createAtManager: () => ({requestPermissionsFromUser: requestPermissions}) } },
  './SystemCallMonitor': load('SystemCallMonitor', {'@kit.TelephonyKit':telephony}),
  './HostPresentation': hostTypes, '@kit.AudioKit': {audio}, '@shengwang/rtc-full': native,
  './CustomerViews': {}, '../../../../../BuildProfile': { DEBUG: false },
  './CallWindowBars': load('CallWindowBars', { '@kit.ArkUI': {} }),
  './CleanupPolicy': load('CleanupPolicy')
});
function invoke(plugin, method, args) {
  return new Promise((resolve, reject) => plugin.onMethodCall({ method, argument: key => args[key] }, {
    success: value => resolve(value),
    error: (code, message, details) => reject({ code, message, details }),
    notImplemented: () => reject(new Error('unexpected missing implementation'))
  }));
}
function engine(overrides = {}) {
  return { stopPreview: () => 0, enableLocalVideo: () => 0, enableLocalAudio: () => 0,
    setupLocalVideo: () => 0, setupRemoteVideo: () => 0, leaveChannel: () => 0,
    muteLocalAudioStream: () => 0, ...overrides };
}
const mockAbility = {getAbility: () => ({context: {getApplicationContext: () => ({
  on: () => {}, off: () => {}
})}})};
function active(id, rtc = engine()) {
  const plugin = new Plugin(); plugin.session = id; plugin.engine = rtc;
  return plugin;
}
function safeError(error, code, operation, recovery, sdkCode) {
  assert.equal(error.code, code);
  assert.deepEqual(Object.fromEntries(error.details), {
    operation, recovery, ...(sdkCode === undefined ? {} : { sdkCode })
  });
  assert.equal(JSON.stringify([error.message, ...error.details]).includes('private'), false);
  return true;
}
// A dangling promise alone does not keep Node alive. Fail if a plugin method never replies.
const deadline = setTimeout(() => { console.error('RTC plugin test timed out'); process.exit(1); }, 10000);
(async () => {
  const {CallWindowBars} = load('CallWindowBars', {'@kit.ArkUI': {}});
  const barCalls = [], original = {statusBarColor: '#ff663322', statusBarContentColor: '#ff010203'};
  const hostWindow = {getWindowProperties: () => ({isLayoutFullScreen: false}), getWindowSystemBarProperties: () => original,
    setWindowSystemBarProperties: async properties => { barCalls.push(properties); },
    setWindowLayoutFullScreen: async full => { barCalls.push(full); }};
  const bars = new CallWindowBars();
  await bars.show(hostWindow);
  assert.equal(barCalls[0], true);
  assert.equal(barCalls[1].statusBarColor, '#00000000');
  await bars.show(hostWindow);
  assert.equal(barCalls.length, 2);
  await bars.show();
  assert.deepEqual(barCalls.slice(2), [original, false]);
  await Promise.all([bars.show(hostWindow), bars.show()]);
  assert.equal(barCalls.length, 4, 'stale full cannot overwrite restored bars');
  let remainingFailures = 2;
  const flaky = {...hostWindow, setWindowSystemBarProperties: async properties => {
    if (remainingFailures > 0) { remainingFailures--; throw new Error('transient'); }
    barCalls.push(properties);
  }};
  await bars.show(flaky);
  await bars.show(flaky);
  assert.equal(barCalls.at(-1).statusBarColor, '#00000000');
  remainingFailures = 2;
  await bars.show();
  await bars.show();
  assert.deepEqual(barCalls.slice(-2), [false, original], 'layout restores while color restoration retries');
  let windowDestroyed = false;
  const departing = {...hostWindow,
    getWindowProperties: () => { if (windowDestroyed) throw Error('destroyed'); return {isLayoutFullScreen: true}; },
    setWindowSystemBarProperties: async p => { if (windowDestroyed) throw Error('destroyed'); barCalls.push(p); }};
  await bars.show(departing);
  windowDestroyed = true;
  await bars.show(hostWindow);
  assert.equal(barCalls.at(-1).statusBarColor, '#00000000');
  assert.equal(barCalls.at(-2), true, 'the new Ability acquires its own window');
  await bars.show();

  const subCalls = [];
  const subWindow = {getWindowProperties: () => ({isLayoutFullScreen: false}),
    setWindowLayoutFullScreen: async flag => subCalls.push(flag)};
  barCalls.length = 0;
  await bars.show(hostWindow);
  await bars.show(hostWindow, subWindow);
  assert.deepEqual(subCalls, [true]);
  assert.equal(barCalls.length, 3);
  assert.equal(barCalls[0], true);
  assert.equal(barCalls[2], false);
  assert.equal(barCalls[1].statusBarColor, '#00000000');
  await bars.show();
  assert.deepEqual(subCalls, [true, false]);
  assert.equal(barCalls.at(-1), original);
  await bars.show(hostWindow, subWindow);
  await bars.show(hostWindow);
  assert.deepEqual(subCalls, [true, false, true, false]);
  assert.equal(barCalls.at(-1), true);
  await bars.show();

  const flutterOnly = new Plugin();
  const modes = [];
  const unsubscribe = flutterOnly.host.observeFullscreen(full => modes.push(full));
  await invoke(flutterOnly, 'setFlutterCallFullscreen', {fullscreen: true});
  await invoke(flutterOnly, 'setFlutterCallFullscreen', {fullscreen: false});
  unsubscribe();
  assert.deepEqual(modes, [false, true, false]);
  let confirm;
  let destroys = 0;
  destroy = () => { destroys++; return new Promise(resolve => { confirm = resolve; }); };
  const plugin = active('first', engine({ stopPreview: () => -9, leaveChannel: () => { throw new Error('private token'); } }));
  const first = invoke(plugin, 'leave', { sessionId: 'first' });
  const repeated = invoke(plugin, 'leave', { sessionId: 'first' });
  assert.equal(destroys, 1, 'concurrent leave destroys once');
  await assert.rejects(invoke(plugin, 'join', {}), error => error.code === 'busy');
  let settled = false; first.then(() => { settled = true; });
  await Promise.resolve(); assert.equal(settled, false, 'no confirmation before destruction');
  confirm();
  for (const result of await Promise.all([first, repeated])) {
    assert.equal(result.get('releaseStatus'), 'releasedWithWarnings');
  }
  assert.equal((await invoke(plugin, 'leave', { sessionId: 'first' })).get('releaseStatus'), 'releasedWithWarnings');
  plugin.session = 'next'; plugin.engine = engine();
  await invoke(plugin, 'leave', { sessionId: 'first' });
  assert.equal(plugin.session, 'next', 'stale repeat cannot close newer call');
  assert.equal(destroys, 1);

  destroy = async () => { throw new Error('private destruction details'); };
  const blocked = active('blocked');
  for (let i = 0; i < 2; i++) {
    await assert.rejects(invoke(blocked, 'leave', { sessionId: 'blocked' }),
      error => safeError(error, 'cleanup_failed', 'leave', 'restartRequired'));
  }
  await assert.rejects(invoke(blocked, 'join', {}), error => error.code === 'busy');

  const controls = active('controls', engine({ muteLocalAudioStream: () => -17 }));
  await assert.rejects(invoke(controls, 'setMuted', { sessionId: 'controls', muted: true }),
    error => safeError(error, 'sdkError', 'setMuted', 'retryOperation', -17));
  controls.engine.muteLocalAudioStream = () => { throw new Error('private raw SDK message'); };
  await assert.rejects(invoke(controls, 'setMuted', { sessionId: 'controls', muted: true }),
    error => safeError(error, 'rtc_operation_failed', 'setMuted', 'retryOperation'));
  const event = new Promise(resolve => { controls.sink = { success: resolve }; });
  controls.handlers('controls', controls.generation).onError(109);
  const payload = await event;
  assert.equal(payload.get('code'), 'sdkError');
  assert.deepEqual(Object.fromEntries(payload.get('details')), { sdkCode: 109, operation: 'event', recovery: 'retryCall' });
  assert.equal(payload.get('sessionId'), 'controls');

  // Exercise the real permission, join, subscription, render and teardown paths.
  const mixed = new Plugin(), subscriptions = [], canvases = [], events = [];
  let options, direction, dimensions, handlers, destroyed = 0;
  const captures = [];
  destroy = async () => { destroyed++; };
  const videoEngine = engine({
    enableVideo: () => 0, startPreview: () => 0, setDefaultAudioRoutetoSpeakerphone: () => 0,
    setVideoEncoderConfiguration: config => { dimensions = config.dimensions; assert.equal(config.frameRate, 15); return 0; },
    setCameraCapturerConfiguration: config => { direction = config.cameraDirection; captures.push(config.cameraFormat); return 0; },
    switchCamera: () => { direction = direction === 0 ? 1 : 0; return 0; },
    joinChannelWithOptions: (_token, _channel, _uid, value) => { options = value; return 0; },
    muteRemoteAudioStream: (uid, mute) => { subscriptions.push(['audio', uid, mute]); return 0; },
    muteRemoteVideoStream: (uid, mute) => { subscriptions.push(['video', uid, mute]); return 0; },
    setupRemoteVideo: canvas => { canvases.push(canvas.id); return 0; }
  });
  create = config => { handlers = config.mEventHandler; return videoEngine; };
  mixed.host.connect(mixed);
  mixed.onListen(null, { success: value => events.push(Object.fromEntries(value)) });
  mixed.onAttachedToAbility(mockAbility);
  const host = mixed.host;
  await invoke(mixed, 'updatePresentation', {sessionId: 'waiting', mode: 'mini', probe: true});
  host.background(); assert.equal(events.at(-1).type, 'hostBackground'); assert.equal(events.at(-1).sessionId, 'waiting');
  host.foreground();
  await invoke(mixed, 'updatePresentation', {sessionId: 'live', mode: 'full'});
  await invoke(mixed, 'join', {sessionId: 'live', appId: '0'.repeat(32), channel: 'test', token: 'test',
    uid: 12, expectedPeerUid: 21, cameraFacing: 'rear', videoQuality: 'sd'});
  assert.equal(direction, native.Constants.CameraDirection.REAR);
  assert.deepEqual([dimensions.width, dimensions.height], [640, 360]);
  assert.deepEqual([captures[0].width, captures[0].height, captures[0].fps], [1280, 720, 15]);
  assert.equal(options.autoSubscribeAudio, false); assert.equal(options.autoSubscribeVideo, false);
  handlers.onUserJoined(99); handlers.onUserJoined(21); handlers.onUserJoined(44);
  assert.deepEqual(subscriptions, [['audio', 21, false], ['video', 21, false]]);
  handlers.onNetworkQuality(99, 3, 3); handlers.onNetworkQuality(21, 4, 3); handlers.onNetworkQuality(0, 2, 2);
  await new Promise(resolve => setTimeout(resolve, 1));
  assert.deepEqual(events.filter(e => e.type === 'networkQuality').map(e => e.uid), [21, 0]);
  handlers.onLocalAudioStateChanged(1, 0); handlers.onLocalVideoStateChanged(0, 2, 0);
  handlers.onLocalVideoStateChanged(1, 1, 0); handlers.onRemoteVideoStateChanged(21, 2, 0);
  handlers.onRemoteVideoStateChanged(99, 1, 0);
  await new Promise(resolve => setTimeout(resolve, 1));
  assert.deepEqual(events.filter(e => e.type === 'mediaTrackState').map(e => [e.track, e.state, e.uid]),
    [['localAudio', 1, undefined], ['localVideo', 2, undefined], ['remoteVideo', 2, 21]]);
  mixed.videoReady({role: 'remote', ready: true, probe: false, disposed: false, id: 2, renderId: 'flutter'});
  assert.equal(canvases.at(-1), 'flutter');
  let rendered;
  const presenters = [];
  const stopPresenters = host.observeFullscreen((full, w) => presenters.push(w));
  const ticket = host.attach(snapshot => { rendered = snapshot; }, subWindow);
  assert.equal(presenters.at(-1), subWindow);
  await invoke(mixed, 'updatePresentation', {sessionId: 'live', mode: 'full', canControl: true, muted: true,
    cameraEnabled: false, speaker: false, quality: 'hd', bindingFailed: true});
  assert.deepEqual([rendered.canControl, rendered.muted, rendered.cameraEnabled, rendered.speaker, rendered.quality, rendered.bindingFailed],
    [true, true, false, false, 'hd', true]);
  for (const action of ['toggleMuted', 'toggleCamera', 'switchCamera', 'toggleSpeaker', 'toggleQuality', 'setQualitySd', 'setQualityHd', 'swapVideo', 'rebindVideo']) {
    host.action(ticket, 'live', action);
    assert.deepEqual(events.at(-1), {type: 'presentationAction', sessionId: 'live', action});
  }
  for (const [audioRoute, speaker] of [['earpiece', false], ['speaker', true], ['wired', false],
    ['bluetooth', false], ['other', true], ['other', false]]) {
    await invoke(mixed, 'updatePresentation', {sessionId: 'live', mode: 'full', audioRoute, speaker});
    assert.equal(rendered.speaker, speaker, 'keep the shared effective speaker selection');
    assert.equal(rendered.audioRoute, audioRoute, 'keep the observed route label');
  }
  for (const showsCallSurface of [false, true]) {
    await invoke(mixed, 'updatePresentation', {sessionId: 'live', mode: 'full', showsCallSurface,
      errorCode: 'tokenRefreshFailed', needsToken: true, canRefreshToken: true});
    assert.ok(rendered.needsToken && rendered.canRefreshToken);
    host.action(ticket, 'live', 'refreshToken');
    assert.equal(events.at(-1).action, 'refreshToken');
  }
  assert.deepEqual([0, 3599999, 3600000, 3661000].map(hostTypes.formatCallDuration),
    ['00:00','59:59','01:00:00','01:01:01']);
  const update = (change) => invoke(mixed, 'updatePresentation', {sessionId: 'live', mode: 'full', ...change});
  await update({localAvatarPath: '/data/storage/el2/base/files/portrait.png'});
  assert.equal(rendered.localAvatarPath, '/data/storage/el2/base/files/portrait.png');
  await update({localAvatarPath: 'https://example.invalid/avatar'});
  assert.equal(rendered.localAvatarPath, '');
  testTime = 10000;
  await update({localWeak:true});
  assert.equal(rendered.weakNotice, '当前你的网络不佳');
  assert.equal(host.weakNoticeRemainingMs, 3000);
  testTime += 1200;
  await update({localWeak:true, mode:'mini'});
  assert.equal(host.weakNoticeRemainingMs, 1800, 'changing window size must not replay the same toast');
  testTime += 1801;
  await update({localWeak:true});
  assert.equal(host.weakNoticeRemainingMs, 0);
  await update({localWeak:true,remoteWeak:true});
  assert.equal(rendered.weakNotice, '当前双方网络不佳');
  assert.equal(host.weakNoticeRemainingMs, 3000);
  await update({remoteWeak:true});
  assert.equal(rendered.weakNotice, '当前对方网络不佳');
  assert.equal(host.weakNoticeRemainingMs, 0, 'partial recovery closes the obsolete both-sides toast');
  await update({localWeak:true});
  assert.equal(host.weakNoticeRemainingMs, 3000, 'a newly weak side starts its own toast');
  await update({});
  assert.equal(host.weakNoticeRemainingMs, 0, 'recovery clears the toast immediately');
  await update({remoteWeak:true});
  await update({remoteWeak:true,phase:'ending'});
  assert.equal(host.weakNoticeRemainingMs, 0, 'ending clears the toast');
  const detachedHost = new hostTypes.CustomerRtcHost();
  const weak = new hostTypes.HostSnapshot({argument: key => ({sessionId:'new',localWeak:true})[key]});
  detachedHost.update(weak);
  detachedHost.attach(() => {});
  assert.equal(detachedHost.weakNoticeRemainingMs, 0, 'native does not replay weakness reported on a Flutter page');
  testTime = undefined;
  const actionsBefore = events.length;
  host.action(ticket, 'expired', 'hangup');
  assert.equal(events.length, actionsBefore, 'old session cannot issue control through a current native view');
  host.surface(ticket, 'live', 'remote', 'native', true);
  assert.equal(canvases.at(-1), 'native');

  host.surface(ticket, 'live', 'local', 'local-native', true);
  for (const primaryVideo of ['local', 'remote', 'local']) {
    await invoke(mixed, 'updatePresentation', {sessionId: 'live', mode: 'full', primaryVideo, canSwapVideo: true});
    assert.equal(rendered.primaryVideo, primaryVideo);
    assert.equal(rendered.canSwapVideo, true);
    assert.equal(host.renderId('remote', 'live'), 'native');
    assert.equal(host.renderId('local', 'live'), 'local-native');
  }
  // Native pages may mount later than the Dart callback and return from
  // background after several ticks. The host's business clock owns all labels.
  testTime = 10000;
  await update({miniElapsedMs: 41000,connectedDurationMs:null,mode:'mini'});
  assert.equal(rendered.durationLabel(testTime + 1000),'00:42');
  testTime += 1300;
  await update({miniElapsedMs: 42300,connectedDurationMs:3599500,mode:'mini'});
  assert.equal(rendered.nextTickMs(testTime),500, 'schedule display on the shared next-second boundary');
  assert.equal(rendered.nextTickMs(testTime + 499),1);
  assert.equal(rendered.durationLabel(testTime + 500),'01:00:00');
  testTime += 500;
  await update({miniElapsedMs: 42800,connectedDurationMs:3600000,mode:'full'});
  assert.equal(rendered.durationLabel(testTime + 1150),'01:00:01');
  const sampled = rendered;
  testTime += 62000;
  host.foreground();
  assert.equal(rendered,sampled, 'resume reuses the original monotonic anchor');
  assert.equal(rendered.durationLabel(testTime),'01:01:02');
  await update({phase:'ending',connectedDurationMs:3662400,miniElapsedMs:999});
  assert.equal(rendered.durationLabel(testTime + 10000),'01:01:02', 'ending freezes the final business duration');
  testTime = undefined;
  const waitingMini = {sessionId: 'live', mode: 'mini', phase: 'waiting', awaitingAnswer: true};
  await invoke(mixed, 'updatePresentation', waitingMini);
  assert.equal(rendered.compactCard, true);
  host.action(ticket, 'live', 'restore');
  assert.equal(events.at(-1).action, 'restore');
  const canvasCount = canvases.length;
  for (const change of [{mode: 'full'}, {awaitingAnswer: false}, {probe: true}, {errorCode: 'sdkError'}, {bindingFailed: true}, {restartRequired: true},
    {phase: 'ending'}, {phase: 'reconnecting'}]) {
    await invoke(mixed, 'updatePresentation', {...waitingMini, ...change});
    assert.equal(rendered.compactCard, false, JSON.stringify(change));
  }
  const accepted = {...waitingMini, phase: 'connected', awaitingAnswer: false,
    answeredMiniCard: true, connectedDurationMs: 0, showsCallSurface: true};
  for (const primaryVideo of ['local', 'remote']) {
    for (const remoteVideo of [false, true, false]) {
      await invoke(mixed, 'updatePresentation', {...accepted, primaryVideo, remoteVideo});
      assert.equal(rendered.timedCard, true, 'zero duration is a valid acceptance sample');
      assert.equal(rendered.cardShowsVideo, remoteVideo);
    }
  }
  for (const change of [{answeredMiniCard: false}, {connectedDurationMs: null}, {mode: 'full'}, {probe: true}]) {
    await invoke(mixed, 'updatePresentation', {...accepted, ...change});
    assert.equal(rendered.compactCard, false, JSON.stringify(change));
  }
  // The media-only elapsed sample comes from a real peer and does not set business acceptance.
  const peer = {...waitingMini, awaitingAnswer: false, miniElapsedMs: 8000, connectedDurationMs: null};
  for (const notice of [{localWeak: true}, {remoteWeak: true}, {errorCode: 'sdkError'}, {bindingFailed: true},
    {restartRequired: true}, {phase: 'ending'}, {phase: 'reconnecting'}]) {
    await invoke(mixed, 'updatePresentation', {...peer, ...notice, remoteVideo: true});
    assert.equal(rendered.timedCard, true);
    assert.equal(rendered.compactCard, true, 'an established mini remains compact until the session ends');
    assert.equal(rendered.miniElapsedMs, 8000);
    assert.equal(rendered.connectedDurationMs, -1);
    assert.equal(rendered.cardShowsVideo, true, 'full-screen notices never cover remote frames in mini mode');
  }
  await invoke(mixed, 'updatePresentation', {...peer, phase: 'reconnecting', remoteVideo: true, miniRemoteVideo: false});
  assert.equal(rendered.timedCard, true);
  assert.equal(rendered.cardShowsVideo, false, 'a stale last remote frame must not replace the portrait');
  await invoke(mixed, 'updatePresentation', {...peer, remoteVideo: true, miniRemoteVideo: true});
  assert.equal(rendered.cardShowsVideo, true, 'a newly available remote picture restores video');
  for (const probe of [false, true]) {
    const preview = {...waitingMini, awaitingAnswer: false, previewMiniCard: true, probe, remoteVideo: true};
    await invoke(mixed, 'updatePresentation', preview);
    assert.equal(rendered.compactCard, true);
    assert.equal(rendered.timedCard, false, 'no time before a real peer or business acceptance');
    assert.equal(rendered.cardShowsVideo, false);
    await invoke(mixed, 'updatePresentation', {...preview, bindingFailed: true});
    assert.equal(rendered.compactCard, false);
  }
  await invoke(mixed, 'updatePresentation', {...waitingMini, mode: 'full', awaitingAnswer: false});
  assert.equal(canvases.length, canvasCount, 'presentation changes keep the live native video canvas');
  mixed.onDetachedFromAbility();
  assert.equal(destroyed, 0); assert.equal(mixed.session, 'live');
  assert.equal(host.back(), true); assert.equal(events.at(-1).action, 'minimize');
  const next = host.attach(() => {});
  host.surface(next, 'live', 'remote', 'native2', true);
  host.detach(ticket); host.surface(ticket, 'live', 'remote', 'native', false);
  assert.equal(canvases.at(-1), 'native2', 'stale destroy must not unbind replacement');
  host.detach(next); assert.equal(canvases.at(-1), 'flutter');
  assert.equal(presenters.at(-1), undefined); stopPresenters();
  videoEngine.setupRemoteVideo = () => -17;
  await assert.rejects(invoke(mixed, 'rebindVideo', {sessionId: 'live'}),
    error => safeError(error, 'sdkError', 'rebindVideo', 'retryOperation', -17));
  await new Promise(resolve => setTimeout(resolve, 1));
  const failure = events.find(e => e.type === 'videoBindingError'); assert.equal(failure.role, 'remote');
  assert.equal(failure.details.get('sdkCode'), -17); assert.equal(mixed.session, 'live');
  videoEngine.setupRemoteVideo = () => 0;
  await invoke(mixed, 'rebindVideo', {sessionId: 'live'});
  await invoke(mixed, 'switchCamera', {sessionId: 'live'});
  await invoke(mixed, 'setVideoQuality', {sessionId: 'live', quality: 'hd'});
  assert.deepEqual([dimensions.width, dimensions.height, captures.length, direction], [1280, 720, 1, 1]);
  const setEncoder = videoEngine.setVideoEncoderConfiguration;
  videoEngine.setVideoEncoderConfiguration = () => -9;
  await assert.rejects(invoke(mixed, 'setVideoQuality', {sessionId: 'live', quality: 'sd'}),
    error => safeError(error, 'sdkError', 'setVideoQuality', 'retryOperation', -9));
  assert.deepEqual([dimensions.width, dimensions.height, captures.length, direction], [1280, 720, 1, 1]);
  videoEngine.setVideoEncoderConfiguration = setEncoder;
  await invoke(mixed, 'setVideoQuality', {sessionId: 'live', quality: 'sd'});
  assert.deepEqual([dimensions.width, dimensions.height], [640, 360]);
  handlers.onUserOffline(99);
  assert.equal(subscriptions.length, 2, 'a foreign UID cannot change subscription state');
  handlers.onUserOffline(21);
  assert.deepEqual(subscriptions.slice(2), [['audio', 21, true], ['video', 21, true]]);
  handlers.onUserJoined(99);
  assert.equal(mixed.remoteUid, 0);
  mixed.onDetachedFromEngine({}); await new Promise(resolve => setTimeout(resolve, 1)); assert.equal(destroyed, 1);

  let finishPermission, creates = 0;
  requestPermissions = () => new Promise(resolve => { finishPermission = resolve; });
  create = () => { creates++; return videoEngine; };
  const waiting = new Plugin(); waiting.onAttachedToAbility(mockAbility);
  const pendingJoin = invoke(waiting, 'join', {sessionId: 'pending', appId: '0'.repeat(32), channel: 'test', token: 'test', uid: 2});
  waiting.onDetachedFromAbility(); await assert.rejects(pendingJoin, error => error.code === 'cancelled');
  finishPermission({authResults: [0, 0]}); await Promise.resolve();
  assert.equal(creates, 0, 'a permission reply from a detached ability must not create a new engine');

  // A background transition may precede EventChannel.onListen. A quick
  // foreground transition must not resurrect that same pending session.
  const safety = new Plugin(), backgroundEvents = [];
  safety.onAttachedToAbility(mockAbility);
  safety.host.connect(safety);
  const safetyArgs = {sessionId:'early', appId:'0'.repeat(32), channel:'test', token:'t', uid:3};
  await invoke(safety, 'updatePresentation', {sessionId:'early',phase:'joining'});
  safety.host.background();
  const receiver = {success: event => { if (event.get('type') === 'hostBackground') backgroundEvents.push(event.get('sessionId')); }};
  safety.onListen(null, receiver);
  assert.deepEqual(backgroundEvents, ['early'], 'onListen must replay the background transition');
  safety.host.background();
  await invoke(safety, 'updatePresentation', {sessionId:'early',phase:'joining'});
  safety.onCancel(null); safety.onListen(null, receiver);
  assert.deepEqual(backgroundEvents, ['early'], 'deliver once across listener startup, duplicate background and presentation refresh');
  let requests = 0;
  requestPermissions = () => { requests++; return new Promise(resolve => { finishPermission = resolve; }); };
  await assert.rejects(invoke(safety, 'join', safetyArgs), e => e.code === 'host_background');
  assert.equal(requests, 0);
  await invoke(safety, 'updatePresentation', {sessionId:'late',phase:'joining'});
  assert.deepEqual(backgroundEvents, ['early','late'], 'new sessions while backgrounded receive their own event');
  safety.host.foreground();
  await assert.rejects(invoke(safety, 'join', {...safetyArgs,sessionId:'late'}), e => e.code === 'host_background');
  assert.equal(requests, 0, 'foreground must not revive an interrupted session');

  await invoke(safety, 'updatePresentation', {sessionId:'permission',phase:'joining'});
  const latePermission = invoke(safety, 'join', {...safetyArgs,sessionId:'permission'});
  assert.equal(requests, 1);
  safety.onCancel(null);
  safety.host.background(); safety.host.foreground();
  finishPermission({authResults: [0,0]});
  await assert.rejects(latePermission, e => e.code === 'host_background');
  safety.onListen(null, receiver);
  assert.deepEqual(backgroundEvents, ['early','late','permission']);
  assert.equal(creates, 0, 'permission success after background cannot create RTC even if app already returned');
  safety.onCancel(null);
  await invoke(safety, 'updatePresentation', {sessionId:'queuedA',phase:'joining'});
  safety.host.background();
  await invoke(safety, 'updatePresentation', {sessionId:'queuedB',phase:'joining'});
  safety.host.foreground();
  safety.onListen(null, receiver);
  assert.deepEqual(backgroundEvents.slice(-2), ['queuedA','queuedB']);
  await assert.rejects(invoke(safety, 'join', {...safetyArgs,sessionId:'queuedA'}), e => e.code === 'host_background');

  // Permission was requested before Dart had published a presentation. The
  // native join still has to see the complete background/foreground cycle.
  await invoke(safety, 'updatePresentation', {sessionId:null});
  const unpublished = invoke(safety, 'join', {...safetyArgs,sessionId:'unpublished'});
  safety.host.background(); safety.host.foreground(); finishPermission({authResults:[0,0]});
  await assert.rejects(unpublished, e => e.code === 'host_background');
  assert.equal(creates, 0);
  assert.equal(backgroundEvents.at(-1), 'unpublished');

  // No EventChannel listener or presentation snapshot is required to stop
  // physical capture on app background. Leave must await the same native destroy.
  requestPermissions = async () => ({authResults:[0,0]});
  const activeId = 'live-without-dart';
  await invoke(safety, 'join', {...safetyArgs,sessionId:activeId});
  safety.onCancel(null);
  let completeDestroy;
  destroy = () => new Promise(resolve => { completeDestroy = resolve; });
  safety.host.background();
  assert.equal(safety.session, activeId);
  await new Promise(resolve => setTimeout(resolve, 450));
  assert.equal(safety.session, null);
  assert.equal(typeof completeDestroy, 'function', 'ordinary background must destroy even without a Dart listener');
  await assert.rejects(invoke(safety, 'join', {...safetyArgs,sessionId:activeId}), e => e.code === 'host_background');
  const release = invoke(safety, 'leave', {sessionId:activeId});
  completeDestroy();
  assert.equal((await release).get('releaseStatus'), 'released');
  assert.equal((await invoke(safety, 'leave', {sessionId:activeId})).get('releaseStatus'), 'released');
  safety.host.foreground(); safety.onListen(null, receiver);
  assert.equal(backgroundEvents.at(-1), activeId);
  assert.equal(creates, 1);
  creates = 0;
  destroy = async () => {};
  safety.onDetachedFromEngine({});

  // TelephonyKit and Agora are mocked here. No subscriber or phone number is needed.
  const phonePlugin = new Plugin(), phoneEvents = [];
  let flutterAppLifecycle;
  const appContext = {
    on: (event, callback) => { assert.equal(event,'applicationStateChange'); flutterAppLifecycle = callback; },
    off: (_event, callback) => { assert.equal(callback,flutterAppLifecycle); flutterAppLifecycle = undefined; }
  };
  phonePlugin.onAttachedToAbility({getAbility: () => ({context: {getApplicationContext: () => appContext}})});
  phonePlugin.host.connect(phonePlugin);
  phonePlugin.onListen(null, {success: event => phoneEvents.push(Object.fromEntries(event))});
  const gate = id => invoke(phonePlugin, 'getSystemCallState', id ? {sessionId:id} : {});
  const phoneJoin = id => invoke(phonePlugin, 'join', {...safetyArgs, sessionId:id});
  for (const [raw, expected] of [[-1,'unknown'],[0,'idle'],[1,'ringing'],[2,'active'],[3,'active']]) {
    currentPhoneState = raw;
    assert.equal(await gate(), expected);
  }
  let phonePermissions = 0, phoneCreates = 0;
  const media = [];
  const phoneEngine = {...videoEngine,
    enableLocalAudio: enabled => { media.push(['capture',enabled]); return 0; },
    muteLocalAudioStream: muted => { media.push(['mute',muted]); return 0; },
    adjustPlaybackSignalVolume: level => { media.push(['volume',level]); return 0; },
    setEnableSpeakerphone: enabled => { media.push(['speaker',enabled]); return 0; }};
  create = () => { phoneCreates++; return phoneEngine; };
  requestPermissions = () => { phonePermissions++; return new Promise(resolve => { finishPermission = resolve; }); };
  assert.equal(await gate('blocked'), 'active');
  await assert.rejects(phoneJoin('blocked'), e => e.code === 'system_call_busy');
  assert.equal(phonePermissions, 0);
  currentPhoneState = 0;
  assert.equal(await gate('cancel'), 'idle');
  assert.equal(slots.size, 2);
  const stale = slots.get(1);
  await invoke(phonePlugin,'endSystemCallObservation',{sessionId:'stale'});
  assert.equal(slots.size, 2);
  await invoke(phonePlugin,'endSystemCallObservation',{sessionId:'cancel'});
  assert.equal(slots.size, 0);
  const racing = phoneJoin('racing');
  currentPhoneState = 1;
  finishPermission({authResults:[0,0]});
  await assert.rejects(racing, e => e.code === 'system_call_busy');
  assert.equal(phoneCreates, 0);
  currentPhoneState = 0;
  requestPermissions = async () => ({authResults:[0,0]});
  const signal = (slot,state,globalState = state) => {
    currentPhoneState = globalState;
    slots.get(slot)({state});
  };
  const presentQueuedCall = async id => {
    await gate(id);
    await invoke(phonePlugin, 'updatePresentation', {sessionId:id,phase:'waiting',mode:'mini',awaitingAnswer:true});
  };
  const queuedId = 'queued-without-rtc';
  await presentQueuedCall(queuedId);
  phonePlugin.host.background(); // Phone UI covers the waiting window before its telephony event.
  await invoke(phonePlugin, 'updatePresentation', {sessionId:queuedId,phase:'waiting',queueLabel:'前方1人'});
  signal(1,1);
  signal(1,0);
  await new Promise(resolve => setTimeout(resolve, 450));
  assert.deepEqual(phoneEvents.filter(e => e.sessionId === queuedId).map(e => [e.type,e.state]),
    [['systemCallState','ringing'],['systemCallState','idle']], 'decline/missed calls preserve the pre-admission queue');
  phonePlugin.host.foreground();
  phonePlugin.host.background();
  await new Promise(resolve => setTimeout(resolve, 450));
  assert.equal(phoneEvents.filter(e => e.type === 'hostBackground' && e.sessionId === queuedId).length, 1,
    'ordinary Home after returning interrupts the waiting call');
  await invoke(phonePlugin, 'endSystemCallObservation', {sessionId:queuedId});
  phonePlugin.host.foreground();
  const answeredId = 'answered-in-queue';
  await presentQueuedCall(answeredId);
  signal(0,1); // Telephony first, background callback second.
  phonePlugin.host.background();
  signal(0,3);
  assert.deepEqual(phoneEvents.filter(e => e.sessionId === answeredId).map(e => [e.type,e.state]),
    [['systemCallState','ringing'],['systemCallState','active']], 'an answered phone call ends the queued session once');
  assert.equal(phoneCreates, 0, 'waiting never starts RTC');
  assert.equal(slots.size, 0, 'answer releases the pre-join observer');
  await invoke(phonePlugin, 'updatePresentation', {sessionId:null});
  phonePlugin.host.foreground();
  currentPhoneState = 0;
  phoneEvents.length = 0;
  await phoneJoin('live-phone');
  await invoke(phonePlugin,'updatePresentation',{sessionId:'live-phone',phase:'connected'});
  const stateEvents = () => phoneEvents.filter(e => e.type === 'systemCallState').map(e => e.state);
  stale({state:3});
  assert.equal(phonePlugin.session, 'live-phone');
  phonePlugin.host.background(); // App callback arrives before the phone observer.
  flutterAppLifecycle.onApplicationBackground();
  await invoke(phonePlugin,'updatePresentation',{sessionId:'live-phone',phase:'connected'});
  assert.equal(phonePlugin.session, 'live-phone');
  await new Promise(resolve => setTimeout(resolve, 40));
  signal(1,1);
  signal(0,0,1); // An idle SIM cannot clear the ringing SIM.
  assert.equal(phonePlugin.session, 'live-phone');
  phonePlugin.handlers('live-phone', phonePlugin.generation).onLocalAudioStateChanged(3,8);
  signal(1,0);
  await new Promise(resolve => setTimeout(resolve, 1350));
  phonePlugin.host.background();
  await invoke(phonePlugin,'updatePresentation',{sessionId:'live-phone',phase:'connected'});
  assert.equal(phonePlugin.session, 'live-phone', 'the phone owns this whole background cycle after decline');
  assert.deepEqual(media,[['mute',true],['volume',0]], 'decline while the dialer covers the app keeps mic and playback held');
  await invoke(phonePlugin,'setMuted',{sessionId:'live-phone',muted:false});
  assert.deepEqual(media.at(-1), ['mute',true], 'a delayed unmute command cannot republish audio in background');
  phonePlugin.host.foreground();
  assert.deepEqual(media.at(-1), ['mute',true], 'wait for process foreground as well as the mixed host');
  flutterAppLifecycle.onApplicationForeground();
  assert.deepEqual(stateEvents(),['ringing','idle']);
  assert.deepEqual(media, [['mute',true],['volume',0],['mute',true],['capture',true],['mute',false],['volume',100],['speaker',true]]);
  assert.equal(phoneEvents.filter(e => e.type === 'hostBackground').length, 0);
  await invoke(phonePlugin,'setMuted',{sessionId:'live-phone',muted:true});
  routeDevice = 3;
  media.length = 0;
  signal(0,1);
  signal(0,0);
  assert.deepEqual(media, [['mute',true],['volume',0],['mute',true],['volume',100]], 'decline preserves mute and external audio output');
  media.length = 0;
  signal(0,1);
  flutterAppLifecycle.onApplicationBackground(); // Flutter host without a CustomerRtcHost callback.
  signal(0,0);
  assert.deepEqual(media,[['mute',true],['volume',0]]);
  flutterAppLifecycle.onApplicationForeground();
  flutterAppLifecycle.onApplicationForeground();
  assert.deepEqual(media,[['mute',true],['volume',0],['mute',true],['volume',100]]);
  signal(0,1);
  signal(0,3);
  assert.equal(phonePlugin.session, null);
  assert.deepEqual(stateEvents().slice(-2), ['ringing','active']);
  assert.equal(slots.size, 0);
  await invoke(phonePlugin,'leave',{sessionId:'live-phone'});
  currentPhoneState = 0;
  await phoneJoin('ordinary');
  signal(1,1);
  phonePlugin.host.background();
  signal(1,0);
  phonePlugin.host.foreground();
  phonePlugin.host.background();
  await new Promise(resolve => setTimeout(resolve, 450));
  assert.equal(phonePlugin.session, null, 'the next ordinary background ends the RTC session');
  await invoke(phonePlugin,'leave',{sessionId:'ordinary'});
  phonePlugin.host.foreground();
  await phoneJoin('destroyed');
  signal(1,1);
  phonePlugin.host.background();
  phonePlugin.host.destroy();
  assert.equal(phonePlugin.session, null, 'host destruction must override a confirmed dialer background');
  await invoke(phonePlugin,'leave',{sessionId:'destroyed'});
  phonePlugin.host.foreground();
  currentPhoneState = 0;
  await phoneJoin('outgoing');
  const outgoingSlot = slots.get(1);
  phonePlugin.onCancel(null);
  signal(1,2);
  assert.equal(phonePlugin.session, null);
  phonePlugin.onListen(null, {success: event => phoneEvents.push(Object.fromEntries(event))});
  assert.deepEqual(phoneEvents.at(-1),{type:'systemCallState',sessionId:'outgoing',state:'active'});
  await invoke(phonePlugin,'leave',{sessionId:'outgoing'});
  currentPhoneState = 0;
  outgoingSlot({state:0});
  phonePlugin.onDetachedFromEngine({});
  assert.equal(flutterAppLifecycle,undefined);
  create = () => { creates++; return videoEngine; };

  // A best-effort audio unsubscribe throwing for a departed user must not
  // skip video unsubscribe or reopen that UID after a different peer is selected.
  const peerOperations = [];
  const peers = active('peers', engine({
    muteRemoteAudioStream: (uid, mute) => {
      peerOperations.push(['audio', uid, mute]);
      if (mute) throw new Error('already offline');
      return 0;
    },
    muteRemoteVideoStream: (uid, mute) => { peerOperations.push(['video', uid, mute]); return mute ? -3 : 0; }
  }));
  const peerEvents = peers.handlers('peers', peers.generation);
  peerEvents.onUserJoined(10); peerEvents.onUserOffline(10);
  peerEvents.onUserJoined(11); peerEvents.onUserJoined(10);
  assert.equal(peers.remoteUid, 11);
  assert.deepEqual(peerOperations, [['audio',10,false],['video',10,false],['audio',10,true],['video',10,true],
    ['audio',11,false],['video',11,false]]);
  await invoke(peers, 'leave', {sessionId:'peers'});
  // Video subscription fails after audio succeeds. Even failed rollback cannot
  // leave a window where another UID becomes eligible.
  const failedSubs = [], forced = active('partial', engine({
    muteRemoteAudioStream: (uid, muted) => { failedSubs.push([uid, muted]); return muted ? -4 : 0; },
    muteRemoteVideoStream: () => -3
  }));
  let partialError;
  forced.sink = { success: value => { partialError = value; } };
  const onJoined = forced.handlers('partial', forced.generation).onUserJoined;
  onJoined(9); onJoined(10);
  assert.equal(partialError.get('type'), 'error'); assert.equal(partialError.get('sessionId'), 'partial');
  assert.equal(partialError.get('details').get('sdkCode'), -3);
  assert.deepEqual(failedSubs, [[9, false], [9, true]]); assert.equal(forced.session, null);
  await new Promise(resolve => setTimeout(resolve, 1));
  assert.equal((await invoke(forced, 'leave', {sessionId:'partial'})).get('releaseStatus'), 'released');

  // A new FlutterEngine must neither create while old global destroy is pending,
  // nor recover a process whose destroy rejected.
  requestPermissions = async () => ({ authResults: [0, 0] });
  const args = {sessionId: 'old', appId: '0'.repeat(32), channel: 'test', token: 't', uid: 1};
  const owner = new Plugin(), successor = new Plugin(), afterFailure = new Plugin();
  for (const instance of [owner, successor, afterFailure]) {
    instance.onAttachedToAbility(mockAbility);
  }
  destroy = () => new Promise(resolve => { confirm = resolve; });
  await invoke(owner, 'join', args);
  owner.onDetachedFromEngine({});
  await assert.rejects(invoke(successor, 'join', {...args,sessionId:'second'}), e => e.code === 'busy');
  assert.equal(creates, 1);
  confirm(); await new Promise(resolve => setTimeout(resolve, 0));
  await invoke(successor, 'join', {...args,sessionId:'second'});
  destroy = async () => { throw new Error('destroy failed'); };
  successor.onDetachedFromEngine({}); await new Promise(resolve => setTimeout(resolve, 0));
  await assert.rejects(invoke(afterFailure, 'join', {...args,sessionId:'third'}),
    e => safeError(e, 'cleanup_failed', 'join', 'restartRequired'));
  assert.equal(creates, 2);

  console.log('PASS: cleanup, stale events, permission cancellation, selected-peer subscription, media settings, mixed-host handoff and system phone call conflicts');
})().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => clearTimeout(deadline));
