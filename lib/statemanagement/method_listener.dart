import 'method_data.dart';
import 'state_stream_factory.dart';

abstract interface class IMethodListener<T> {
  Future<void> callMethod(String methodName, {Object? receiverId, Map<String, Object>? params});
}

class MethodListener<T> implements IMethodListener<T> {
  MethodListener._();

  static final _methodListener = <int, MethodListener>{};

  factory MethodListener() => _methodListener.putIfAbsent(T.hashCode, () => MethodListener<T>._()) as MethodListener<T>;

  @override
  Future<void> callMethod(String methodName, {Object? receiverId, Map<String, Object>? params}) async =>
      StateStreamFactory(T.hashCode).addToStream(MethodData(methodName, methodReceiverId: receiverId, methodParams: params));
}
