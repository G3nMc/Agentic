class CircuitBreaker {
  final int maxFailures;
  final Duration timeout;
  final Duration resetTimeout;
  
  int _failureCount = 0;
  DateTime? _lastFailureTime;
  bool _isOpen = false;
  
  CircuitBreaker({
    this.maxFailures = 5,
    this.timeout = const Duration(minutes: 1),
    this.resetTimeout = const Duration(minutes: 5),
  });
  
  bool get isOpen => _isOpen;
  
  Future<T> call<T>(Future<T> Function() operation) async {
    if (_isOpen) {
      if (DateTime.now().isAfter(_lastFailureTime!.add(resetTimeout))) {
        // Try to close the circuit
        _isOpen = false;
        _failureCount = 0;
      } else {
        throw CircuitBreakerOpenException();
      }
    }
    
    try {
      final result = await operation();
      // Reset failure count on success
      _failureCount = 0;
      return result;
    } catch (error) {
      _failureCount++;
      _lastFailureTime = DateTime.now();
      
      if (_failureCount >= maxFailures) {
        _isOpen = true;
      }
      
      rethrow;
    }
  }
}

class CircuitBreakerOpenException implements Exception {
  @override
  String toString() => 'Circuit breaker is open';
}