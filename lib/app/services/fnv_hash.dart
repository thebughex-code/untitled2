/// FNV-1a hash utility for generating deterministic cache keys from URLs.
class FnvHash {
  /// Compute FNV-1a 32-bit hash of [input].
  static int fnv1a(String input) {
    const int fnvPrime = 0x01000193;
    const int fnvOffset = 0x811c9dc5;
    int hash = fnvOffset;
    for (int i = 0; i < input.length; i++) {
      hash ^= input.codeUnitAt(i);
      hash = (hash * fnvPrime) & 0xFFFFFFFF;
    }
    return hash;
  }

  /// Return a hex string cache key for [url].
  static String hashUrl(String url) {
    return fnv1a(url).toRadixString(16).padLeft(8, '0');
  }
}
