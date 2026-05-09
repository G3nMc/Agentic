import 'dart:collection';

class CacheManager {
  final int maxSize;
  final Map<String, CacheEntry> _cache = {};
  final Queue<String> _queue = Queue();
  
  CacheManager({this.maxSize = 100});
  
  T? get<T>(String key) {
    final entry = _cache[key];
    if (entry == null) return null;
    
    // Check if entry is expired
    if (entry.expiry != null && DateTime.now().isAfter(entry.expiry!)) {
      _remove(key);
      return null;
    }
    
    return entry.value as T?;
  }
  
  void put<T>(String key, T value, {Duration? ttl}) {
    // Remove oldest entries if we're at max size
    while (_cache.length >= maxSize) {
      if (_queue.isNotEmpty) {
        final oldestKey = _queue.removeFirst();
        _remove(oldestKey);
      } else {
        break;
      }
    }
    
    final expiry = ttl != null ? DateTime.now().add(ttl) : null;
    final entry = CacheEntry(value, expiry);
    
    _cache[key] = entry;
    _queue.add(key);
  }
  
  bool contains(String key) {
    return _cache.containsKey(key);
  }
  
  void remove(String key) {
    _remove(key);
  }
  
  void _remove(String key) {
    _cache.remove(key);
    _queue.remove(key);
  }
  
  void clear() {
    _cache.clear();
    _queue.clear();
  }
  
  int get size => _cache.length;
}

class CacheEntry {
  final dynamic value;
  final DateTime? expiry;
  
  CacheEntry(this.value, this.expiry);
}