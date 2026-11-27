import { window } from '@kit.ArkUI';
import { fileUri } from '@kit.CoreFileKit';
import { Constants } from '@shengwang/rtc-full';
import { CustomerRtcHost, HostSnapshot, monotonicMs } from './HostPresentation';

@Component
struct HostVideo {
  role: string = '';
  session: string = '';
  ticket: number = 0;
  private surfaceId(): string { return `customer_host_${this.ticket}_${this.session}_${this.role}`; }
  build() {
    XComponent({ id: this.surfaceId(), type: 'surface', libraryname: Constants.AGORA_LIB_NAME })
      .width('100%').height('100%')
      .onLoad(() => CustomerRtcHost.shared.surface(this.ticket, this.session, this.role, this.surfaceId(), true))
      .onDestroy(() => CustomerRtcHost.shared.surface(this.ticket, this.session, this.role, this.surfaceId(), false))
  }
}

// Place as the last child of the host's top-level Stack above native navigation/Web.
@Component
export struct CustomerRtcOverlay {
  @State private state: HostSnapshot = new HostSnapshot();
  @State private x: number = 8;
  @State private y: number = 24;
  @State private miniDragged: boolean = false;
  @State private widthVp: number = 190;
  @State private heightVp: number = 250;
  @State private insetX: number = 0;
  @State private insetY: number = 0;
  @State private now: number = monotonicMs();
  @State private qualityMenuOpen: boolean = false;
  private clock: number = -1;
  @State private weakNotice: string = '';
  private noticeTimer?: number;
  // The exported controls are white alpha masks. Scale RGB without changing alpha.
  private darkIcon: ColorFilter = new ColorFilter([
    39 / 255, 0, 0, 0, 0,
    0, 48 / 255, 0, 0, 0,
    0, 0, 46 / 255, 0, 0,
    0, 0, 0, 1, 0
  ]);
  private whiteIcon: ColorFilter = new ColorFilter([
    1, 0, 0, 0, 0,
    0, 1, 0, 0, 0,
    0, 0, 1, 0, 0,
    0, 0, 0, 1, 0
  ]);
  @State private viewportWidth: number = 190;
  @State private viewportHeight: number = 250;
  @State private systemBottom: number = 0;
  private viewportX: number = 0;
  private viewportY: number = 0;
  private hostWindow?: window.Window;
  private onInsets = () => this.updateViewport();
  private updateViewport(): void {
    let left = 0, top = 0, right = this.viewportWidth, bottom = this.viewportHeight;
    let systemBottom = 0;
    const w = this.hostWindow;
    if (w) {
      const ui = this.getUIContext();
      const rect = w.getWindowProperties().windowRect;
      for (const type of [window.AvoidAreaType.TYPE_SYSTEM, window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR,
        window.AvoidAreaType.TYPE_CUTOUT, window.AvoidAreaType.TYPE_KEYBOARD]) {
        const area = w.getWindowAvoidArea(type);
        left = Math.max(left, ui.px2vp(area.leftRect.width) - this.viewportX);
        top = Math.max(top, ui.px2vp(area.topRect.height) - this.viewportY);
        right = Math.min(right, ui.px2vp(rect.width - area.rightRect.width) - this.viewportX);
        bottom = Math.min(bottom, ui.px2vp(rect.height - area.bottomRect.height) - this.viewportY);
        if (type !== window.AvoidAreaType.TYPE_KEYBOARD) {
          systemBottom = Math.max(systemBottom, this.viewportHeight - bottom);
        }
      }
    }
    this.systemBottom = systemBottom;
    this.insetX = left; this.insetY = top;
    this.widthVp = Math.max(0, right - left); this.heightVp = Math.max(0, bottom - top);
  }
  private originX: number = 0;
  private originY: number = 0;
  private ticket: number = 0;

  aboutToAppear(): void {
    // UIContext identifies this component's own window even if a different
    // window was opened more recently in the same Ability.
    const name = this.getUIContext().getWindowName();
    if (name) {
      try {
        this.hostWindow = window.findWindow(name);
        this.hostWindow.on('avoidAreaChange', this.onInsets);
        this.updateViewport();
      } catch (_) { /* The presenter may already be closing. */ }
    }
    this.ticket = CustomerRtcHost.shared.attach((state: HostSnapshot) => {
      if (this.state.sessionId !== state.sessionId) {
        this.miniDragged = false;
        this.x = 8; this.y = 24;
      }
      if (this.state.sessionId !== state.sessionId || !state.canControl || state.mode !== 'full' ||
          state.probe || !state.showsCallSurface || state.phase === 'ending') {
        this.qualityMenuOpen = false;
      }
      this.updateWeakNotice(state);
      this.state = state;
      this.updateClock();
    }, this.hostWindow);
  }
  aboutToDisappear(): void {
    this.qualityMenuOpen = false;
    this.stopClock();
    this.updateWeakNotice(new HostSnapshot());
    try { this.hostWindow?.off('avoidAreaChange', this.onInsets); } catch (_) {}
    this.hostWindow = undefined;
    CustomerRtcHost.shared.detach(this.ticket);
  }
  private mini(): boolean { return this.state.mode === 'mini'; }
  private label(): string {
    if (this.state.restartRequired) { return '请重启 App 后再通话'; }
    if (this.state.bindingFailed) { return '视频画面绑定失败'; }
    if (this.state.errorCode === 'tokenRefreshFailed') { return '通话授权更新失败'; }
    if (this.state.errorCode) { return '通话操作遇到问题'; }
    if (this.state.needsToken) { return '通话授权需要更新'; }
    if (this.state.probe) { return '窗口测试 · 无媒体'; }
    if (this.state.phase === 'ending') { return '正在结束通话'; }
    if (this.state.phase === 'connected') { return '视频通话'; }
    if (this.state.phase === 'reconnecting') { return '正在重连'; }
    return '等待连接';
  }
  private clamp(value: number, max: number): number { return Math.max(0, Math.min(value, max)); }
  private stopClock(): void {
    if (this.clock >= 0) { clearTimeout(this.clock); this.clock = -1; }
  }
  private updateClock(): void {
    this.stopClock();
    this.now = monotonicMs();
    if (this.state.phase === 'ending' || !this.state.sessionId || this.state.displayDurationMs < 0) { return; }
    if (this.state.mode !== 'full' && !this.state.timedCard) { return; }
    this.clock = setTimeout(() => this.updateClock(), this.state.nextTickMs(this.now));
  }
  private updateWeakNotice(state: HostSnapshot): void {
    if (this.noticeTimer !== undefined) { clearTimeout(this.noticeTimer); this.noticeTimer = undefined; }
    const remaining = CustomerRtcHost.shared.weakNoticeRemainingMs;
    this.weakNotice = remaining > 0 ? state.weakNotice : '';
    if (this.weakNotice) {
      this.noticeTimer = setTimeout(() => { this.weakNotice = ''; this.noticeTimer = undefined; }, remaining);
    }
  }
  private panelWidth(): number {
    return this.mini() ? Math.min(this.state.compactCard ? 84 : 190, this.widthVp) : (this.state.rotated ? this.heightVp : this.widthVp);
  }
  private panelHeight(): number {
    return this.mini() ? Math.min(this.state.compactCard ? 150 : 250, this.heightVp) : (this.state.rotated ? this.widthVp : this.heightVp);
  }
  // The media canvas includes the system bars. Interactive controls and the
  // floating inset use the intersection with the window's reported safe area.
  private canvasWidth(): number {
    return this.mini() ? this.panelWidth() : (this.state.rotated ? this.viewportHeight : this.viewportWidth);
  }
  private canvasHeight(): number {
    return this.mini() ? this.panelHeight() : (this.state.rotated ? this.viewportWidth : this.viewportHeight);
  }
  private safeX(): number { return this.mini() ? 0 : (this.state.rotated ? this.insetY : this.insetX); }
  private safeY(): number {
    return this.mini() ? 0 : (this.state.rotated ? this.viewportWidth - this.insetX - this.widthVp : this.insetY);
  }
  private secondaryWidth(): number {
    if (this.state.compactCard) { return this.panelWidth(); }
    if (this.mini()) { return Math.min(84, this.panelWidth() * 0.24); }
    return Math.min(84, Math.max(0, this.panelWidth() - 32), this.panelHeight() * 0.28 * 84 / 150);
  }
  private secondaryHeight(): number {
    if (this.state.compactCard) { return this.panelHeight(); }
    return this.mini() ? Math.min(150, this.panelHeight() * 0.28) : this.secondaryWidth() * 150 / 84;
  }
  private secondaryX(): number {
    return this.safeX() + Math.max(0, this.panelWidth() - this.secondaryWidth() - (this.mini() ? 10 : 16));
  }
  private secondaryY(): number {
    return this.mini() ? Math.max(0, this.panelHeight() - 44 - this.secondaryHeight()) :
      this.safeY() + Math.min(this.panelHeight() / 4, Math.max(48, 105 - this.safeY()));
  }
  private isInset(role: string): boolean {
    return !this.state.compactCard && role !== this.state.primaryVideo;
  }
  private panelX(): number {
    if (!this.mini()) { return (this.viewportWidth - this.canvasWidth()) / 2; }
    const room = this.widthVp - this.panelWidth();
    const x = this.state.compactCard && !this.miniDragged ? room - 16 : this.x;
    return this.insetX + this.clamp(x, room);
  }
  private panelY(): number {
    if (!this.mini()) { return (this.viewportHeight - this.canvasHeight()) / 2; }
    const room = this.heightVp - this.panelHeight();
    const y = this.state.compactCard && !this.miniDragged ? 105 - this.viewportY - this.insetY : this.y;
    return this.insetY + this.clamp(y, room);
  }
  private send(action: string): void {
    CustomerRtcHost.shared.action(this.ticket, this.state.sessionId, action);
  }
  private endLabel(): string {
    if (this.state.restartRequired) { return '请重启 App'; }
    if (this.state.errorCode === 'cleanupFailed') { return '重试结束'; }
    if (this.state.probe) { return '结束测试'; }
    return this.state.showsCallSurface ? '挂断' : '取消';
  }
  private speakerLabel(): string {
    if (this.state.audioRoute === 'bluetooth') { return '蓝牙耳机'; }
    if (this.state.audioRoute === 'wired') { return '有线耳机'; }
    if (this.state.audioRoute === 'earpiece') { return '听筒'; }
    return this.state.speaker ? '扬声器已开' : '扬声器已关';
  }
  private hasNotice(): boolean {
    return this.state.restartRequired || this.state.needsToken || !!this.state.errorCode || this.state.bindingFailed ||
      this.state.phase === 'reconnecting' || this.state.phase === 'ending';
  }
  private activeControl(action: string): boolean {
    if (action === 'toggleMuted') { return !this.state.muted; }
    if (action === 'toggleSpeaker') { return this.state.speaker; }
    return action === 'toggleCamera' && this.state.cameraEnabled;
  }
  private controlLabel(action: string): string {
    switch (action) {
      case 'toggleMuted': return this.state.muted ? '麦克风已关' : '麦克风已开';
      case 'toggleSpeaker': return this.speakerLabel();
      case 'toggleCamera': return this.state.cameraEnabled ? '摄像头已开' : '摄像头已关';
      case 'toggleOrientation': return this.panelWidth() > this.panelHeight() ? '切换竖屏' : '切换横屏';
      case 'switchCamera': return '翻转摄像头';
      default: return this.endLabel();
    }
  }
  private controlEnabled(action: string): boolean {
    if (action === 'toggleOrientation') { return this.state.canToggleOrientation; }
    if (action === 'hangup') {
      return !this.state.restartRequired && (this.state.phase !== 'ending' || this.state.errorCode === 'cleanupFailed');
    }
    return this.state.canControl;
  }
  @Builder
  actionButton(icon: Resource, action: string) {
    Column({ space: this.panelHeight() < 340 ? 3 : (this.state.showsCallSurface ? 8 : 10) }) {
      Stack({alignContent: Alignment.Center}) {
        Image(icon).width(this.panelHeight() < 340 ? 20 : 27.5).aspectRatio(1)
          .objectFit(ImageFit.Contain).colorFilter(this.activeControl(action) ? this.darkIcon : this.whiteIcon)
      }.width(this.panelHeight() < 340 ? 36 : (action === 'hangup' && !this.state.showsCallSurface ? 65 : 55)).height(this.panelHeight() < 340 ? 36 : (action === 'hangup' && !this.state.showsCallSurface ? 65 : 55))
        .linearGradient({ angle: 149, colors: action === 'hangup'
          ? [['#E6FF5360', 0.17], ['#FFFF3141', 0.87]] : (this.activeControl(action) ? [['#F0FFFFFF', 0], ['#F0FFFFFF', 1]] : [['#4DFFFFFF', 0], ['#4DFFFFFF', 1]]) }).borderRadius(33)
      Text(this.controlLabel(action)).fontColor(Color.White).fontSize(13).lineHeight(18).maxLines(1)
    }.constraintSize({ minWidth: 54, minHeight: 44 }).alignItems(HorizontalAlign.Center)
      .enabled(this.controlEnabled(action)).opacity(this.controlEnabled(action) ? 1 : 0.52).accessibilityText(this.controlLabel(action))
      .onClick(() => this.send(action))
  }
  @Builder
  endControl() {
    this.actionButton($r('app.media.call_end'), 'hangup')
  }
  @Builder
  avatar(diameter: number) {
    Image($r('app.media.service_avatar')).width(diameter).height(diameter)
      .scale({ x: 1.295, y: 1.295 }).objectFit(ImageFit.Contain).accessibilityText('客服头像')
  }
  @Builder
  personalAvatar(diameter: number) {
    Stack({alignContent: Alignment.Center}) {
      Circle().width(diameter).height(diameter).fill('#647974')
      Circle().width(diameter * 0.33).height(diameter * 0.33).fill('#DEEBE7')
        .position({x: diameter * 0.335, y: diameter * 0.2})
      Ellipse().width(diameter * 0.75).height(diameter * 0.68).fill('#DEEBE7')
        .position({x: diameter * 0.125, y: diameter * 0.6})
      if (this.state.localAvatarPath) {
        Image(fileUri.getUriFromPath(this.state.localAvatarPath)).width(diameter).height(diameter).objectFit(ImageFit.Cover)
      }
    }.width(diameter).height(diameter).borderRadius(diameter / 2).clip(true).accessibilityText('用户头像')
  }
  @Builder
  waiting() {
    Stack({ alignContent: Alignment.Center }) {
      Column({ space: 20 }) {
        this.avatar(Math.min(100, this.panelHeight() * 0.19))
        Text(this.state.queueLabel || '等待坐席接听，请稍等…').fontSize(13).lineHeight(18).fontColor(Color.White)
          .textAlign(TextAlign.Center).width(Math.min(187.5, this.panelWidth() * 0.86))
      }.position({ x: '50%', y: this.panelHeight() < 360 ? 48 : Math.max(54,this.viewportHeight * 250 / 812 - this.insetY) })
        .markAnchor({ x: '50%', y: 0 })
      Column() { this.endControl() }.position({ x: '50%', y: this.panelHeight() - (this.panelHeight() < 360 ? 12 : Math.max(6, 50 - (this.viewportHeight - this.insetY - this.heightVp))) })
        .markAnchor({ x: '50%', y: '100%' })
    }.width('100%').height('100%')
  }
  private headerTop(): number {
    const height = this.state.rotated ? this.viewportWidth : this.viewportHeight;
    const safeTop = this.state.rotated ? this.viewportWidth - this.widthVp - this.insetX : this.viewportY + this.insetY;
    return height < 400 ? 0 : Math.max(0, 44 - safeTop);
  }
  @Builder
  qualityItem(label: string, quality: string) {
    Button(label, { type: ButtonType.Normal })
      .width('100%').height(48).padding(0).backgroundColor(Color.White)
      .fontSize(14).fontColor(this.state.quality === quality ? '#008781' : '#22292A')
      .fontWeight(this.state.quality === quality ? 600 : 400)
      .accessibilitySelected(this.state.quality === quality)
      .onClick(() => {
        if (!this.qualityMenuOpen) { return; }
        this.qualityMenuOpen = false;
        if (this.state.canControl && this.state.quality !== quality) {
          this.send(quality === 'hd' ? 'setQualityHd' : 'setQualitySd');
        }
      })
  }
  @Builder
  qualityMenu() {
    Stack().width('100%').height('100%').backgroundColor(Color.Transparent)
      .accessibilityLevel('no').hitTestBehavior(HitTestMode.Block)
      .onClick(() => { this.qualityMenuOpen = false; })
    Column() {
      this.qualityItem('标清', 'sd')
      this.qualityItem('高清', 'hd')
    }.width(Math.min(120, this.panelWidth())).backgroundColor(Color.White)
      .borderRadius(16).clip(true).shadow({ radius: 4, offsetY: 2, color: '#33000000' })
      .position({
        x: Math.max(0, this.panelWidth() - 132),
        y: Math.min(this.headerTop() + Math.min(60, this.panelHeight() / 3), Math.max(0, this.panelHeight() - 96))
      })
  }
  @Builder
  controls() {
    Column({ space: this.panelHeight() < 340 ? 3 : 20 }) {
      Row() {
        this.actionButton($r('app.media.call_mic'), 'toggleMuted')
        this.actionButton($r('app.media.call_speaker'), 'toggleSpeaker')
        this.actionButton($r('app.media.call_camera'), 'toggleCamera')
      }.width('100%').justifyContent(FlexAlign.SpaceAround)
      Row() {
        this.actionButton($r('app.media.call_rotate'), 'toggleOrientation')
        this.endControl()
        this.actionButton($r('app.media.call_flip'), 'switchCamera')
      }.width('100%').justifyContent(FlexAlign.SpaceAround)
    }.width(Math.min(327, this.panelWidth())).padding({ top: 8, bottom: this.panelHeight() < 340 ? 4 : Math.max(6, 39 - (this.viewportHeight - this.insetY - this.heightVp)) })
  }
  @Builder
  fullChrome() {
    if (!this.state.showsCallSurface) {
      this.waiting()
    } else {
      if (this.state.probe) {
        Column() { this.endControl() }.position({x: '50%', y: this.panelHeight() - 20}).markAnchor({x: '50%', y: '100%'})
      } else {
        Column() { this.controls() }.position({ x: '50%', y: '100%' }).markAnchor({ x: '50%', y: '100%' })
      }
    }
    Row() {
      Button() {
        Image(this.state.showsCallSurface ? $r('app.media.call_minimize') : $r('app.media.call_minimize_wait')).width(24).height(24).colorFilter(this.whiteIcon)
      }.type(ButtonType.Circle).backgroundColor(Color.Transparent).width(44).height(44).accessibilityText('缩小窗口').onClick(() => this.send('minimize'))
      Blank()
      if (this.state.showsCallSurface && !this.state.probe) {
        Button() {
          Row({space: 4}) {
            Text(this.state.quality === 'hd' ? '高清' : this.state.quality === 'sd' ? '标清' : '清晰度')
              .fontSize(15).fontColor(Color.White)
            Image($r('app.media.call_quality_arrow')).width(9).height(9).colorFilter(this.whiteIcon)
          }
        }.backgroundColor(Color.Transparent).accessibilityText('选择清晰度')
          .enabled(this.state.canControl).onClick(() => { this.qualityMenuOpen = true; })
      }
    }.width('100%').position({x: 0, y: this.state.showsCallSurface && !this.state.probe ? this.headerTop() : 0})
    if (this.state.showsCallSurface) {
      Column() {
        Text(this.state.connectedDurationMs >= 0 ? this.state.durationLabel(this.now) :
          (this.state.probe ? '窗口测试 · 无媒体' : '媒体预览')).fontColor(Color.White).fontSize(17).fontWeight(FontWeight.Medium)
        if (this.state.connectedDurationMs >= 0) { Text('通话时长').fontColor(Color.White).fontSize(13) }
      }.position({ x: '50%', y: this.state.rotated ? 4 : Math.max(4, 54 - this.insetY) }).markAnchor({x: '50%', y: 0})
    }
    if (this.hasNotice()) {
      Row() {
        Text(this.label()).fontColor(Color.White).fontSize(13)
        if (this.state.canRefreshToken) {
          Button('重试通话授权').fontSize(13).onClick(() => this.send('refreshToken'))
        } else if (this.state.bindingFailed && this.state.canControl) {
          Button('恢复画面').fontSize(13).onClick(() => this.send('rebindVideo'))
        }
      }.padding(5).backgroundColor('#BA383431').borderRadius(8).position({ x: '50%', y: 49 }).markAnchor({x: '50%', y: 0})
    }
    if (this.qualityMenuOpen) { this.qualityMenu() }
  }
  private startMiniDrag(): void {
    this.originX = this.panelX() - this.insetX;
    this.originY = this.panelY() - this.insetY;
    this.x = this.originX; this.y = this.originY;
    this.miniDragged = true;
  }
  private moveMiniDrag(event: GestureEvent): void {
    this.x = this.clamp(this.originX + event.offsetX, this.widthVp - this.panelWidth());
    this.y = this.clamp(this.originY + event.offsetY, this.heightVp - this.panelHeight());
  }
  private dockMini(): void {
    const room = this.widthVp - this.panelWidth();
    const inset = this.state.compactCard ? Math.min(16, room / 2) : 0;
    this.x = this.x < room / 2 ? inset : room - inset;
  }
  private cardWidth(): number { return this.mini() ? this.panelWidth() : this.secondaryWidth(); }
  private cardHeight(): number { return this.mini() ? this.panelHeight() : this.secondaryHeight(); }
  private cardHasPicture(): boolean {
    return this.mini() ? this.state.cardShowsVideo : (this.state.primaryVideo === 'remote' || this.state.miniRemoteVideo);
  }
  // The 259px asset includes transparent padding around a 180px portrait.
  private cardAvatarScale(): number {
    return Math.min(58, this.cardWidth() * 0.7, this.cardHeight() * 0.5) / 180;
  }
  private cardCaption(): string {
    if (!this.mini()) {
      return this.state.displayDurationMs >= 0 ? this.state.durationLabel(this.now) : '';
    }
    if (this.state.timedCard) { return this.state.durationLabel(this.now); }
    if (this.state.probe) { return '无媒体测试'; }
    return '等待接听';
  }
  @Builder
  cardFace() {
    Stack({ alignContent: Alignment.Center }) {
      Stack({ alignContent: Alignment.Center }) {
        if (!this.cardHasPicture()) {
          Image($r('app.media.service_avatar')).width(180 * this.cardAvatarScale()).aspectRatio(1)
            .scale({ x: 259 / 180, y: 259 / 180 }).objectFit(ImageFit.Contain).accessibilityLevel('no')
            .position({ x: '50%', y: this.cardHeight() * 64 / 150 - 1.5 + 15.5 * this.cardAvatarScale() })
            .markAnchor({ x: '50%', y: '50%' })
        }
        if (this.mini() || this.state.miniElapsedMs >= 0 || this.state.connectedDurationMs >= 0) {
          Text(this.cardCaption()).width('100%').height(Math.min(28, this.cardHeight()))
            .fontSize(14).fontWeight(FontWeight.Medium).fontColor(Color.White).maxLines(1)
            .textAlign(TextAlign.Center)
            .backgroundColor(!this.mini() || this.state.timedCard || this.state.probe ? '#6609403D' : '#66455353')
            .position({ x: 0, y: '100%' }).markAnchor({ x: 0, y: '100%' })
        }
      }.width(Math.max(0, this.cardWidth() - 3)).height(Math.max(0, this.cardHeight() - 3))
        .borderRadius(18.5).clip(true)
        .linearGradient({ angle: 180, colors: this.cardHasPicture() ? [['#00000000', 0], ['#00000000', 1]] :
          (!this.mini() || this.state.timedCard || this.state.probe ? [['#70C2BE', 0], ['#53908D', 1]] : [['#222D2D', 0], ['#273434', 1]]) })
      if (this.cardHasPicture()) {
        Rect().width('100%').height('100%').radius(20).fill(Color.Transparent)
          .stroke('#BFFFFFFF').strokeWidth(3).hitTestBehavior(HitTestMode.None)
      }
    }.width('100%').height('100%').borderRadius(20).clip(true)
      .linearGradient({ angle: 180, colors: this.cardHasPicture() ? [['#00000000', 0], ['#00000000', 1]] :
        [['#B3FFFFFF', 0], ['#CCFFFFFF', 1]] })
  }
  @Builder
  serviceMiniCard() {
    Stack() { this.cardFace() }.width('100%').height('100%')
      .accessibilityGroup(true).accessibilityText((this.state.timedCard ? '通话时长 ' : '') + this.cardCaption() + '，恢复全屏')
      .onClick(() => this.send('restore'))
      .gesture(PanGesture().onActionStart(() => this.startMiniDrag())
        .onActionUpdate((event: GestureEvent) => this.moveMiniDrag(event)).onActionEnd(() => this.dockMini()))
  }
  @Builder
  miniChrome() {
    Column() {
      Text(this.label()).width('100%').height(32).fontColor(Color.White)
        .textAlign(TextAlign.Center).backgroundColor('#263342')
        .gesture(PanGesture().onActionStart(() => this.startMiniDrag())
          .onActionUpdate((event: GestureEvent) => this.moveMiniDrag(event)).onActionEnd(() => this.dockMini()))
      Blank().width('100%').onClick(() => this.send('restore'))
      Row({ space: 4 }) {
        Button('全屏').fontSize(14).onClick(() => this.send('restore'))
        Button(this.endLabel()).fontSize(14).enabled(!this.state.restartRequired).onClick(() => this.send('hangup'))
      }.height(42)
    }.width('100%').height('100%')
  }
  @Builder
  streamLayer(role: string, session: string) {
    Stack() {
      HostVideo({ role: role, session: session, ticket: this.ticket }).width('100%').height('100%')
      if (role === 'local' && !this.state.cameraEnabled) {
        Stack({alignContent: Alignment.Center}) {
          this.personalAvatar(this.isInset(role) ? Math.min(58, this.secondaryWidth() * 0.7) : Math.min(100, this.panelHeight() * 0.19))
        }.width('100%').height('100%').backgroundColor('#1D2626')
      }
      if (role === 'remote' && !this.state.miniRemoteVideo && !this.mini() &&
          this.state.showsCallSurface && !this.isInset(role)) {
        Stack() { this.avatar(Math.min(100, this.panelHeight() * 0.19)) }
          .width('100%').height('100%').linearGradient({ angle: 180, colors: [['#70C2BE', 0], ['#53908D', 1]] })
      }
    }.width(this.isInset(role) ? this.secondaryWidth() : this.canvasWidth())
      .height(this.isInset(role) ? this.secondaryHeight() : this.canvasHeight())
      .position({x: this.isInset(role) ? this.secondaryX() : 0, y: this.isInset(role) ? this.secondaryY() : 0})
      .opacity(this.state.compactCard && role === 'local' ? 0 : 1)
      .borderRadius(this.isInset(role) ? (this.mini() ? 12 : 20) : 0).clip(true)
      .zIndex(this.isInset(role) ? 1 : 0).hitTestBehavior(HitTestMode.None)
  }
  @Builder
  videoLayers(session: string) {
    Stack({ alignContent: Alignment.TopStart }) {
      // Each RTC role owns one XComponent for the session, independent of its frame.
      this.streamLayer('local', session)
      this.streamLayer('remote', session)
      if (!this.state.compactCard) {
        Stack() {
          if (!this.mini()) {
            this.cardFace()
          } else if (this.state.primaryVideo === 'local' && !this.state.remoteVideo) {
            Stack() {
              Column() { this.avatar(32) }.position({x: '50%', y: '42%'}).markAnchor({x: '50%', y: '50%'})
            }.width('100%').height('100%').linearGradient({angle: 180, colors: [['#70C2BE', 0], ['#53908D', 1]]})
          }
        }.width(this.secondaryWidth()).height(this.secondaryHeight()).borderRadius(this.mini() ? 12 : 20).clip(true)
          .position({x: this.secondaryX(), y: this.secondaryY()}).zIndex(2).hitTestBehavior(HitTestMode.None)
      }
    }.width('100%').height('100%').hitTestBehavior(HitTestMode.None)
  }
  @Builder
  swapTarget() {
    Button(this.state.primaryVideo === 'local' ? '切换到对方主画面' : '切换到本机主画面',
      { type: ButtonType.Normal, stateEffect: false })
      .backgroundColor(Color.Transparent).fontColor(Color.Transparent).padding(0)
      .width(this.secondaryWidth()).height(this.secondaryHeight()).borderRadius(20)
      .position({x: this.secondaryX(), y: this.secondaryY()})
      .onClick(() => this.send('swapVideo'))
  }
  // System indicators keep their physical edge when the user rotates the call UI.
  @Builder
  systemBarScrim(inset: number, x: number, y: number, angle: number, side: boolean) {
    Column().width(side ? inset + 8 : this.viewportWidth).height(side ? this.viewportHeight : inset + 8)
      .linearGradient({angle: angle,
        colors: [['#8A000000', 0], ['#8A000000', inset / (inset + 8)], ['#00000000', 1]]})
      .position({x: x, y: y}).hitTestBehavior(HitTestMode.None)
  }
  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.state.sessionId) {
        ForEach([this.state.sessionId], (session: string) => {
          Stack({ alignContent: Alignment.Center }) {
            if (!this.state.probe) { this.videoLayers(session) }
            if (this.state.compactCard) { this.serviceMiniCard() }
            else if (this.mini()) { this.miniChrome() } else {
              if (!this.state.showsCallSurface) {
                Image($r('app.media.call_wait_background')).width('100%').height('100%').objectFit(ImageFit.Cover)
              } else {
                Column().width('100%').height('100%').linearGradient({angle: 180,
                  colors: [['#B3000000', 0], ['#00000000', 0.186], ['#00000000', 0.645], ['#B3000000', 1]]})
                  .hitTestBehavior(HitTestMode.Transparent)
              }
              Stack({ alignContent: Alignment.Center }) { this.fullChrome() }
                .width(this.panelWidth()).height(this.panelHeight())
                .position({x: this.safeX(), y: this.safeY()}).hitTestBehavior(HitTestMode.Transparent)
            }
            if (!this.mini() && this.state.canSwapVideo && this.state.showsCallSurface && !this.state.probe &&
                !this.qualityMenuOpen) { this.swapTarget() }
          }.width(this.canvasWidth()).height(this.canvasHeight()).backgroundColor('#1D2626')
            .borderRadius(this.state.compactCard ? 20 : (this.mini() ? 12 : 0)).clip(true)
            .rotate({angle: !this.mini() && this.state.rotated ? 90 : 0})
            .position({ x: this.panelX(), y: this.panelY() })
        }, (session: string) => session)
        if (!this.mini()) {
          if (this.state.rotated && this.insetY > 0) {
            this.systemBarScrim(this.insetY, 0, 0, 180, false)
          }
          if (this.state.rotated && this.systemBottom > 0) {
            this.systemBarScrim(this.systemBottom, 0, this.viewportHeight - this.systemBottom - 8, 0, false)
          }
          if (this.insetX > 0) {
            this.systemBarScrim(this.insetX, 0, 0, 90, true)
          }
          if (this.viewportWidth - this.insetX - this.widthVp > 0) {
            this.systemBarScrim(this.viewportWidth - this.insetX - this.widthVp, this.insetX + this.widthVp - 8, 0, 270, true)
          }
        }
        if (this.weakNotice) {
          Text(this.weakNotice).fontColor(Color.White).fontSize(14)
            .padding({left: 16, right: 16, top: 10, bottom: 10}).borderRadius(18).backgroundColor('#DD283332')
            .position({x: this.insetX + this.widthVp / 2, y: this.insetY + this.heightVp / 2})
            .markAnchor({x: '50%', y: '50%'}).hitTestBehavior(HitTestMode.None)
        }
      }
    }.width('100%').height('100%')
      .hitTestBehavior(HitTestMode.None)
      .expandSafeArea(this.state.sessionId && !this.mini() ? [SafeAreaType.SYSTEM, SafeAreaType.CUTOUT] : [],
        this.state.sessionId && !this.mini() ? [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END] : [])
      .onAreaChange((_old: Area, area: Area) => {
        this.viewportX = Number(area.globalPosition.x);
        this.viewportY = Number(area.globalPosition.y);
        this.viewportWidth = Number(area.width); this.viewportHeight = Number(area.height);
        this.updateViewport();
      })
  }
}
