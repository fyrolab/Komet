import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../../backend/api.dart';
import '../../frontend/screens/chats/chat_list_screen.dart';
import '../../frontend/widgets/swipe_route.dart';
import '../../main.dart';
import '../../models/shared_payload.dart';
import '../utils/logger.dart';
import 'share_inbox.dart';
import 'shared_file_usage.dart';

class ShareIntentBridge {
  ShareIntentBridge._();
  static final ShareIntentBridge instance = ShareIntentBridge._();

  static const _method = MethodChannel('ru.komet.app/share');
  static const _events = EventChannel('ru.komet.app/share_events');
  static const _retryDelay = Duration(milliseconds: 300);
  static const _maxRetries = 100;

  bool _started = false;
  bool _ready = false;
  bool _presenting = false;
  SharedPayload? _pending;
  int _retriesLeft = 0;
  Timer? _retry;
  late final _inbox = ShareInbox(
    consume: () => _method.invokeMethod<dynamic>('consumeInitialShare'),
    acknowledge: (id) =>
        _method.invokeMethod<void>('acknowledgeShare', {'id': id}),
    onShare: _receivePayload,
  );

  bool get _native {
    try {
      return Platform.isAndroid || Platform.isIOS;
    } catch (_) {
      return false;
    }
  }

  void init() {
    if (_started || !_native) return;
    _started = true;
    _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (e) => logger.w('ShareIntentBridge: events stream error: $e'),
    );
    api.stateStream.listen((state) {
      if (state == SessionState.online) _flushPending();
    });
  }

  void markReady() {
    _ready = true;
    _flushPending();
  }

  Future<void> checkInitialShare() async {
    if (!_native) return;
    try {
      if (Platform.isIOS) {
        await _inbox.check();
      } else {
        _onEvent(await _method.invokeMethod<dynamic>('consumeInitialShare'));
      }
    } catch (e) {
      logger.w('ShareIntentBridge.checkInitialShare: $e');
    }
  }

  Future<void> clearCache() async {
    if (!_native) return;
    try {
      await _method.invokeMethod<void>('clearCache');
    } catch (e) {
      logger.w('ShareIntentBridge.clearCache: $e');
    }
  }

  void _onEvent(Object? event) {
    if (Platform.isIOS) {
      unawaited(checkInitialShare());
      return;
    }
    final payload = SharedPayload.fromMap(event);
    if (payload == null) return;
    _receivePayload(payload);
  }

  void _receivePayload(SharedPayload payload) {
    logger.i(
      'Поделиться: получено ${payload.files.length} файлов'
      '${payload.text != null ? ' и текст' : ''}',
    );
    _pending = payload;
    _retriesLeft = _maxRetries;
    _flushPending();
  }

  void _flushPending() {
    final payload = _pending;
    if (payload == null || _presenting) return;

    final context = KometApp.navigatorKey.currentContext;
    if (!_ready || context == null || api.state != SessionState.online) {
      if (Platform.isIOS && (!_ready || api.state != SessionState.online)) {
        return;
      }
      if (!Platform.isIOS && _retriesLeft <= 0) {
        _pending = null;
        return;
      }
      _retriesLeft--;
      _retry ??= Timer(_retryDelay, () {
        _retry = null;
        _flushPending();
      });
      return;
    }

    _pending = null;
    _retry?.cancel();
    _retry = null;
    _presenting = true;
    unawaited(
      pushSwipeable<void>(
        context,
        (_) => ChatListScreen(sharePayload: payload),
      ).whenComplete(() => _finishShare(payload)),
    );
  }

  Future<void> _finishShare(SharedPayload payload) async {
    try {
      await SharedFileUsage.instance.waitUntilUnused(
        payload.files.map((file) => file.path),
      );
      if (Platform.isIOS) {
        await _inbox.complete();
      } else if (_pending == null) {
        await clearCache();
      }
    } catch (e) {
      logger.w('ShareIntentBridge.complete: $e');
    } finally {
      _presenting = false;
      _flushPending();
    }
  }
}
