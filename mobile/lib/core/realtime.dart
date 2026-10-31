import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api.dart';
import 'models.dart';

class Realtime {
  Realtime(this.api);
  final ApiClient api;
  final connected = ValueNotifier(false);
  final _events = StreamController<Json>.broadcast();
  Stream<Json> get events => _events.stream;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _retry;
  bool _stopped = true;
  int _generation = 0, _attempt = 0;
  void start() {
    _stopped = false;
    _connect();
  }

  void reconnect() {
    if (!_stopped) _connect();
  }

  Future<void> _connect() async {
    final generation = ++_generation;
    _retry?.cancel();
    connected.value = false;
    await _subscription?.cancel();
    await _channel?.sink.close();
    if (_stopped || generation != _generation || api.token == null) return;
    try {
      final uri = api.uri('/ws');
      final channel = WebSocketChannel.connect(
        uri.replace(scheme: uri.scheme == 'https' ? 'wss' : 'ws'),
      );
      _channel = channel;
      await channel.ready.timeout(const Duration(seconds: 8));
      if (_stopped || generation != _generation) {
        await channel.sink.close();
        return;
      }
      channel.sink.add(jsonEncode({'type': 'auth', 'token': api.token}));
      _subscription = channel.stream.listen(
        (data) {
          if (generation != _generation || _stopped) return;
          try {
            final event = jsonDecode(data as String) as Json;
            if (event['type'] == 'ready') {
              connected.value = true;
              _attempt = 0;
            }
            _events.add(event);
          } catch (_) {
            /* Ignore malformed transport frames. */
          }
        },
        onError: (Object _) => _disconnected(generation),
        onDone: () {
          if (channel.closeCode == 1008 &&
              !_stopped &&
              generation == _generation) {
            api.onUnauthorized?.call();
          } else {
            _disconnected(generation);
          }
        },
        cancelOnError: true,
      );
    } catch (_) {
      _disconnected(generation);
    }
  }

  void _disconnected(int generation) {
    if (_stopped || generation != _generation) return;
    connected.value = false;
    _retry?.cancel();
    _retry = Timer(
      Duration(seconds: min(30, 1 << min(_attempt++, 5))),
      _connect,
    );
  }

  void typing(String id, bool value) {
    if (connected.value) {
      _channel?.sink.add(
        jsonEncode({'type': 'typing', 'conversation_id': id, 'typing': value}),
      );
    }
  }

  void stop() {
    _stopped = true;
    _generation++;
    _retry?.cancel();
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    connected.value = false;
  }

  void dispose() {
    stop();
    connected.dispose();
    _events.close();
  }
}
