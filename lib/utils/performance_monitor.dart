import 'dart:math';



class PerformanceMonitor {

  static final PerformanceMonitor _instance = PerformanceMonitor._internal();

  factory PerformanceMonitor() => _instance;

  PerformanceMonitor._internal();

  

  final Map<String, List<double>> _metrics = {};

  final Map<String, Stopwatch> _activeTimers = {};

  

  void startTimer(String operation) {

    _activeTimers[operation] = Stopwatch()..start();

  }

  

  void stopTimer(String operation) {

    final stopwatch = _activeTimers[operation];

    if (stopwatch != null) {

      stopwatch.stop();

      _recordMetric(operation, stopwatch.elapsedMilliseconds.toDouble());

      _activeTimers.remove(operation);

    }

  }

  

  void recordMetric(String operation, double value) {

    _recordMetric(operation, value);

  }

  

  void _recordMetric(String operation, double value) {

    if (!_metrics.containsKey(operation)) {

      _metrics[operation] = [];

    }

    _metrics[operation]!.add(value);

    

    // Keep only the last 1000 measurements to prevent memory leaks

    if (_metrics[operation]!.length > 1000) {

      _metrics[operation] = _metrics[operation]!.sublist(_metrics[operation]!.length - 1000);

    }

  }

  

  double? getAverage(String operation) {

    final metrics = _metrics[operation];

    if (metrics == null || metrics.isEmpty) return null;

    

    final sum = metrics.reduce((a, b) => a + b);

    return sum / metrics.length;

  }

  

  double? getMin(String operation) {

    final metrics = _metrics[operation];

    if (metrics == null || metrics.isEmpty) return null;

    

    return metrics.reduce(min);

  }

  

  double? getMax(String operation) {

    final metrics = _metrics[operation];

    if (metrics == null || metrics.isEmpty) return null;

    

    return metrics.reduce(max);

  }

  

  int getCount(String operation) {

    return _metrics[operation]?.length ?? 0;

  }

  

  void reset() {

    _metrics.clear();

  }

  

  Map<String, PerformanceMetrics> getAllMetrics() {

    final result = <String, PerformanceMetrics>{};

    _metrics.forEach((operation, metrics) {

      if (metrics.isNotEmpty) {

        final sum = metrics.reduce((a, b) => a + b);

        final average = sum / metrics.length;

        final minValue = metrics.reduce((a, b) => a < b ? a : b);

        final maxValue = metrics.reduce((a, b) => a > b ? a : b);

        

        result[operation] = PerformanceMetrics(

          count: metrics.length,

          average: average,

          min: minValue,

          max: maxValue,

        );

      }

    });

    return result;

  }

}



class PerformanceMetrics {

  final int count;

  final double average;

  final double min;

  final double max;

  

  PerformanceMetrics({

    required this.count,

    required this.average,

    required this.min,

    required this.max,

  });

}