abstract interface class IMethodData {
  String get methodName;
  Object? get methodReceiverId;
  Map<String, Object>? get methodParams;
}

class MethodData implements IMethodData {
  @override
  final String methodName;
  @override
  final Object? methodReceiverId;
  @override
  final Map<String, Object>? methodParams;

  MethodData(
    this.methodName, {
    this.methodReceiverId,
    this.methodParams,
  });
}
