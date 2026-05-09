import 'dart:async';

class TaskQueue {
  final int concurrency;
  final Queue _queue = Queue();
  final List<Completer> _running = [];
  
  TaskQueue({this.concurrency = 5});
  
  Future<T> add<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    
    _queue.add(() async {
      try {
        final result = await task();
        completer.complete(result);
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    
    _process();
    return completer.future;
  }
  
  void _process() {
    while (_running.length < concurrency && _queue.isNotEmpty) {
      final task = _queue.removeFirst();
      final completer = Completer();
      _running.add(completer);
      
      task().whenComplete(() {
        _running.remove(completer);
        _process();
      });
    }
  }
}

class Queue {
  final List<Function> _items = [];
  
  void add(Function item) {
    _items.add(item);
  }
  
  Function removeFirst() {
    return _items.removeAt(0);
  }
  
  bool get isEmpty => _items.isEmpty;
  
  bool get isNotEmpty => _items.isNotEmpty;
  
  int get length => _items.length;
}