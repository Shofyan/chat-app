import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'models.dart';
import 'realtime.dart';

class AppController extends ChangeNotifier {
  AppController({ApiClient? client}) : api = client ?? ApiClient(defaultBase) {
    realtime = Realtime(api);
    api.onUnauthorized = expireSession;
  }
  static String get defaultBase =>
      const String.fromEnvironment('API_BASE_URL', defaultValue: '') != ''
      ? const String.fromEnvironment('API_BASE_URL')
      : !kIsWeb && defaultTargetPlatform == TargetPlatform.android
      ? 'http://10.0.2.2:8080'
      : 'http://localhost:8080';
  final ApiClient api;
  late final Realtime realtime;
  final _storage = const FlutterSecureStorage();
  ChatUser? user;
  ThemeMode themeMode = ThemeMode.system;
  bool loading = true;
  String? startupError;
  SharedPreferences? _prefs;
  Future<void> initialize() async {
    loading = true;
    startupError = null;
    notifyListeners();
    try {
      _prefs = await SharedPreferences.getInstance();
      api.baseUrl = _prefs!.getString('server') ?? defaultBase;
      themeMode = ThemeMode.values[_prefs!.getInt('theme')?.clamp(0, 2) ?? 0];
      api.token = await _storage.read(key: 'session');
      if (api.token != null) {
        try {
          user = ChatUser.fromJson(await api.request('GET', '/me'));
          realtime.start();
        } on ApiException catch (e) {
          if (e.status == 401) {
            await _clearSession();
          } else {
            startupError = e.message;
          }
        }
      }
    } catch (_) {
      startupError =
          'Penyimpanan sesi belum tersedia. Coba muat ulang aplikasi.';
    }
    loading = false;
    notifyListeners();
  }

  Future<void> authenticate({
    required String email,
    required String password,
    String? name,
  }) async {
    final data = await api.request(
      'POST',
      name == null ? '/auth/login' : '/auth/register',
      data: {'email': email, 'password': password, 'name': ?name},
    );
    await _storage.write(key: 'session', value: data['token']);
    api.token = data['token'];
    user = ChatUser.fromJson(data['user']);
    realtime.start();
    notifyListeners();
  }

  Future<void> setServer(String value) async {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const ApiException(
        'Masukkan alamat dasar, contoh http://192.168.1.10:8080',
      );
    }
    api.baseUrl = value.trim().replaceAll(RegExp(r'/+$'), '');
    await _prefs?.setString('server', api.baseUrl);
    notifyListeners();
  }

  Future<void> setTheme(ThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    await _prefs?.setInt('theme', mode.index);
  }

  Future<void> logout() async {
    await api.request('POST', '/auth/logout');
    await _clearSession();
    notifyListeners();
  }

  Future<void> _clearSession() async {
    realtime.stop();
    api.token = null;
    user = null;
    startupError = null;
    await _storage.delete(key: 'session');
  }

  Future<void> forgetSession() async {
    await _clearSession();
    notifyListeners();
  }

  void expireSession() {
    if (user != null) {
      _clearSession().then((_) => notifyListeners());
    }
  }

  @override
  void dispose() {
    realtime.dispose();
    api.close();
    super.dispose();
  }
}
