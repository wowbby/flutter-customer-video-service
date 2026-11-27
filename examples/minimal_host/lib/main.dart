import 'package:flutter/material.dart';
import 'package:customer_video_service/customer_video_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MinimalVideoHost(
      controller: VideoServiceController(
    allowProbe: true,
    // Replace with the host's authenticated credential service for real calls.
    credentialsProvider: (context) async =>
        throw const CallException(CallErrorCode.invalidConfiguration),
  )));
}

class MinimalVideoHost extends StatefulWidget {
  const MinimalVideoHost({super.key, required this.controller});
  final VideoServiceController controller;
  @override
  State<MinimalVideoHost> createState() => _MinimalVideoHostState();
}

class _MinimalVideoHostState extends State<MinimalVideoHost> {
  final _navigator = GlobalKey<NavigatorState>();
  late final _bridge = CustomerH5Bridge(
      controller: widget.controller, onOpenBusiness: _openBusiness);
  void _openBusiness() {
    _navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => VideoServiceBackScope(
            controller: widget.controller,
            child: Scaffold(
                appBar: AppBar(title: const Text('宿主业务页')),
                body: const Center(child: Text('会话由组件持有，页面可以自由退出。'))))));
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        navigatorKey: _navigator,
        builder: (_, child) =>
            VideoServiceHost(controller: widget.controller, child: child!),
        home: VideoServiceBackScope(
            controller: widget.controller,
            child: Scaffold(
                appBar: AppBar(title: const Text('最小组件宿主 · 无媒体示例')),
                body: Column(children: [
                  TextButton(
                      onPressed: _openBusiness, child: const Text('打开业务页')),
                  Expanded(
                      child:
                          CustomerServiceWebView(bridge: _bridge, html: _html)),
                ]))),
      );
  @override
  void dispose() {
    _bridge.dispose();
    widget.controller.dispose();
    super.dispose();
  }
}

const _html =
    '''<!doctype html><html><meta name="viewport" content="width=device-width,initial-scale=1"><body>
<h3>H5 发起，组件管理窗口</h3><p>此示例仅验证无媒体窗口，不采集摄像头。</p>
<button id="start" disabled onclick="send('startProbe')">启动无媒体窗口</button>
<button id="business" disabled onclick="send('openBusiness')">打开宿主业务页</button>
<pre id="state">等待桥接</pre><script>
let sequence=0;
function send(action){CustomerBridge.postMessage(JSON.stringify({version:1,requestId:String(++sequence),action:action,params:{}}));}
window.onNativeMessage=function(message){
 if(message.kind==='state'){document.getElementById('state').textContent=JSON.stringify(message.state,null,2);document.getElementById('start').disabled=!!message.state.sessionId;document.getElementById('business').disabled=false;}
};
</script></body></html>''';
