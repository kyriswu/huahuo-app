enum V3DocumentImportPhase {
  preparingFile('准备文件', '正在保存并校验本地文件。'),
  requestingUpload('申请上传', '正在向服务器申请文件上传凭证。'),
  uploading('上传文件', '正在上传文件，大文件所需时间取决于网络速度。'),
  confirmingUpload('确认上传', '正在核验服务器接收的文件。'),
  creatingIngestion('提交解析任务', '文件已上传，正在申请解析；尚未确认任务受理。'),
  checkingIngestion('查询解析状态', '正在查询已受理任务的状态，不会重复上传文件。'),
  parsing('解析文件', '服务器已受理，正在解析文件内容。'),
  creatingNote('生成笔记', '文件解析已完成，正在保存原始笔记。'),
  synchronizingNote('同步笔记', '云端笔记已生成，正在同步到资产库。'),
  queuingDistillation('保存沉淀任务', '笔记已生成，正在保存数字孪生沉淀任务。'),
  completed('导入完成', '笔记已保存，可在资产库查看。');

  const V3DocumentImportPhase(this.label, this.message);

  final String label;
  final String message;
}

bool documentImportRequiresReselection(String? code) => const <String>{
  'DOCUMENT_PICKER_UNSUPPORTED_FILE',
  'DOCUMENT_IMPORT_TYPE_UNSUPPORTED',
  'DOCUMENT_IMPORT_FILE_EMPTY',
  'DOCUMENT_IMPORT_SIZE_INVALID',
  'DOCUMENT_IMPORT_FILE_TOO_LARGE',
  'DOCUMENT_BODY_SOURCE_UNAVAILABLE',
  'DOCUMENT_IMPORT_SOURCE_MUTATED',
  'DOCUMENT_IMPORT_HASH_INVALID',
  'DOCUMENT_IMPORT_COPY_INTEGRITY_FAILED',
  'DOCUMENT_IMPORT_PRIVATE_FILE_MISSING',
  'DOCUMENT_IMPORT_PRIVATE_REF_INVALID',
  'DOCUMENT_IMPORT_PRIVATE_FILE_CONFLICT',
  'DOCUMENT_IMPORT_PRIVATE_HASH_MISMATCH',
  'DOCUMENT_IMPORT_PRIVATE_SIZE_MISMATCH',
  'UPLOAD_FILE_TOO_LARGE',
  'UPLOAD_MIME_UNSUPPORTED',
  'UPLOAD_OBJECT_SIZE_MISMATCH',
  'UPLOAD_OBJECT_MISMATCH',
  'NOTE_INGESTION_UNSUPPORTED',
  'NOTE_INGESTION_QUARANTINED',
  'NOTE_INGESTION_NOT_FOUND',
  'NOTE_INGESTION_EXPIRED',
  'DOCUMENT_INGESTION_EXPIRED',
  'DOCUMENT_INGESTION_CANCELLED',
  'DOCUMENT_INGESTION_REMOTE_FAILED',
}.contains(code);

bool documentImportCanResumeAfterIntervention(String? code) => const <String>{
  'AUTH_SESSION_EXPIRED',
  'AUTH_UNAUTHORIZED',
  'AUTH_REQUIRED',
  'AUTH_TOKEN_EXPIRED',
  'AUTH_TOKEN_INVALID',
  'UNAUTHORIZED',
  'TOKEN_EXPIRED',
  'PERMISSION_DENIED',
  'FORBIDDEN',
  'WORKSPACE_ACCESS_DENIED',
  'WORKSPACE_FORBIDDEN',
  'WORKSPACE_WRITE_FORBIDDEN',
}.contains(code);

String documentImportErrorMessage(String? code) => switch (code) {
  'DOCUMENT_PICKER_UNSUPPORTED_FILE' || 'DOCUMENT_IMPORT_TYPE_UNSUPPORTED' =>
    '格式不支持，请选择 TXT、Markdown、CSV、JSON、PDF、DOCX、PPTX 或 XLSX。',
  'DOCUMENT_IMPORT_FILE_EMPTY' => '文件为空，请选择有内容的文件。',
  'DOCUMENT_IMPORT_FILE_TOO_LARGE' ||
  'DOCUMENT_IMPORT_SIZE_INVALID' => '文件超过大小限制，请选择不超过 100 MB 的文件。',
  'UPLOAD_FILE_TOO_LARGE' =>
    '服务器拒绝了此文件的大小。客户端支持 100 MB，但当前服务端限制尚未满足；请联系管理员或选择更小的文件。',
  'DOCUMENT_BODY_SOURCE_UNAVAILABLE' ||
  'DOCUMENT_IMPORT_PRIVATE_FILE_MISSING' => '无法读取文件，请先将云端文件下载到本机，再重新选择原文件。',
  'DOCUMENT_IMPORT_SOURCE_MUTATED' ||
  'DOCUMENT_IMPORT_HASH_INVALID' ||
  'DOCUMENT_IMPORT_COPY_INTEGRITY_FAILED' ||
  'DOCUMENT_IMPORT_PRIVATE_REF_INVALID' ||
  'DOCUMENT_IMPORT_PRIVATE_FILE_CONFLICT' ||
  'DOCUMENT_IMPORT_PRIVATE_HASH_MISMATCH' ||
  'DOCUMENT_IMPORT_PRIVATE_SIZE_MISMATCH' => '文件已变化或完整性校验失败，请重新选择原文件。',
  'DOCUMENT_IMPORT_STORAGE_FULL' => '设备存储空间不足，请释放空间后重试。',
  'DOCUMENT_IMPORT_FILE_ACCESS_DENIED' => '无法访问文件，请检查文件权限后重新选择。',
  'DOCUMENT_IMPORT_STAGE_FAILED' => '本地文件准备失败，请检查可用存储空间后重新选择。',
  'DOCUMENT_IMPORT_ACCEPT_PERSIST_FAILED' => '导入任务未能安全保存，尚未提交服务器，请检查存储空间后重试。',
  'DOCUMENT_IMPORT_CHECKPOINT_PERSIST_FAILED' ||
  'DOCUMENT_IMPORT_NOTE_PERSIST_FAILED' => '本地进度保存失败，请检查存储空间后重试；已确认的云端结果会继续复用。',
  'WORKSPACE_CONTEXT_UNAVAILABLE' ||
  'WORKSPACE_NOT_READY' => '工作空间尚未就绪，请登录并完成初始化后重试。',
  'AUTH_SESSION_EXPIRED' ||
  'AUTH_UNAUTHORIZED' ||
  'AUTH_REQUIRED' ||
  'AUTH_TOKEN_EXPIRED' ||
  'AUTH_TOKEN_INVALID' ||
  'UNAUTHORIZED' ||
  'TOKEN_EXPIRED' => '登录状态已失效，请重新登录后继续。',
  'PERMISSION_DENIED' ||
  'FORBIDDEN' ||
  'WORKSPACE_ACCESS_DENIED' ||
  'WORKSPACE_FORBIDDEN' ||
  'WORKSPACE_WRITE_FORBIDDEN' => '当前账号没有访问权限，请确认登录账号和工作空间。',
  'IDEMPOTENCY_KEY_CONFLICT' => '导入请求标识冲突，服务器未受理本次操作，请联系管理员核查，不要反复提交。',
  'RATE_LIMITED' ||
  'TOO_MANY_REQUESTS' ||
  'API_RATE_LIMITED' => '请求过于频繁，请稍后继续。',
  'UPLOAD_TOKEN_EXPIRED' => '上传凭证已失效，重试会申请新凭证并重新上传。',
  'UPLOAD_OBJECT_TIMEOUT' => '文件上传超时，本次传输已停止，请检查网络后重试。',
  'UPLOAD_OBJECT_FAILED' ||
  'UPLOAD_OBJECT_HTTP_ERROR' ||
  'DOCUMENT_UPLOAD_FAILED' => '文件上传失败，请检查网络后重试。',
  'UPLOAD_OBJECT_SIZE_MISMATCH' ||
  'UPLOAD_OBJECT_MISMATCH' => '服务器收到的文件与本地文件不一致，请重新选择原文件。',
  'UPLOAD_MIME_UNSUPPORTED' ||
  'NOTE_INGESTION_UNSUPPORTED' => '服务器暂不支持此文件格式，请选择其他格式或联系管理员。',
  'DOCUMENT_UPLOAD_TOKEN_INCOMPLETE' ||
  'DOCUMENT_UPLOAD_RESOURCE_MISMATCH' => '服务器返回的上传回执不完整或不匹配，已停止后续导入，请重试或联系管理员。',
  'DOCUMENT_UPLOAD_COMPLETE_FAILED' => '上传结果确认失败，重试会先核验已上传文件。',
  'NOTE_INGESTION_QUARANTINED' => '文件未通过服务器安全或内容校验，解析已停止，请检查文件是否损坏、加密或格式异常。',
  'DOCUMENT_INGESTION_EXPIRED' ||
  'NOTE_INGESTION_EXPIRED' ||
  'NOTE_INGESTION_NOT_FOUND' => '解析任务已过期或不存在，请重新选择文件发起导入。',
  'DOCUMENT_INGESTION_CANCELLED' => '解析任务已取消，如需导入请重新选择文件。',
  'DOCUMENT_INGESTION_REMOTE_FAILED' => '服务器解析失败，任务已停止，请检查文件或联系管理员。',
  'DOCUMENT_INGESTION_TIMEOUT' => '服务器已受理，但本次查询等待已结束。可以离开，稍后继续查询，不会重复上传。',
  'DOCUMENT_INGESTION_POLL_FAILED' => '暂时无法查询解析结果，任务已保留，请检查网络后继续查询。',
  'DOCUMENT_INGESTION_RESPONSE_INVALID' ||
  'DOCUMENT_INGESTION_ID_MISMATCH' ||
  'DOCUMENT_INGESTION_STATUS_INVALID' => '服务器返回的解析状态异常，已停止等待，请重试查询或联系管理员。',
  'DOCUMENT_INGESTION_PROMOTE_FAILED' => '解析结果尚未保存为笔记，重试将继续保存，不会重新上传。',
  'DOCUMENT_REMOTE_NOTE_UNAVAILABLE' => '云端笔记已生成，但资产库同步失败，请重试同步，不会重新上传或生成笔记。',
  'DIGITAL_TWIN_QUEUE_SAVE_FAILED' => '笔记已生成，但沉淀任务保存失败，请重试保存，不会重复导入笔记。',
  'DOCUMENT_IMPORT_INTERRUPTED' => '上次操作已中断，进度已保留，点击重试从已确认的阶段继续。',
  'DOCUMENT_ANALYSIS_SERVICE_UNAVAILABLE' => '文档分析服务暂不可用，请稍后重试。',
  'INTERNAL_ERROR' ||
  'API_SERVER_UNAVAILABLE' => '服务器处理请求失败，请稍后重试；重复失败时请联系管理员。',
  'NETWORK_REQUEST_FAILED' ||
  'NETWORK_UNAVAILABLE' ||
  'NETWORK_ERROR' ||
  'REQUEST_TIMEOUT' ||
  'API_TIMEOUT' => '网络连接失败或请求超时，请检查网络后继续。',
  'API_REQUEST_CANCELLED' => '请求已中断，进度已保留，可稍后继续。',
  'API_RESPONSE_INVALID' => '服务器返回的数据不完整，请重试或联系管理员。',
  'DOCUMENT_INGESTION_CREATE_FAILED' => '提交解析任务失败，尚未确认服务器受理；重试会复用已上传文件。',
  'DOCUMENT_UPLOAD_TOKEN_FAILED' => '申请上传凭证失败，请检查网络后重试。',
  'DIGITAL_TWIN_DISTILLATION_RECEIPT_MISSING' =>
    '服务器未返回沉淀任务回执，请重试确认上传结果或联系管理员。',
  'DOCUMENT_IMPORT_PRIVATE_VERIFY_FAILED' => '无法校验本地文件，请检查文件权限和存储空间后重试。',
  'DOCUMENT_PICKER_SOURCE_UNAVAILABLE' => '无法读取所选文件，请先下载到本机再选择。',
  'NATIVE_DOCUMENT_PICKER_UNAVAILABLE' => '当前设备暂不支持本地文件选择。',
  'NATIVE_DOCUMENT_PICKER_FAILED' => '打开文件选择器失败，请重新选择。',
  _ => '当前步骤未完成，进度已保留。请重试；重复失败时请提供错误码联系管理员。',
};
