import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../utils/fnv_hash.dart';
import '../services/logger_service.dart';

/// LRU cache with both in-memory (fast) and on-disk (persistent) tiers.
///
/// - Memory tier: up to [maxMemoryEntries] segments (default 50).
/// - Disk tier:   up to [maxDiskCacheBytes] bytes (default 500 MB).
///
/// Both tiers use LRU eviction – the least-recently-used entry is removed
/// first when the tier is full.
class SegmentCache {
  // ---------------------------------------------------------------------------
  // Configuration
  // ---------------------------------------------------------------------------
  static const int maxDiskCacheBytes = 100 * 1024 * 1024; // 100 MB (Lightweight)
  static const int maxMemoryEntries = 50;

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  late String _cacheDir;
  int _currentDiskSize = 0;
  bool _initialized = false;

  /// Disk LRU tracker: key → size-in-bytes, ordered oldest → newest.
  final LinkedHashMap<String, int> _diskEntries = LinkedHashMap<String, int>();

  /// Memory LRU cache: key → raw bytes, ordered oldest → newest.
  final LinkedHashMap<String, Uint8List> _memoryCache =
      LinkedHashMap<String, Uint8List>();

  // ---------------------------------------------------------------------------
  // Initialisation
  // ---------------------------------------------------------------------------

  /// Must be called once before any [get] / [put] operations.
  Future<void> init() async {
    if (_initialized) return;
    final dir = await getTemporaryDirectory();
    _cacheDir = '${dir.path}/hls_cache';
    await Directory(_cacheDir).create(recursive: true);
    await _scanExistingCache();
    _initialized = true;
  }

  /// Walk the disk cache directory and repopulate [_diskEntries].
  ///
  /// - Deletes files older than 7 days.
  /// - Sorts remaining files by `lastModified` (Ascending = Oldest first) so LRU works.
  Future<void> _scanExistingCache() async {
    final dir = Directory(_cacheDir);
    if (!await dir.exists()) return;

    final List<File> files = [];
    final now = DateTime.now();
    final expiryLimit = now.subtract(const Duration(days: 7));
    int deletedCount = 0;

    await for (final entity in dir.list()) {
      if (entity is File) {
        try {
          final stat = await entity.stat();
          
          // 1. Check Expiry
          if (stat.modified.isBefore(expiryLimit)) {
            await entity.delete();
            deletedCount++;
            continue;
          }

          files.add(entity);
        } catch (e) {
          LoggerService.w('[SegmentCache] Failed to stat/delete file: ${entity.path}');
        }
      }
    }

    if (deletedCount > 0) {
      LoggerService.i('[SegmentCache] Cleaned up $deletedCount expired files (older than 7 days).');
    }

    // 2. Sort by Last Modified (Oldest first)
    // This is crucial so _diskEntries has the correct eviction order.
    files.sort((a, b) {
      // We need synchronous stat here ideally, but we already got it async above.
      // To keep it simple and robust, we'll re-stat synchronously or rely on
      // the fact that we just listed them.
      // Better: Store stats in a temporary tuple list.
      // Refactoring slightly to use a helper class for sorting would be cleaner
      // but let's do sync stat for simplicity in sorting function, or assume valid.
      return a.lastModifiedSync().compareTo(b.lastModifiedSync());
    });

    // 3. Populate LRU Map
    for (final file in files) {
      final name = file.path.split(Platform.pathSeparator).last;
      final size = file.lengthSync();
      _diskEntries[name] = size;
      _currentDiskSize += size;
    }
    
    LoggerService.i(
      '[SegmentCache] Initialized. Disk usage: ${(_currentDiskSize / 1024 / 1024).toStringAsFixed(2)} MB. Files: ${files.length}'
    );
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  String _keyForUrl(String url) => FnvHash.hashUrl(url);

  /// Retrieve bytes for [url], or `null` if not cached.
  ///
  /// Promotes the entry in both memory and disk LRU lists.
  Future<Uint8List?> get(String url) async {
    final key = _keyForUrl(url);

    // 1. Check memory
    if (_memoryCache.containsKey(key)) {
      final data = _memoryCache.remove(key)!;
      _memoryCache[key] = data; // move to newest position
      return data;
    }

    // 2. Check disk
    final file = File('$_cacheDir/$key');
    if (await file.exists()) {
      try {
        // Touch file so it remains "fresh" on next app launch
        // (Wait for it? Maybe fire and forget to not block UI)
        file.setLastModified(DateTime.now()).catchError((_) {});

        final data = await file.readAsBytes();
        _addToMemoryCache(key, data);
        
        // Promote in disk LRU tracker
        if (_diskEntries.containsKey(key)) {
          final size = _diskEntries.remove(key)!;
          _diskEntries[key] = size;
        }
        return data;
      } catch (e) {
        LoggerService.e('[SegmentCache] Error reading $key: $e');
        return null;
      }
    }

    return null;
  }

  /// Store [data] under [url] in both memory and disk caches.
  Future<void> put(String url, Uint8List data) async {
    final key = _keyForUrl(url);
    _addToMemoryCache(key, data);
    await _addToDiskCache(key, data);
  }

  /// Quick check (no I/O) – returns `true` if [url] is in memory or tracked
  /// on disk.
  bool containsKey(String url) {
    final key = _keyForUrl(url);
    return _memoryCache.containsKey(key) || _diskEntries.containsKey(key);
  }

  /// Total bytes currently on disk.
  int get currentDiskSize => _currentDiskSize;

  /// Total entries in memory.
  int get memoryEntryCount => _memoryCache.length;

  // ---------------------------------------------------------------------------
  // Memory LRU helpers
  // ---------------------------------------------------------------------------

  void _addToMemoryCache(String key, Uint8List data) {
    _memoryCache.remove(key); // remove to re-insert at end
    _memoryCache[key] = data;

    // Evict oldest until within limit
    while (_memoryCache.length > maxMemoryEntries) {
      _memoryCache.remove(_memoryCache.keys.first);
    }
  }

  // ---------------------------------------------------------------------------
  // Disk LRU helpers
  // ---------------------------------------------------------------------------

  Future<void> _addToDiskCache(String key, Uint8List data) async {
    final path = '$_cacheDir/$key';
    final tmpPath = '$path.tmp';
    final file = File(path);
    final tmpFile = File(tmpPath);

    try {
      // Ensure the cache directory still exists (OS may wipe temp dirs)
      await Directory(_cacheDir).create(recursive: true);
      // Atomic write: Write to .tmp then rename
      await tmpFile.writeAsBytes(data, flush: true);
      await tmpFile.rename(path);
    } catch (e) {
      LoggerService.e('[SegmentCache] Atomic write failed for $key: $e');
      try { await tmpFile.delete(); } catch (_) {}
      return; 
    }

    // Book-keeping
    if (_diskEntries.containsKey(key)) {
      _currentDiskSize -= _diskEntries[key]!;
      _diskEntries.remove(key);
    }
    _diskEntries[key] = data.length;
    _currentDiskSize += data.length;

    // Evict oldest entries until under limit
    while (_currentDiskSize > maxDiskCacheBytes && _diskEntries.isNotEmpty) {
      final oldestKey = _diskEntries.keys.first;
      final oldestSize = _diskEntries[oldestKey]!;
      _diskEntries.remove(oldestKey);
      _currentDiskSize -= oldestSize;
      
      // Also remove from memory if present (optional but good for consistency)
      _memoryCache.remove(oldestKey);
      
      try {
        await File('$_cacheDir/$oldestKey').delete();
        LoggerService.v('[SegmentCache] Evicted $oldestKey (Size: $oldestSize bytes)');
      } catch (e) {
        LoggerService.w('[SegmentCache] Failed to delete evicted file $oldestKey: $e');
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Maintenance
  // ---------------------------------------------------------------------------

  /// Wipe everything (both tiers).
  Future<void> clear() async {
    _memoryCache.clear();
    _diskEntries.clear();
    _currentDiskSize = 0;
    try {
      final dir = Directory(_cacheDir);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
        await dir.create(recursive: true);
      }
    } catch (_) {}
  }
}
