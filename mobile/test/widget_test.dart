import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ruang_chat/core/api.dart';
import 'package:ruang_chat/core/app_controller.dart';
import 'package:ruang_chat/core/models.dart';
import 'package:ruang_chat/screens/auth_screen.dart';
import 'package:ruang_chat/screens/chat_screen.dart';
import 'package:ruang_chat/widgets/common.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  testWidgets(
    'Login rejects invalid input without sending a request on a narrow phone',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var calls = 0;
      final app = AppController(
        client: ApiClient(
          'http://localhost',
          client: MockClient((_) async {
            calls++;
            return http.Response('{}', 400);
          }),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ruangTheme(Brightness.light),
          home: AuthScreen(app: app),
        ),
      );
      await tester.ensureVisible(find.text('Masuk ke Ruang'));
      await tester.tap(find.text('Masuk ke Ruang'));
      await tester.pumpAndSettle();
      expect(find.text('Masukkan email yang valid.'), findsOneWidget);
      expect(calls, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    },
  );
  testWidgets(
    'Chat sends real API payload, clears composer and deduplicates its response',
    (tester) async {
      final sent = <Map<String, dynamic>>[];
      final message = {
        'id': '1',
        'sender_id': 'alice',
        'client_id': 'seed-id-1',
        'text': 'Halo Alice',
        'created_at': '2026-10-31T00:00:00Z',
        'is_read': false,
        'reactions': <dynamic>[],
        'reply': null,
        'attachment': null,
      };
      final api = ApiClient(
        'http://localhost',
        client: MockClient((r) async {
          if (r.method == 'GET') {
            return http.Response(
              jsonEncode({
                'messages': [message],
                'has_more': false,
              }),
              200,
            );
          }
          if (r.url.path.endsWith('/read')) return http.Response('', 204);
          final body = jsonDecode(r.body) as Map<String, dynamic>;
          sent.add(body);
          return http.Response(
            jsonEncode({...message, ...body, 'id': '2'}),
            201,
          );
        }),
      );
      final app = AppController(client: api)
        ..user = const ChatUser(id: 'alice', name: 'Alice');
      await tester.pumpWidget(
        MaterialApp(
          theme: ruangTheme(Brightness.light),
          home: ChatScreen(
            app: app,
            conversation: const Conversation(
              id: 'c1',
              peer: ChatUser(id: 'bob', name: 'Bob'),
              lastMessage: '',
              unread: 0,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Kirim pesan'), findsNothing);
      await tester.enterText(find.byType(TextField).last, '  Pesan baru  ');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Kirim pesan'));
      await tester.pumpAndSettle();
      expect(sent.single['text'], 'Pesan baru');
      expect((sent.single['client_id'] as String).length, 36);
      expect(find.text('Pesan baru'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).last).controller!.text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      app.dispose();
    },
  );
  test(
    'API preserves server errors and expires unauthorized sessions',
    () async {
      var expired = false;
      final api = ApiClient(
        'http://localhost',
        client: MockClient(
          (_) async => http.Response('{"error":"Sesi berakhir"}', 401),
        ),
      )..onUnauthorized = () => expired = true;
      await expectLater(
        api.request('GET', '/me'),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)),
      );
      expect(expired, isTrue);
      api.close();
    },
  );
}
