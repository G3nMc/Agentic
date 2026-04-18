import 'dart:async';
import 'dart:developer';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'method_data.dart';
import 'method_listener.dart';
import 'state_stream_factory.dart';

abstract class IStateManager<W extends StatefulWidget> extends State<W> {
  void onMethodListener(MethodData methodData);
  Object? get methodListenerId;
  void attachListener();
  void detachListener();

  @override
  void initState() {
    super.initState();
    attachListener();
  }

  @override
  void dispose() {
    detachListener();
    super.dispose();
  }
}

abstract class StateManager<T extends StatefulWidget> extends IStateManager<T> {
  StreamSubscription<IMethodData>? _subscription;

  void _methodListener(IMethodData methodData) {
    final Object? receiverId = methodData.methodReceiverId;
    final bool fire = receiverId == null || receiverId == methodListenerId;
    final bool isOK = methodData is MethodData;

    if (mounted && isOK && fire) {
      setState(() {
        onMethodListener(methodData);
      });
    }
  }

  IMethodListener<L> getStateListener<L>() => MethodListener<L>();

  @override
  Object? get methodListenerId => null;

  int get _classTypeHashCode => widget.runtimeType.hashCode;

  @override
  void attachListener() {
    if (_subscription != null) {
      if (kDebugMode) {
        log("WARNING: Listener already attached for $_classTypeHashCode (${widget.runtimeType})");
      }
      return;
    }

    if (kDebugMode) {
      log("attachListener _classTypeHashCode $_classTypeHashCode (${widget.runtimeType})");
    }

    _subscription = StateStreamFactory(_classTypeHashCode).addListener(_methodListener);
  }

  @override
  void detachListener() {
    if (_subscription == null) {
      if (kDebugMode) {
        log("WARNING: Attempted to detach listener that was not attached for $_classTypeHashCode");
      }
      return;
    }

    if (kDebugMode) {
      log("detachListener _classTypeHashCode $_classTypeHashCode (${widget.runtimeType})");
    }

    StateStreamFactory(_classTypeHashCode).removeListener(_subscription!);
    _subscription = null;
  }
}
