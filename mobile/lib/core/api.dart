import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'models.dart';

class ApiException implements Exception {
  const ApiException(this.message, [this.status = 0]);
  final String message;
  final int status;
  @override
  String toString() => message;
}

class ApiClient {
  ApiClient(this.baseUrl, {http.Client? client})
    : _client = client ?? http.Client();
  String baseUrl;
  String? token;
  void Function()? onUnauthorized;
  final http.Client _client;
  Uri uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl/api/v1$path').replace(queryParameters: query);
  Map<String, String> get headers => {
    if (token != null) 'Authorization': 'Bearer $token',
  };
  Future<Json> request(
    String method,
    String path, {
    Json? data,
    Map<String, String>? query,
  }) async {
    final req = http.Request(method, uri(path, query));
    req.headers.addAll({...headers, 'Content-Type': 'application/json'});
    if (data != null) req.body = jsonEncode(data);
    try {
      final response = await http.Response.fromStream(await _client.send(req))
          .timeout(const Duration(seconds: 25));
      _check(response.statusCode, response.bodyBytes, path);
      return response.bodyBytes.isEmpty
          ? {}
          : jsonDecode(utf8.decode(response.bodyBytes)) as Json;
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw const ApiException('Koneksi terlalu lama. Coba lagi.');
    } catch (_) {
      throw const ApiException(
        'Server belum terhubung. Periksa alamat server dan jaringan.',
      );
    }
  }

  void _check(int status, Uint8List bytes, String path) {
    if (status < 400) return;
    if (status == 401 && !path.startsWith('/auth/')) onUnauthorized?.call();
    String message = 'Permintaan gagal ($status).';
    try {
      message = jsonDecode(utf8.decode(bytes))['error'] ?? message;
    } catch (_) {
      /* Non-JSON proxy response. */
    }
    throw ApiException(message, status);
  }

  Future<Attachment> upload(
    String conversationId,
    String name,
    Uint8List bytes,
  ) async {
    if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
      throw const ApiException('Ukuran lampiran harus 1 byte sampai 8 MB.');
    }
    final req =
        http.MultipartRequest(
            'POST',
            uri('/conversations/$conversationId/attachments'),
          )
          ..headers.addAll(headers)
          ..files.add(
            http.MultipartFile.fromBytes('file', bytes, filename: name),
          );
    try {
      final response = await http.Response.fromStream(await _client.send(req))
          .timeout(const Duration(seconds: 45));
      _check(response.statusCode, response.bodyBytes, '/attachments');
      return Attachment.fromJson(jsonDecode(utf8.decode(response.bodyBytes)));
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException(
        'Unggah gagal. Periksa jaringan, lalu coba lagi.',
      );
    }
  }

  Future<Uint8List> attachment(String id) async {
    try {
      final response = await _client
          .get(uri('/attachments/$id'), headers: headers)
          .timeout(const Duration(seconds: 30));
      _check(response.statusCode, response.bodyBytes, '/attachments/$id');
      return response.bodyBytes;
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException('Lampiran gagal dimuat.');
    }
  }

  void close() => _client.close();
}
