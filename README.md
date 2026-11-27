# Flutter 视频客服组件

`wowbby/flutter-customer-video-service` 是面向业务 App 的私有内部交付仓库。Git 标签 `v0.3.0` 对应源工程 `JHKHIAILife_Nexus` 提交 `c9e1d831078f73196c859055323cd14f97c9e74d` 下的 `demos/rtc_demo` 组件。

## 接入

检出 `v0.3.0`，在宿主的 `pubspec.yaml` 中将 `customer_video_service` 的 path 指向本仓库的 `packages/customer_video_service`。保留与 `packages/customer_rtc` 的相邻目录关系。验证工具链为 Flutter OHOS `3.27.5-ohos-1.0.8` 和 Dart `3.6.2`。

鸿蒙首次构建前，在本仓库根目录执行以下命令，下载声网 4.4.2 HAR 并校验 SHA-256。

```sh
bash packages/customer_rtc/ohos/tool/setup_sdk.sh
```

[业务宿主接入指南](packages/customer_video_service/README.md) · [最小宿主示例](examples/minimal_host/README.md) · [原生插件接口](docs/contracts/native-plugin.md)
