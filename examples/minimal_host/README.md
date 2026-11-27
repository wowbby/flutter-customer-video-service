# 最小宿主

这个独立 Flutter 示例仅依赖 `customer_video_service` 的公共入口。点击「开始等待客服」直接调用 `beginWaiting()`。此示例可在没有 RTC 凭据时打开等待窗口，缩小后进入另一业务页，返回、恢复或取消。示例使用单个 FlutterEngine，通过 Flutter 生命周期管理会话。

## 从源码导出组件

在完整 Demo 的根目录运行以下命令。默认导出当前 HEAD，输出在 `exports/`。也可以把 Git 提交或标签作为第一个参数，把目标目录作为第二个参数。

```sh
./tool/export_components.sh
```

将输出的 `.tar.gz` 解压到项目外任意目录。归档顶层目录名记录了组件版本及完整提交号。两个包必须保留同级关系，升级时一起替换。要接入已有宿主，只需把 `packages/` 放到宿主选定的位置。例如，以下配置适用于放在宿主根目录的 `vendor/packages/`。

```yaml
dependencies:
  customer_video_service:
    path: vendor/packages/customer_video_service
```

iOS 宿主最低部署版本为 15。使用 Xcode 27 时，把 Runner、Podfile 的 `platform :ios` 和 Pod target 的 `IPHONEOS_DEPLOYMENT_TARGET` 一并设为 15.0。若现有 `post_install` 已遍历 target，可在 `flutter_additional_ios_build_settings(target)` 后加入以下配置。

```ruby
target.build_configurations.each do |config|
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
end
```

鸿蒙构建前，从 `packages/customer_rtc/ohos/` 运行 `./tool/setup_sdk.sh` 获取并校验固定版本 HAR。在宿主 `ohos/build-profile.json5` 的产品配置中开启 `buildOption.strictMode.useNormalizedOHMUrl` 以加载字节码 HAR。

真实通话由宿主提供摄像头、麦克风用途声明与短期凭据。独立原生业务页覆盖窗口还需在顶层容器接入插件，见 [Android](../../packages/customer_rtc/android/HOST.md)、[iOS](../../packages/customer_rtc/ios/HOST.md)、[鸿蒙](../../packages/customer_rtc/ohos/HOST.md)。

## 在解压目录验证示例

从归档顶层进入示例目录，使用 Flutter OHOS 3.27.5-ohos-1.0.8 / Dart 3.6.2。以下命令假设 `flutter` 指向该版本。首次解析需有依赖下载源，本机已有缓存时可用 `flutter pub get --offline`。

```sh
cd examples/minimal_host
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
```

Widget 测试覆盖进入业务页后小窗延续及结束清理。要在完整 Demo 的平台壳运行这个入口，从 Demo 根目录执行 `./tool/flutterw run -d <设备ID> --target examples/minimal_host/lib/main.dart`。业务准入时用服务器返回的凭据调用 `admit()`，收到坐席接听信令时调用 `updateBusinessState()`，Token 续期使用 `tokenProvider`。公共 API、现有 JSBridge 接线及迁移步骤见 [组件接入指南](../../packages/customer_video_service/README.md)。
