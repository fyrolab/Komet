import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:komet/core/share/share_inbox.dart';

Map<String, Object?> _share(String id) => {'id': id, 'text': 'Synthetic $id'};

void main() {
  test('coalesces initial, resumed and native event checks', () async {
    final response = Completer<Object?>();
    var consumes = 0;
    final received = <String?>[];
    final inbox = ShareInbox(
      consume: () {
        consumes++;
        return response.future;
      },
      acknowledge: (_) async {},
      onShare: (payload) => received.add(payload.text),
    );

    final first = inbox.check();
    final second = inbox.check();
    final third = inbox.check();
    expect(consumes, 1);
    response.complete(_share('first'));
    await Future.wait([first, second, third]);

    expect(consumes, 1);
    expect(received, ['Synthetic first']);
  });

  test('keeps the active share until explicitly completed', () async {
    var consumes = 0;
    final acknowledged = <String>[];
    final received = <String?>[];
    final inbox = ShareInbox(
      consume: () async {
        consumes++;
        return _share('pending');
      },
      acknowledge: (id) async => acknowledged.add(id),
      onShare: (payload) => received.add(payload.text),
    );

    await inbox.check();
    for (var i = 0; i < 150; i++) {
      await inbox.check();
    }

    expect(consumes, 1);
    expect(acknowledged, isEmpty);
    expect(received, ['Synthetic pending']);
  });

  test('acknowledges one share before consuming the next', () async {
    final pending = ['first', 'second'];
    final operations = <String>[];
    final received = <String?>[];
    final inbox = ShareInbox(
      consume: () async {
        operations.add('consume');
        return pending.isEmpty ? null : _share(pending.first);
      },
      acknowledge: (id) async {
        operations.add('acknowledge $id');
        expect(pending.removeAt(0), id);
      },
      onShare: (payload) => received.add(payload.text),
    );

    await inbox.check();
    await Future.wait([inbox.complete(), inbox.check(), inbox.check()]);
    expect(received, ['Synthetic first', 'Synthetic second']);
    expect(operations, ['consume', 'acknowledge first', 'consume']);

    await inbox.complete();
    expect(operations, [
      'consume',
      'acknowledge first',
      'consume',
      'acknowledge second',
      'consume',
    ]);
  });

  test('retries failed acknowledgement without presenting again', () async {
    var failed = false;
    final pending = ['first', 'second'];
    final received = <String?>[];
    final inbox = ShareInbox(
      consume: () async => pending.isEmpty ? null : _share(pending.first),
      acknowledge: (id) async {
        if (!failed) {
          failed = true;
          throw StateError('Synthetic acknowledgement failure');
        }
        expect(pending.removeAt(0), id);
      },
      onShare: (payload) => received.add(payload.text),
    );

    await inbox.check();
    await expectLater(inbox.complete(), throwsStateError);
    await inbox.check();

    expect(received, ['Synthetic first', 'Synthetic second']);
    expect(pending, ['second']);
  });

  test('skips an empty envelope without blocking subsequent shares', () async {
    final pending = <Object?>[
      {'id': 'missing-files', 'files': <Object?>[]},
      _share('valid'),
    ];
    final acknowledged = <String>[];
    final received = <String?>[];
    final inbox = ShareInbox(
      consume: () async => pending.isEmpty ? null : pending.first,
      acknowledge: (id) async {
        acknowledged.add(id);
        pending.removeAt(0);
      },
      onShare: (payload) => received.add(payload.text),
    );

    await inbox.check();

    expect(acknowledged, ['missing-files']);
    expect(received, ['Synthetic valid']);
  });

  test(
    'rechecks when a native event arrives during an empty consume',
    () async {
      final initial = Completer<Object?>();
      var consumes = 0;
      final received = <String?>[];
      final inbox = ShareInbox(
        consume: () {
          consumes++;
          return consumes == 1 ? initial.future : Future.value(_share('new'));
        },
        acknowledge: (_) async {},
        onShare: (payload) => received.add(payload.text),
      );

      final first = inbox.check();
      final second = inbox.check();
      initial.complete(null);
      await Future.wait([first, second]);

      expect(consumes, 2);
      expect(received, ['Synthetic new']);
    },
  );
}
