final class ProductResult<T> {
  const ProductResult._({
    required this.isSuccess,
    required this.code,
    required this.message,
    required this.retryable,
    this.data,
  });

  const ProductResult.success(T data)
    : this._(
        isSuccess: true,
        code: 'OK',
        message: '',
        retryable: false,
        data: data,
      );

  const ProductResult.failure({
    required String code,
    required String message,
    bool retryable = false,
  }) : this._(
         isSuccess: false,
         code: code,
         message: message,
         retryable: retryable,
       );

  final bool isSuccess;
  final String code;
  final String message;
  final bool retryable;
  final T? data;
}
