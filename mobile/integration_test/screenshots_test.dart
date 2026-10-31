import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ruang_chat/core/api.dart';
import 'package:ruang_chat/core/app_controller.dart';
import 'package:ruang_chat/core/models.dart';
import 'package:ruang_chat/core/realtime.dart';
import 'package:ruang_chat/screens/auth_screen.dart';
import 'package:ruang_chat/screens/home_screen.dart';
import 'package:ruang_chat/widgets/common.dart';

// Uses the disposable backend in capture-screenshots.sh and leaves saved user
// sessions and preferences untouched. Every captured page is the real app UI.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final screenshotKey = GlobalKey();
  final navigatorKey = GlobalKey<NavigatorState>();

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 12),
    );
  }

  Future<void> visible(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 60 && finder.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(finder, findsWidgets);
    await settle(tester);
  }

  Future<void> capture(WidgetTester tester, String name) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(tester);
    expect(tester.takeException(), isNull);
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
    debugPrint('Captured $name');
  }

  Future<Json> register(ApiClient api, String name, String email) async {
    final response = await api.request(
      'POST',
      '/auth/register',
      data: {'name': name, 'email': email, 'password': 'Screenshot123!'},
    );
    api.token = response['token'];
    return response['user'];
  }

  Future<Json> send(ApiClient api, String cid, String text, {String? reply}) =>
      api.request(
        'POST',
        '/conversations/$cid/messages',
        data: {
          'client_id': 'gallery-${DateTime.now().microsecondsSinceEpoch}',
          'text': text,
          'reply_to_id': ?reply,
        },
      );

  testWidgets('Capture every mobile page and supporting chat panel', (
    tester,
  ) async {
    const base = String.fromEnvironment(
      'API_BASE_URL',
      defaultValue: 'http://10.0.2.2:18081',
    );
    const fixture = String.fromEnvironment('SCREENSHOT_IMAGE_BASE64');
    expect(fixture, isNotEmpty, reason: 'Run scripts/capture-screenshots.sh');
    final app = AppController(client: ApiClient(base));
    final andi = ApiClient(base),
        sari = ApiClient(base),
        dimas = ApiClient(base);
    final andiRealtime = Realtime(andi);

    try {
      await app.setTheme(ThemeMode.light);
      await tester.pumpWidget(
        RepaintBoundary(
          key: screenshotKey,
          child: ListenableBuilder(
            listenable: app,
            builder: (context, _) => MaterialApp(
              navigatorKey: navigatorKey,
              title: 'Ruang Chat',
              debugShowCheckedModeBanner: false,
              theme: ruangTheme(Brightness.light),
              darkTheme: ruangTheme(Brightness.dark),
              themeMode: app.themeMode,
              home: app.user == null
                  ? AuthScreen(app: app)
                  : HomeScreen(key: ValueKey(app.user!.id), app: app),
            ),
          ),
        ),
      );
      await capture(tester, '01-login');
      await tester.tap(find.byTooltip('Pengaturan server'));
      await visible(tester, find.text('Alamat server'));
      await capture(tester, '03-server-settings');
      await tester.tap(find.text('Batal'));
      await settle(tester);
      await tester.ensureVisible(find.text('Belum punya akun? Daftar'));
      await tester.tap(find.text('Belum punya akun? Daftar'));
      await settle(tester);
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, 900),
      );
      await capture(tester, '02-register');

      // Set up genuine API data without writing to the device's secure storage.
      final me = await register(app.api, 'Rina Novita', 'rina@demo.local');
      final peer = await register(andi, 'Andi Pratama', 'andi@demo.local');
      final sariUser = await register(sari, 'Sari Putri', 'sari@demo.local');
      final dimasUser = await register(
        dimas,
        'Dimas Saputra',
        'dimas@demo.local',
      );
      final andiChat = await app.api.request(
        'POST',
        '/conversations',
        data: {'user_id': peer['id']},
      );
      final sariChat = await app.api.request(
        'POST',
        '/conversations',
        data: {'user_id': sariUser['id']},
      );
      final dimasChat = await app.api.request(
        'POST',
        '/conversations',
        data: {'user_id': dimasUser['id']},
      );
      final cid = andiChat['id'] as String;
      final welcome = await send(
        andi,
        cid,
        'Hai Rina! Sudah siap belajar Flutter? 👋',
      );
      await send(
        app.api,
        cid,
        'Siap! Tampilan chat dan backend Go sudah terhubung.',
      );
      await send(
        andi,
        cid,
        'Kita coba fitur balas pesan dan berbagi gambar, ya.',
      );
      final reply = await send(
        app.api,
        cid,
        'Setuju. Sekarang pesannya bisa dibalas juga ✨',
        reply: welcome['id'],
      );
      await send(sari, sariChat['id'], 'Besok belajar Flutter bareng, yuk! 📚');
      await send(
        dimas,
        dimasChat['id'],
        'Mantap, Docker-nya sudah berjalan 🚀',
      );
      final image = await app.api.upload(
        cid,
        'ruang-chat.png',
        base64Decode(fixture),
      );
      await app.api.request(
        'POST',
        '/conversations/$cid/messages',
        data: {
          'client_id': 'gallery-image-message',
          'text': 'Ikon aplikasi Ruang yang baru ✨',
          'attachment_id': image.id,
        },
      );
      final latest = await app.api.request(
        'GET',
        '/conversations/$cid/messages',
      );
      await andi.request(
        'POST',
        '/conversations/$cid/read',
        data: {'message_id': (latest['messages'] as List).last['id']},
      );
      await andi.request(
        'PUT',
        '/messages/${reply['id']}/reaction',
        data: {'emoji': '❤️'},
      );

      final andiReady = andiRealtime.events.firstWhere(
        (e) => e['type'] == 'ready',
      );
      andiRealtime.start();
      await andiReady.timeout(const Duration(seconds: 10));
      final meReady = app.realtime.events.firstWhere(
        (e) => e['type'] == 'ready',
      );
      app.realtime.start();
      await meReady.timeout(const Duration(seconds: 10));
      app.user = ChatUser.fromJson(me);
      await app.setTheme(ThemeMode.light);
      await visible(tester, find.text('Percakapan'));
      await visible(tester, find.text('Andi Pratama'));
      await capture(tester, '04-conversations');

      await tester.tap(find.text('Chat baru'));
      await visible(tester, find.text('Mulai percakapan'));
      await visible(tester, find.text('Sari Putri').last);
      await capture(tester, '05-new-chat');
      navigatorKey.currentState!.pop();
      await settle(tester);

      await tester.tap(find.byTooltip('Profil & preferensi'));
      await visible(tester, find.text('Profil & preferensi'));
      await capture(tester, '06-profile');
      navigatorKey.currentState!.pop();
      await settle(tester);

      await tester.tap(find.text('Andi Pratama'));
      await visible(tester, find.text('Ikon aplikasi Ruang yang baru ✨'));
      await visible(tester, find.byType(Image));
      await capture(tester, '07-chat');
      await app.setTheme(ThemeMode.dark);
      await capture(tester, '08-chat-dark');
      await app.setTheme(ThemeMode.light);
      await settle(tester);

      await tester.tap(find.byType(UserAvatar).first);
      await visible(tester, find.text('Info kontak'));
      await capture(tester, '09-contact');
      navigatorKey.currentState!.pop();
      await settle(tester);

      await tester.tap(find.byType(Image).first);
      await visible(tester, find.byType(InteractiveViewer));
      await capture(tester, '10-image-viewer');
      navigatorKey.currentState!.pop();
      await settle(tester);

      await tester.tap(find.byTooltip('Lampirkan file'));
      await visible(tester, find.text('Bagikan sesuatu'));
      await capture(tester, '11-attachments');
      navigatorKey.currentState!.pop();
      await settle(tester);

      await tester.longPress(find.text('Ikon aplikasi Ruang yang baru ✨'));
      await visible(tester, find.text('Balas pesan'));
      await capture(tester, '12-reactions');
      await tester.tap(find.text('Balas pesan'));
      await settle(tester);
      await capture(tester, '13-reply');
      await tester.tap(find.byTooltip('Batalkan balasan'));
      await tester.tap(find.byTooltip('Cari pesan'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).first, 'Flutter');
      await capture(tester, '14-search');
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      app.api.onUnauthorized = null;
      app.realtime.stop();
      andiRealtime.dispose();
      for (final api in [app.api, andi, sari, dimas]) {
        if (api.token != null) await api.request('POST', '/auth/logout');
      }
      app.dispose();
      andi.close();
      sari.close();
      dimas.close();
    }
  });
}
