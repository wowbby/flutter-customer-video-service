import { trustedHtml } from './TrustedHtml';
import { Any, PlatformView, PlatformViewFactory, StandardMessageCodec } from '@ohos/flutter_ohos';
import { Params } from '@ohos/flutter_ohos/src/main/ets/plugin/platform/PlatformView';
import common from '@ohos.app.ability.common';
import webview from '@ohos.web.webview';
import { Constants } from '@shengwang/rtc-full';

export interface ViewOwner {
  emit(event: Map<string, Object>): void;
  addWeb(view: CustomerWebView): void;
  removeWeb(id: number): void;
  addVideo(view: CustomerVideoView): void;
  removeVideo(view: CustomerVideoView): void;
  videoReady(view: CustomerVideoView): void;
}

export class BridgeProxy {
  private view: CustomerWebView;
  constructor(view: CustomerWebView) { this.view = view; }
  postMessage(message: string): void {
    if (this.view.trusted && !this.view.disposed && typeof message === 'string' && message.length <= 65536) {
      this.view.owner.emit(new Map<string, Object>([['type', 'bridge'], ['viewId', this.view.id], ['message', message]]));
    }
  }
}

export class CustomerWebView extends PlatformView {
  readonly controller: webview.WebviewController = new webview.WebviewController();
  readonly proxy: BridgeProxy = new BridgeProxy(this);
  readonly url: string;
  trusted: boolean = false;
  disposed: boolean = false;
  loaded: boolean = false;
  private initialNavigationPending: boolean = false;
  private initialNavigationAccepted: boolean = false;
  readonly owner: ViewOwner;
  readonly id: number;
  readonly html: string;
  constructor(owner: ViewOwner, id: number, html: string) {
    super();
    this.owner = owner; this.id = id; this.html = html;
    this.url = `https://customer.invalid/view-${id}/`;
    owner.addWeb(this);
  }
  getView(): WrappedBuilder<[Params]> { return new WrappedBuilder(webBuilder); }
  attach(): void {
    if (this.disposed || this.loaded) { return; }
    this.loaded = true;
    // No remote resources or frames can inherit the JS proxy. Only the bundled main document runs.
    this.initialNavigationPending = true;
    this.controller.loadData(trustedHtml(this.html), 'text/html', 'UTF-8', this.url, this.url);
  }
  intercept(url: string, mainFrame: boolean): boolean {
    // ArkWeb reports loadData as data:text/html even with an HTTPS base URL.
    // Consume this native-owned load exactly once; all later navigation is denied.
    if (!this.disposed && mainFrame && this.initialNavigationPending && url.startsWith('data:text/html')) {
      this.initialNavigationPending = false;
      this.initialNavigationAccepted = true;
      return false;
    }
    return true;
  }
  ready(url: string): void {
    this.trusted = !this.disposed && this.initialNavigationAccepted &&
      (url === this.url || url.startsWith('data:text/html'));
    if (this.trusted) {
      this.owner.emit(new Map<string, Object>([['type', 'webReady'], ['viewId', this.id]]));
    }
  }
  reply(json: string): void {
    const parsed: Object = JSON.parse(json) as Object;
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) { throw new Error('invalid_json'); }
    if (!this.disposed && this.trusted) {
      this.controller.runJavaScript(`window.onNativeMessage && window.onNativeMessage(${JSON.stringify(parsed)});`).catch(() => {});
    }
  }
  dispose(): void {
    this.disposed = true;
    this.trusted = false;
    this.owner.removeWeb(this.id);
    try { this.controller.deleteJavaScriptRegister('CustomerBridge'); this.controller.stop(); } catch (_) {}
  }
}

@Builder
function webBuilder(params: Params) {
  WebSurface({ view: params.platformView as CustomerWebView })
}

@Component
struct WebSurface {
  view: CustomerWebView = null!;
  build() {
    Web({ src: '', controller: this.view.controller })
      .width('100%').height('100%')
      .javaScriptAccess(true).domStorageAccess(false).fileAccess(false)
      .mixedMode(MixedMode.None).blockNetwork(true).multiWindowAccess(false)
      .javaScriptProxy({ object: this.view.proxy, name: 'CustomerBridge', methodList: ['postMessage'], controller: this.view.controller })
      .onControllerAttached(() => this.view.attach())
      .onPageBegin(() => { this.view.trusted = false; })
      .onPageEnd((event) => this.view.ready(event?.url ?? ''))
      .onLoadIntercept((event) => {
        // loadData has a single native-owned initial load; every subsequent navigation is denied.
        return this.view.intercept(event?.data.getRequestUrl() ?? '', event?.data.isMainFrame() ?? false);
      })
      .onPermissionRequest((event) => { event?.request.deny(); })
  }
}

export class CustomerVideoView extends PlatformView {
  readonly renderId: string;
  ready: boolean = false;
  disposed: boolean = false;
  readonly owner: ViewOwner;
  readonly id: number;
  readonly role: string;
  readonly probe: boolean;
  constructor(owner: ViewOwner, id: number, role: string, probe: boolean) {
    super();
    this.owner = owner; this.id = id; this.role = role; this.probe = probe;
    this.renderId = `customer_rtc_${id}_${role}`;
    if (!probe) { owner.addVideo(this); }
  }
  getView(): WrappedBuilder<[Params]> { return new WrappedBuilder(videoBuilder); }
  loaded(): void {
    if (!this.disposed) { this.ready = true; this.owner.videoReady(this); }
  }
  unloaded(): void { this.ready = false; this.owner.removeVideo(this); }
  dispose(): void { this.disposed = true; this.ready = false; this.owner.removeVideo(this); }
}

@Builder
function videoBuilder(params: Params) {
  VideoSurface({ view: params.platformView as CustomerVideoView })
}

@Component
struct VideoSurface {
  view: CustomerVideoView = null!;
  build() {
    Stack() {
      if (this.view.probe) {
        Column() {
          Text(this.view.role === 'local' ? 'LOCAL' : 'NATIVE · OHOS')
            .fontColor(Color.White).fontSize(this.view.role === 'local' ? 10 : 18).maxLines(1)
          Text(this.view.role === 'local' ? '无媒体' : 'REMOTE · 无媒体')
            .fontColor('#A6C2D2').fontSize(this.view.role === 'local' ? 8 : 11).maxLines(1)
          Text(`view ${this.view.id}`).fontColor('#A6C2D2')
            .fontSize(this.view.role === 'local' ? 7 : 10).maxLines(1)
        }.justifyContent(FlexAlign.Center).width('100%').height('100%').backgroundColor('#153342')
      } else {
        XComponent({ id: this.view.renderId, type: 'surface', libraryname: Constants.AGORA_LIB_NAME })
          .width('100%').height('100%').onLoad(() => this.view.loaded()).onDestroy(() => this.view.unloaded())
      }
    }.width('100%').height('100%').clip(true).backgroundColor(Color.Black)
  }
}

export class CustomerWebFactory extends PlatformViewFactory {
  private owner: ViewOwner;
  constructor(owner: ViewOwner) { super(StandardMessageCodec.INSTANCE); this.owner = owner; }
  create(context: common.Context, id: number, args: Any): PlatformView {
    const values = args as Map<string, Object>;
    return new CustomerWebView(this.owner, id, values.get('html') as string ?? '');
  }
}
export class CustomerVideoFactory extends PlatformViewFactory {
  private owner: ViewOwner;
  constructor(owner: ViewOwner) { super(StandardMessageCodec.INSTANCE); this.owner = owner; }
  create(context: common.Context, id: number, args: Any): PlatformView {
    const values = args as Map<string, Object>;
    return new CustomerVideoView(this.owner, id, values.get('role') === 'local' ? 'local' : 'remote', values.get('probe') === true);
  }
}
