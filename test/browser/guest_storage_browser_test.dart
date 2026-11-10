@TestOn('browser')
library;

import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/live/browser_storage.dart';
import 'package:paul_demo/live/guest_preview.dart';
import 'package:paul_demo/live/live_bootstrap.dart';

@JS('eval')
external JSAny? _eval(JSString code);

void main() {
  setUp(
    () => _eval(
      '''
    globalThis.originalTabStorage = Object.getOwnPropertyDescriptor(window, 'sessionStorage');
  '''
          .toJS,
    ),
  );
  tearDown(
    () => _eval(
      '''
    if (originalTabStorage) Object.defineProperty(window, 'sessionStorage', originalTabStorage);
    else delete window.sessionStorage;
    delete globalThis.originalTabStorage;
  '''
          .toJS,
    ),
  );

  for (final failure in ['SecurityError', 'QuotaExceededError']) {
    test(
      'guest bootstrap survives $failure while storage adapter remains strict',
      () async {
        if (failure == 'SecurityError') {
          _eval(
            '''
          Object.defineProperty(window, 'sessionStorage', {configurable:true, get: () => {
            throw new DOMException('Synthetic blocked storage', 'SecurityError');
          }});
        '''
                .toJS,
          );
        } else {
          _eval(
            '''
          Object.defineProperty(window, 'sessionStorage', {configurable:true, value: {
            getItem: () => null,
            setItem: () => { throw new DOMException('Synthetic full storage', 'QuotaExceededError'); },
            removeItem: () => {}
          }});
        '''
                .toJS,
          );
        }
        final app = await buildLiveApp(
          url: 'https://test.supabase.co',
          key: 'test-key',
          appUrl: 'https://paul.example',
        );
        expect(app, isA<GuestUnavailableApp>());
        expect(
          (app as GuestUnavailableApp).message,
          contains('Browser storage is unavailable.'),
        );
        expect(
          () => writeSessionValue('synthetic-journal', 'synthetic-pending-id'),
          throwsA(anything),
        );
        if (failure == 'SecurityError') {
          expect(
            () => readSessionValue('synthetic-journal'),
            throwsA(anything),
          );
        }
      },
    );
  }
}
