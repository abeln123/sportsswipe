import 'dart:js_interop';

@JS('sportsSwipeWallet.connect')
external JSPromise<JSString> _connect();
@JS('sportsSwipeWallet.signMessage')
external JSPromise<JSString> _signMessage(JSString message);
@JS('sportsSwipeWallet.signTransaction')
external JSPromise<JSString> _signTransaction(JSString transaction);
Future<String> connectCollectibleWallet() async => (await _connect().toDart).toDart;
Future<String> signCollectibleMessage(String message) async => (await _signMessage(message.toJS).toDart).toDart;
Future<String> signCollectibleTransaction(String transaction) async => (await _signTransaction(transaction.toJS).toDart).toDart;
