import 'dart:math';

class RetryHandler {
  final int maxRetries;
  final Duration baseDelay;
  final Duration maxDelay;
  final double jitterFactor;
  
  RetryHandler({
    this.maxRetries = 3,
    this.baseDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.jitterFactor = 0.3,
  });
  
  Future<T> executeWithRetry<T>(Future<T> Function() operation) async {
    int attempt = 0;
    Exception? lastException;
    
    while (attempt <= maxRetries) {
      try {
        return await operation();
      } catch (e) {
        lastException = e as Exception;
        attempt++;
        
        if (attempt > maxRetries) {
          break;
        }
        
        // Calculate delay with exponential backoff
        final delay = _calculateDelay(attempt);
        await Future.delayed(delay);
      }
    }
    
    throw lastException!;
  }
  
  Duration _calculateDelay(int attempt) {
    // Exponential backoff: baseDelay * 2^(attempt-1)
    final delayMillis = baseDelay.inMilliseconds * pow(2, attempt - 1).toInt();
    final delay = Duration(milliseconds: delayMillis);
    
    // Cap at maxDelay
    final cappedDelay = delay > maxDelay ? maxDelay : delay;
    
    // Add jitter
    final jitterRange = (cappedDelay.inMilliseconds * jitterFactor).toInt();
    final jitter = Random().nextInt(jitterRange * 2) - jitterRange;
    
    return Duration(milliseconds: (cappedDelay.inMilliseconds + jitter).clamp(0, maxDelay.inMilliseconds));
  }
}