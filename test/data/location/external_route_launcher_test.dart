import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/location/navigation_target.dart';
import 'package:visitacampo/data/location/external_route_launcher.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final target = NavigationTarget.tryCreate(4.6, -74.08)!;
  const launcher = ExternalRouteLauncher();

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('abre fuera de SUNO, sin webview, credenciales ni cabeceras', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    expect(await launcher.open(target), isTrue);
    expect(calls.single.method, 'launch');
    final args = calls.single.arguments as Map<Object?, Object?>;
    expect(args['url'], target.directionsUri.toString());
    expect(args['useSafariVC'], isFalse);
    expect(args['useWebView'], isFalse);
    expect(args['headers'], isEmpty);
  });

  test('sistema sin manejador y error de plataforma devuelven fallo recuperable', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => false);
    expect(await launcher.open(target), isFalse);
    messenger.setMockMethodCallHandler(channel, (_) async => throw PlatformException(code: 'unavailable'));
    expect(await launcher.open(target), isFalse);
  });
}
