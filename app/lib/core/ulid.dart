import 'dart:math';

const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
final _rng = Random.secure();

/// A 26-character ULID: 48-bit millisecond timestamp + 80 random bits, Crockford
/// base32. Sorts by creation time and is safe to use as an idempotency key.
String newUlid({DateTime? now}) {
  var t = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final out = List<String>.filled(26, '');
  for (var i = 9; i >= 0; i--) {
    out[i] = _alphabet[t % 32];
    t ~/= 32;
  }
  for (var i = 10; i < 26; i++) {
    out[i] = _alphabet[_rng.nextInt(32)];
  }
  return out.join();
}
