import 'dart:js_interop';

import 'collectible_wallet_stub.dart' as fallback;

@JS('sportsSwipeWallet.connect')
external JSPromise<JSString> _connect();
@JS('sportsSwipeWallet.signMessage')
external JSPromise<JSString> _signMessage(JSString message);
@JS('sportsSwipeWallet.signTransaction')
external JSPromise<JSString> _signTransaction(JSString transaction);

bool _useFallback = false;

Future<String> connectCollectibleWallet() async {
  try {
    final addr = (await _connect().toDart).toDart;
    _useFallback = false;
    return addr;
  } catch (_) {
    _useFallback = true;
    return fallback.connectCollectibleWallet();
  }
}

Future<String> signCollectibleMessage(String message) async {
  if (_useFallback) return fallback.signCollectibleMessage(message);
  return (await _signMessage(message.toJS).toDart).toDart;
}

Future<String> signCollectibleTransaction(String transaction) async {
  if (_useFallback) return fallback.signCollectibleTransaction(transaction);
  return (await _signTransaction(transaction.toJS).toDart).toDart;
}
