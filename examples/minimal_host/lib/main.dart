import 'package:flutter/material.dart';
import 'package:customer_video_service/customer_video_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MinimalVideoHost(controller: VideoServiceController()));
}

class MinimalVideoHost extends StatefulWidget {
  const MinimalVideoHost({super.key, required this.controller});
  final VideoServiceController controller;
  @override
  State<MinimalVideoHost> createState() => _MinimalVideoHostState();
}

class _MinimalVideoHostState extends State<MinimalVideoHost> {
  final _navigator = GlobalKey<NavigatorState>();
  Future<void> _beginWaiting() async {
    try {
      await widget.controller.beginWaiting();
    } on CallException catch (error) {
      final context = _navigator.currentContext;
      if (context != null && context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.code.name)));
      }
    }
  }

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
                appBar: AppBar(title: const Text('视频客服接入示例')),
                body: Column(children: [
                  FilledButton(
                      onPressed: _beginWaiting, child: const Text('开始等待客服')),
                  TextButton(
                      onPressed: _openBusiness, child: const Text('打开业务页')),
                ]))),
      );
  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }
}
