import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ruang_chat/core/api.dart';
import 'package:ruang_chat/core/app_controller.dart';
import 'package:ruang_chat/core/models.dart';
import 'package:ruang_chat/core/realtime.dart';
import 'package:ruang_chat/screens/home_screen.dart';
import 'package:ruang_chat/widgets/common.dart';

// Run only against the disposable backend created by scripts/test-mobile.sh.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final screenshotKey = GlobalKey();
  Future<void> capture(String name) async {
    final boundary =
        screenshotKey.currentContext!.findRenderObject()
            as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    binding.reportData ??= <String, dynamic>{};
    final screenshots = binding.reportData!['screenshots'] ??= <dynamic>[];
    (screenshots as List).add({
      'screenshotName': name,
      'bytes': data!.buffer.asUint8List().toList(),
    });
  }

  Future<void> visible(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 60 && finder.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(finder, findsWidgets);
  }

  testWidgets(
    'Native Android chat uses real HTTP, WebSocket, replies and reactions',
    (tester) async {
      const base = String.fromEnvironment(
        'API_BASE_URL',
        defaultValue: 'http://10.0.2.2:18081',
      );
      final app = AppController(client: ApiClient(base));
      final peer = ApiClient(base);
      final stamp = DateTime.now().microsecondsSinceEpoch;
      await app.initialize();
      await app.forgetSession();
      await app.setTheme(ThemeMode.light);
      await app.authenticate(
        name: 'Rina Novita',
        email: 'rina-$stamp@test.local',
        password: 'Integration123!',
      );
      final result = await peer.request(
        'POST',
        '/auth/register',
        data: {
          'name': 'Andi Pratama',
          'email': 'andi-$stamp@test.local',
          'password': 'Integration123!',
        },
      );
      peer.token = result['token'];
      final peerUser = ChatUser.fromJson(result['user']);
      final conversation = await app.api.request(
        'POST',
        '/conversations',
        data: {'user_id': peerUser.id},
      );
      final cid = conversation['id'] as String;
      final peerRealtime = Realtime(peer);
      final ready = peerRealtime.events.firstWhere((e) => e['type'] == 'ready');
      peerRealtime.start();
      await ready.timeout(const Duration(seconds: 10));
      await peer.request(
        'POST',
        '/conversations/$cid/messages',
        data: {
          'client_id': 'welcome-$stamp',
          'text': 'Hai Rina! Sudah siap belajar Flutter? 👋',
        },
      );

      await tester.pumpWidget(
        RepaintBoundary(
          key: screenshotKey,
          child: ListenableBuilder(
            listenable: app,
            builder: (context, _) => MaterialApp(
              theme: ruangTheme(Brightness.light),
              darkTheme: ruangTheme(Brightness.dark),
              themeMode: app.themeMode,
              home: HomeScreen(app: app),
            ),
          ),
        ),
      );
      await visible(tester, find.text('Andi Pratama'));
      debugPrint('E2E: conversations loaded');
      await tester.tap(find.text('Andi Pratama'));
      debugPrint('E2E: room opened');
      await visible(
        tester,
        find.text('Hai Rina! Sudah siap belajar Flutter? 👋'),
      );
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 12),
      );
      final delivered = peerRealtime.events.firstWhere(
        (e) =>
            e['type'] == 'message' &&
            e['message']['text'] ==
                'Siap! Backend Go dan Docker sudah terhubung.',
      );
      debugPrint('E2E: entering message');
      await tester.enterText(
        find.byType(TextField).last,
        'Siap! Backend Go dan Docker sudah terhubung.',
      );
      debugPrint('E2E: message entered');
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 12),
      );
      await tester.tap(find.byTooltip('Kirim pesan'));
      final received = await delivered.timeout(const Duration(seconds: 10));
      expect(received['message']['sender_id'], app.user!.id);
      await visible(
        tester,
        find.text('Siap! Backend Go dan Docker sudah terhubung.'),
      );
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 12),
      );
      await tester.longPress(
        find.text('Hai Rina! Sudah siap belajar Flutter? 👋'),
      );
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 12),
      );
      await tester.tap(find.text('Balas pesan'));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 12),
      );
      await tester.enterText(
        find.byType(TextField).last,
        'Kita tambahkan fitur balas dan reaksi juga, ya ✨',
      );
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 12),
      );
      await tester.tap(find.byTooltip('Kirim pesan'));
      await visible(
        tester,
        find.text('Kita tambahkan fitur balas dan reaksi juga, ya ✨'),
      );
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 12),
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 12),
      );
      final history = await peer.request('GET', '/conversations/$cid/messages');
      final messages = history['messages'] as List;
      expect(
        messages.last['reply']['text'],
        'Hai Rina! Sudah siap belajar Flutter? 👋',
      );
      await peer.request(
        'POST',
        '/conversations/$cid/read',
        data: {'message_id': messages.last['id']},
      );
      await peer.request(
        'PUT',
        '/messages/${messages.last['id']}/reaction',
        data: {'emoji': '❤️'},
      );
      await visible(tester, find.text('❤️'));
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 12),
      );
      await tester.pump();
      await capture('android-chat-light');
      await app.setTheme(ThemeMode.dark);
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 12),
      );
      await tester.pump();
      await capture('android-chat-dark');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await app.logout();
      peerRealtime.dispose();
      peer.close();
      app.dispose();
    },
  );
}
