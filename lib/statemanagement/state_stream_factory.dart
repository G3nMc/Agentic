import 'dart:async';

import 'package:flutter/foundation.dart';

import 'method_data.dart';

class StateStreamFactory {
  final int classTypeHashCode;

  StateStreamFactory._(this.classTypeHashCode);

  static final _stateStreamFactorySource = <int, StateStreamFactory>{};

  factory StateStreamFactory(int classId) => _stateStreamFactorySource.putIfAbsent(classId, () => StateStreamFactory._(classId));

  StreamController<IMethodData>? _streamController;
  final Set<StreamSubscription<IMethodData>> _subscriptions = {};

  void _ensureStream() {
    if (_streamController == null || _streamController!.isClosed) {
      _streamController = StreamController<IMethodData>.broadcast();
      if (kDebugMode) {
        print('StateStreamFactory: Created new stream for hash $classTypeHashCode');
      }
    }
  }

  StreamSubscription<IMethodData> addListener(void Function(IMethodData)? onData) {
    _ensureStream();

    final subscription = _streamController!.stream.listen(
      onData,
      onError: (error, stackTrace) {
        if (kDebugMode) {
          print('StateStreamFactory Error (hash $classTypeHashCode): $error\n$stackTrace');
        }
      },
      cancelOnError: false,
    );

    _subscriptions.add(subscription);

    if (kDebugMode) {
      print('StateStreamFactory: Added listener for hash $classTypeHashCode (total: ${_subscriptions.length})');
    }

    return subscription;
  }

  void addToStream(IMethodData event) {
    if (_streamController != null && !_streamController!.isClosed) {
      _streamController!.sink.add(event);

      if (kDebugMode) {
        print('StateStreamFactory: Event sent to hash $classTypeHashCode - ${event.methodName}');
      }
    } else {
      if (kDebugMode) {
        print('StateStreamFactory: Cannot send event, stream closed for hash $classTypeHashCode');
      }
    }
  }

  void removeListener(StreamSubscription<IMethodData> subscription) {
    subscription.cancel();
    _subscriptions.remove(subscription);

    if (kDebugMode) {
      print('StateStreamFactory: Removed listener for hash $classTypeHashCode (remaining: ${_subscriptions.length})');
    }

    if (_subscriptions.isEmpty) {
      if (_streamController != null && !_streamController!.isClosed) {
        _streamController!.close();
        _streamController = null;

        if (kDebugMode) {
          print('StateStreamFactory: Closed stream for hash $classTypeHashCode');
        }
      }

      _stateStreamFactorySource.remove(classTypeHashCode);

      if (kDebugMode) {
        print('StateStreamFactory: Removed factory for hash $classTypeHashCode from cache');
      }
    }
  }
}
