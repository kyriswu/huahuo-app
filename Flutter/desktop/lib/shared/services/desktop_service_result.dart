enum DesktopServiceResultKind { success, unavailable, queued, failure }

final class DesktopServiceResult<T> {
  const DesktopServiceResult._({
    required this.kind,
    required this.code,
    required this.message,
    required this.retryable,
    this.data,
  });

  const DesktopServiceResult.success(T data)
    : this._(
        kind: DesktopServiceResultKind.success,
        code: 'OK',
        message: '',
        retryable: false,
        data: data,
      );

  const DesktopServiceResult.unavailable({
    String code = 'DESKTOP_SERVICE_UNAVAILABLE',
    String message = '服务尚未配置',
  }) : this._(
         kind: DesktopServiceResultKind.unavailable,
         code: code,
         message: message,
         retryable: false,
       );

  const DesktopServiceResult.queued({
    required T data,
    String code = 'DESKTOP_OPERATION_QUEUED',
    String message = '操作已保存在本地队列',
  }) : this._(
         kind: DesktopServiceResultKind.queued,
         code: code,
         message: message,
         retryable: true,
         data: data,
       );

  const DesktopServiceResult.failure({
    required String code,
    required String message,
    bool retryable = false,
    T? data,
  }) : this._(
         kind: DesktopServiceResultKind.failure,
         code: code,
         message: message,
         retryable: retryable,
         data: data,
       );

  final DesktopServiceResultKind kind;
  final T? data;
  final String code;
  final String message;
  final bool retryable;

  bool get isSuccess => kind == DesktopServiceResultKind.success;
  bool get isUnavailable => kind == DesktopServiceResultKind.unavailable;
  bool get isQueued => kind == DesktopServiceResultKind.queued;
  bool get isFailure => kind == DesktopServiceResultKind.failure;
}
