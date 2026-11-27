import { Any, PlatformView, PlatformViewFactory, StandardMessageCodec } from '@ohos/flutter_ohos';
import { Params } from '@ohos/flutter_ohos/src/main/ets/plugin/platform/PlatformView';
import common from '@ohos.app.ability.common';
import { Constants } from '@shengwang/rtc-full';

export interface VideoViewOwner {
  addVideo(view: CustomerVideoView): void;
  removeVideo(view: CustomerVideoView): void;
  videoReady(view: CustomerVideoView): void;
}

export class CustomerVideoView extends PlatformView {
  readonly renderId: string;
  ready: boolean = false;
  disposed: boolean = false;
  readonly owner: VideoViewOwner;
  readonly id: number;
  readonly role: string;
  readonly probe: boolean;
  constructor(owner: VideoViewOwner, id: number, role: string, probe: boolean) {
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

export class CustomerVideoFactory extends PlatformViewFactory {
  private owner: VideoViewOwner;
  constructor(owner: VideoViewOwner) { super(StandardMessageCodec.INSTANCE); this.owner = owner; }
  create(context: common.Context, id: number, args: Any): PlatformView {
    const values = args as Map<string, Object>;
    return new CustomerVideoView(this.owner, id, values.get('role') === 'local' ? 'local' : 'remote', values.get('probe') === true);
  }
}
