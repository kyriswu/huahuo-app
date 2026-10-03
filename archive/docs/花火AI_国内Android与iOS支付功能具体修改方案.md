# 花火 AI 国内 Android 与 iOS 支付功能改造方案

> 适用仓库：`Xieyangzai/Flutter`  
> 适用分支：`Flutter-UI`  
> Flutter 工程目录：`Flutter/src/`  
> 方案日期：2026-08-02  
> 支付范围：国内 Android（微信支付、支付宝）+ 国内 iOS（Apple App Store 应用内购买）

---

## 1. 改造目标

在保留当前“会员与额度”页面视觉设计的基础上，将演示功能改造成真实支付能力：

- 国内 Android：
  - 微信 APP 支付；
  - 支付宝 APP 支付；
  - 第一版采用一次性期限会员，不做微信/支付宝自动代扣；
  - 支付完成后由后端确认订单并发放会员权益。
- 国内 iOS：
  - 使用 Apple App Store In-App Purchase；
  - 使用自动续订订阅；
  - 支持恢复购买、续订、取消续订、退款和订阅状态同步。
- 账号权益：
  - Android 与 iOS 使用同一花火账号体系；
  - 用户在任一平台购买后，登录另一平台仍可读取对应会员权益；
  - 客户端不直接修改会员状态，后端是唯一事实源。
- 安全目标：
  - 微信商户密钥、支付宝应用私钥、Apple 服务端密钥不得进入 App；
  - 客户端支付回调不能作为会员开通依据；
  - 所有订单、回调、验单和权益发放必须幂等。

---

## 2. 当前工程状态

当前 `Flutter-UI` 分支已经具备以下基础：

- Flutter 3.44 / Dart 3.12 工程；
- Riverpod 状态管理；
- GoRouter 路由；
- `ApiClient`、`EndpointCatalog`、幂等请求机制；
- 稳定设备 ID；
- 登录会话和安全 token；
- “会员与额度”页面；
- 当前会员、额度、套餐、协议勾选和支付按钮 UI。

但支付部分仍是演示状态：

- `v3_profile_side_panel.dart` 内的会员页面硬编码了价格和权益；
- 点击“立即支付”只显示“支付服务尚未接入”；
- `profileMembershipPortProvider` 使用 `ProfileMembershipDemoPort`；
- 页面价格与 DemoPort 价格不一致；
- `EndpointCatalog` 只有 `GET /api/v1/membership`；
- 没有订单创建、订单查询、Apple 验单和支付记录接口；
- `pubspec.yaml` 没有应用内购买依赖；
- Android 没有微信、支付宝原生支付桥接；
- Android 正式构建仍使用 Debug 签名。

---

## 3. 最终产品设计

### 3.1 内部统一 SKU

建议第一版固定三种内部商品：

| 内部 SKU | 会员等级 | Android 商品 | iOS 商品 |
|---|---|---|---|
| `pro_30d` | PRO | 购买 30 天 | PRO 连续包月 |
| `pro_365d` | PRO | 购买 365 天 | PRO 连续包年 |
| `max_365d` | MAX | 购买 365 天 | MAX 连续包年 |

### 3.2 iOS App Store Product ID

使用当前 iOS Bundle ID：

```text
com.hangzhouchuda.huahuoai
```

建议 App Store Connect 商品 ID：

```text
com.hangzhouchuda.huahuoai.pro.monthly
com.hangzhouchuda.huahuoai.pro.annual
com.hangzhouchuda.huahuoai.max.annual
```

三个商品放在同一个自动续订订阅组中。

### 3.3 Android 购买规则

Android 第一版不做自动续费：

- PRO 30 天；
- PRO 365 天；
- MAX 365 天；
- 支付前显示微信支付、支付宝两种方式；
- 页面不得显示“连续包月”“自动续费”；
- 页面协议只显示会员服务协议、购买说明和退款说明。

### 3.4 跨平台权益规则

后端保存独立权益记录，计算“当前有效会员”时采用：

1. 只考虑状态为 `active`、`grace_period` 的权益；
2. 会员等级优先级：`MAX > PRO > FREE`；
3. 同等级取到期时间最晚的权益；
4. Android 购买 MAX 时，原有 PRO 权益不删除；
5. MAX 到期后，如果原 PRO 仍未到期，可继续恢复为 PRO；
6. iOS 订阅状态以 Apple 服务端通知和服务端验单为准。

---

## 4. 目录结构调整

新增正式 Billing 模块：

```text
Flutter/src/lib/features/billing/
├── domain/
│   ├── billing_product.dart
│   ├── payment_order.dart
│   ├── purchase_result.dart
│   └── membership_entitlement.dart
├── data/
│   ├── billing_api.dart
│   └── membership_api.dart
├── infrastructure/
│   ├── ios_store_purchase_port.dart
│   ├── app_store_purchase_service.dart
│   ├── android_payment_port.dart
│   └── method_channel_android_payment.dart
├── application/
│   ├── billing_controller.dart
│   └── billing_runtime_coordinator.dart
└── presentation/
    └── v3_membership_page.dart
```

Android 原生新增：

```text
Flutter/src/android/app/src/main/kotlin/<最终包名>/
├── PaymentBridge.kt
├── PaymentContract.kt
└── wxapi/
    └── WXPayEntryActivity.kt
```

后端新增逻辑模块：

```text
billing/
├── catalog
├── orders
├── providers/
│   ├── wechat
│   ├── alipay
│   └── apple
├── entitlements
├── callbacks
└── reconciliation
```

---

## 5. 现有 Flutter 文件修改清单

### 5.1 `Flutter/src/pubspec.yaml`

增加 iOS 官方应用内购买插件：

```yaml
dependencies:
  in_app_purchase: 3.3.0
```

说明：

- 本项目只在 iOS 使用该插件；
- 国内 Android 不使用 Google Play Billing；
- 当前插件支持 iOS 13+，与当前工程部署目标兼容；
- 版本固定为 `3.3.0`，不要在首个支付版本中使用浮动大版本。

执行：

```bash
cd Flutter/src
flutter pub get
```

### 5.2 `lib/features/ui_v3/presentation/v3_profile_side_panel.dart`

删除以下内容：

- `_V3MembershipPage`；
- `_V3MembershipPageState`；
- `_MembershipPlan`；
- `_MembershipBilling`；
- `_MembershipPlanCard`；
- 页面内硬编码价格；
- `section == '会员充值'` 的特殊分支。

侧边栏入口由：

```dart
_goPlaceholder(context, '会员充值')
```

改为：

```dart
_go(context, '/v3/profile/membership')
```

### 5.3 `lib/app/navigation/app_router.dart`

新增明确路由：

```dart
GoRoute(
  path: '/v3/profile/membership',
  builder: (context, state) => const V3MembershipPage(),
),
```

增加 import：

```dart
import '../../features/billing/presentation/v3_membership_page.dart';
```

路由位置建议放在 `/v3/profile/account` 附近。

### 5.4 `lib/features/ui_v3/data/profile_capability_ports.dart`

删除或停止使用：

```dart
final profileMembershipPortProvider = Provider<ProfileMembershipPort>(
  (ref) => ProfileMembershipDemoPort(),
);
```

删除演示会员商品和演示额度，改由 Billing 模块从后端加载。

`ProfileAccountSecurityPort`、`ProfileSupportPort` 等其他能力暂不改动。

### 5.5 `lib/features/ui_v3/domain/profile_capability_models.dart`

会员相关类型迁移到：

```text
lib/features/billing/domain/
```

旧类型如被其他页面引用，可暂时保留兼容层，但不得继续保存价格或支付状态。

### 5.6 `lib/app/bootstrap/app_providers.dart`

增加：

```dart
final billingApiProvider = Provider<BillingApiPort>((ref) {
  return BillingApi(apiClient: ref.watch(apiClientProvider));
});

final membershipApiProvider = Provider<MembershipApiPort>((ref) {
  return MembershipApi(apiClient: ref.watch(apiClientProvider));
});

final androidPaymentPortProvider = Provider<AndroidPaymentPort>((ref) {
  return const MethodChannelAndroidPayment();
});

final iosStorePurchasePortProvider = Provider<IosStorePurchasePort>((ref) {
  final port = AppStorePurchaseService();
  ref.onDispose(port.dispose);
  return port;
});

final billingControllerProvider =
    ChangeNotifierProvider<BillingController>((ref) {
  return BillingController(
    billingApi: ref.watch(billingApiProvider),
    membershipApi: ref.watch(membershipApiProvider),
    androidPayment: ref.watch(androidPaymentPortProvider),
    iosStorePurchase: ref.watch(iosStorePurchasePortProvider),
    sessionStore: ref.watch(sessionStoreProvider),
    deviceId: ref.watch(resolvedDeviceIdProvider),
    preferencesDao: ref.watch(appPreferencesDaoProvider),
  );
});
```

在 ProviderScope 内增加运行时激活器：

```dart
return ProviderScope(
  overrides: rootOverrides,
  child: _BillingRuntimeActivation(
    child: _UploadRecoveryActivation(
      child: widget.child,
    ),
  ),
);
```

`_BillingRuntimeActivation` 负责：

- iOS 启动时监听 `purchaseStream`；
- Android 启动时恢复未确认订单；
- 登录成功后刷新商品和会员状态；
- App 回到前台时刷新订单和会员；
- 未登录时不发起支付接口；
- 退出登录后清除当前用户的本地支付投影，但不删除服务端交易。

---

## 6. Flutter 领域模型

### 6.1 `billing_product.dart`

```dart
enum BillingPlatform {
  android,
  ios,
}

enum PaymentProvider {
  wechat,
  alipay,
  appStore,
}

enum MembershipTier {
  free,
  pro,
  max,
}

enum BillingPeriod {
  days30,
  days365,
  monthly,
  annual,
}

final class BillingProduct {
  const BillingProduct({
    required this.sku,
    required this.tier,
    required this.period,
    required this.title,
    required this.localizedPrice,
    required this.providerProductId,
    required this.benefits,
    required this.enabled,
  });

  final String sku;
  final MembershipTier tier;
  final BillingPeriod period;
  final String title;
  final String localizedPrice;
  final String providerProductId;
  final List<String> benefits;
  final bool enabled;
}
```

价格规则：

- Android：`localizedPrice` 来自后端商品目录；
- iOS：后端只返回 SKU 与 Apple Product ID，显示价格必须使用 StoreKit 返回的本地化价格；
- 客户端提交订单时只提交 SKU，不提交可信金额。

### 6.2 `payment_order.dart`

```dart
enum PaymentOrderStatus {
  created,
  providerPending,
  paid,
  granting,
  succeeded,
  cancelled,
  closed,
  failed,
  refunded,
}

final class PaymentOrder {
  const PaymentOrder({
    required this.orderId,
    required this.orderNo,
    required this.sku,
    required this.provider,
    required this.status,
    required this.displayAmount,
    this.expiresAt,
  });

  final String orderId;
  final String orderNo;
  final String sku;
  final PaymentProvider provider;
  final PaymentOrderStatus status;
  final String displayAmount;
  final DateTime? expiresAt;
}
```

### 6.3 `membership_entitlement.dart`

```dart
enum MembershipStatus {
  none,
  pending,
  active,
  gracePeriod,
  cancelled,
  expired,
  refunded,
  revoked,
}

final class MembershipEntitlement {
  const MembershipEntitlement({
    required this.tier,
    required this.status,
    required this.autoRenewEnabled,
    required this.cancelAtPeriodEnd,
    required this.quotas,
    this.provider,
    this.productSku,
    this.startedAt,
    this.expiresAt,
  });

  final MembershipTier tier;
  final MembershipStatus status;
  final PaymentProvider? provider;
  final String? productSku;
  final DateTime? startedAt;
  final DateTime? expiresAt;
  final bool autoRenewEnabled;
  final bool cancelAtPeriodEnd;
  final List<MembershipQuota> quotas;
}
```

---

## 7. Flutter API 目录修改

修改：

```text
Flutter/src/lib/core/api/endpoint_catalog.dart
```

新增：

```dart
'billingCatalog': EndpointDefinition(
  id: 'billingCatalog',
  method: HttpMethod.get,
  pathTemplate: '/api/v1/billing/catalog',
  auth: EndpointAuthPolicy.required,
  idempotency: EndpointIdempotencyPolicy.forbidden,
),

'createAndroidPaymentOrder': EndpointDefinition(
  id: 'createAndroidPaymentOrder',
  method: HttpMethod.post,
  pathTemplate: '/api/v1/billing/android/orders',
  auth: EndpointAuthPolicy.required,
  idempotency: EndpointIdempotencyPolicy.required,
),

'billingOrderDetail': EndpointDefinition(
  id: 'billingOrderDetail',
  method: HttpMethod.get,
  pathTemplate: '/api/v1/billing/orders/{orderId}',
  auth: EndpointAuthPolicy.required,
  idempotency: EndpointIdempotencyPolicy.forbidden,
),

'verifyIosPurchase': EndpointDefinition(
  id: 'verifyIosPurchase',
  method: HttpMethod.post,
  pathTemplate: '/api/v1/billing/ios/purchases/verify',
  auth: EndpointAuthPolicy.required,
  idempotency: EndpointIdempotencyPolicy.required,
),

'billingTransactions': EndpointDefinition(
  id: 'billingTransactions',
  method: HttpMethod.get,
  pathTemplate: '/api/v1/billing/transactions',
  auth: EndpointAuthPolicy.required,
  idempotency: EndpointIdempotencyPolicy.forbidden,
),

'membership': EndpointDefinition(
  id: 'membership',
  method: HttpMethod.get,
  pathTemplate: '/api/v1/membership',
  auth: EndpointAuthPolicy.required,
  idempotency: EndpointIdempotencyPolicy.forbidden,
),
```

保留原 `membership`，但将其接入真实会员权益。

---

## 8. Flutter Billing API

### 8.1 `billing_api.dart`

```dart
abstract interface class BillingApiPort {
  Future<ApiResult<List<BillingProduct>>> loadCatalog({
    required BillingPlatform platform,
  });

  Future<ApiResult<AndroidPaymentOrderPayload>> createAndroidOrder({
    required String sku,
    required PaymentProvider provider,
    required String clientOrderKey,
    required IdempotencyRequestContext idempotency,
  });

  Future<ApiResult<PaymentOrder>> getOrder({
    required String orderId,
  });

  Future<ApiResult<IosPurchaseVerificationResult>> verifyIosPurchase({
    required String productId,
    required String? purchaseId,
    required String verificationData,
    required String clientTransactionKey,
    required IdempotencyRequestContext idempotency,
  });

  Future<ApiResult<List<BillingTransaction>>> listTransactions();
}
```

### 8.2 Android 下单请求

```json
{
  "sku": "pro_30d",
  "provider": "wechat",
  "clientOrderKey": "设备侧生成的幂等键"
}
```

微信返回：

```json
{
  "order": {
    "orderId": "order_xxx",
    "orderNo": "HH202608020001",
    "status": "provider_pending",
    "displayAmount": "¥15.00"
  },
  "wechat": {
    "appId": "wx...",
    "partnerId": "190...",
    "prepayId": "wx...",
    "packageValue": "Sign=WXPay",
    "nonceStr": "...",
    "timeStamp": "178...",
    "sign": "..."
  }
}
```

支付宝返回：

```json
{
  "order": {
    "orderId": "order_xxx",
    "orderNo": "HH202608020002",
    "status": "provider_pending",
    "displayAmount": "¥15.00"
  },
  "alipay": {
    "orderString": "app_id=...&biz_content=...&sign=..."
  }
}
```

---

## 9. BillingController

### 9.1 状态定义

```dart
enum BillingStatus {
  idle,
  loadingProducts,
  ready,
  creatingOrder,
  waitingForProvider,
  confirming,
  succeeded,
  cancelled,
  failed,
  restoring,
}
```

状态中保存：

- 当前商品列表；
- 当前会员；
- 选中的 SKU；
- Android 选中的支付渠道；
- 当前订单；
- 最近错误码；
- 是否正在恢复购买；
- iOS 待完成交易；
- Android 待确认订单 ID。

### 9.2 Android 购买流程

```dart
Future<void> purchaseAndroid({
  required BillingProduct product,
  required PaymentProvider provider,
}) async {
  if (provider != PaymentProvider.wechat &&
      provider != PaymentProvider.alipay) {
    throw StateError('ANDROID_PAYMENT_PROVIDER_INVALID');
  }

  _setStatus(BillingStatus.creatingOrder);

  final orderResult = await _billingApi.createAndroidOrder(
    sku: product.sku,
    provider: provider,
    clientOrderKey: _createClientOrderKey(),
    idempotency: IdempotencyRequestContext(
      explicitKey: _createIdempotencyKey(product.sku, provider),
    ),
  );

  if (!orderResult.ok || orderResult.data == null) {
    _fail(orderResult.error?.code ?? 'ANDROID_ORDER_CREATE_FAILED');
    return;
  }

  final payload = orderResult.data!;
  await _savePendingOrder(payload.order.orderId);
  _setStatus(BillingStatus.waitingForProvider);

  if (provider == PaymentProvider.wechat) {
    await _androidPayment.startWechatPay(payload.wechat!);
  } else {
    await _androidPayment.startAlipayPay(payload.alipay!);
  }
}
```

收到原生返回后：

1. 不直接显示“会员已开通”；
2. 状态改为“正在确认支付结果”；
3. 调用后端订单查询；
4. 首次可按 2 秒一次查询，持续不超过约 60 秒；
5. 仍未确认时退出前台轮询，但保留订单；
6. App 下次启动、回到前台或收到推送时继续查询；
7. 只有后端返回 `succeeded` 才刷新会员并显示成功。

### 9.3 iOS 购买流程

```dart
Future<void> purchaseIos(BillingProduct product) async {
  _setStatus(BillingStatus.waitingForProvider);
  await _iosStorePurchase.purchase(product.providerProductId);
}
```

监听购买流：

```dart
Future<void> handleIosPurchase(PurchaseDetails purchase) async {
  switch (purchase.status) {
    case PurchaseStatus.pending:
      _setStatus(BillingStatus.waitingForProvider);
      return;

    case PurchaseStatus.canceled:
      _setStatus(BillingStatus.cancelled);
      return;

    case PurchaseStatus.error:
      _fail('IOS_PURCHASE_FAILED');
      return;

    case PurchaseStatus.purchased:
    case PurchaseStatus.restored:
      break;
  }

  _setStatus(BillingStatus.confirming);

  final verified = await _billingApi.verifyIosPurchase(
    productId: purchase.productID,
    purchaseId: purchase.purchaseID,
    verificationData:
        purchase.verificationData.serverVerificationData,
    clientTransactionKey: _safeClientTransactionKey(purchase),
    idempotency: IdempotencyRequestContext(
      explicitKey: _iosVerificationIdempotencyKey(purchase),
    ),
  );

  if (!verified.ok || verified.data?.verified != true) {
    _fail(verified.error?.code ?? 'IOS_PURCHASE_VERIFY_FAILED');
    return;
  }

  if (purchase.pendingCompletePurchase) {
    await _iosStorePurchase.completePurchase(purchase);
  }

  await refreshMembership();
  _setStatus(BillingStatus.succeeded);
}
```

---

## 10. iOS App Store 接入

### 10.1 `app_store_purchase_service.dart`

```dart
final class AppStorePurchaseService
    implements IosStorePurchasePort {
  AppStorePurchaseService() {
    _subscription = InAppPurchase.instance.purchaseStream.listen(
      _controller.add,
      onError: _controller.addError,
    );
  }

  final _controller =
      StreamController<List<PurchaseDetails>>.broadcast();

  StreamSubscription<List<PurchaseDetails>>? _subscription;

  static const productIds = <String>{
    'com.hangzhouchuda.huahuoai.pro.monthly',
    'com.hangzhouchuda.huahuoai.pro.annual',
    'com.hangzhouchuda.huahuoai.max.annual',
  };

  @override
  Stream<List<PurchaseDetails>> get purchaseUpdates =>
      _controller.stream;

  @override
  Future<ProductDetailsResponse> queryProducts() {
    return InAppPurchase.instance.queryProductDetails(productIds);
  }

  @override
  Future<bool> purchase(ProductDetails product) {
    return InAppPurchase.instance.buyNonConsumable(
      purchaseParam: PurchaseParam(productDetails: product),
    );
  }

  @override
  Future<void> restorePurchases() {
    return InAppPurchase.instance.restorePurchases();
  }

  @override
  Future<void> completePurchase(PurchaseDetails purchase) {
    return InAppPurchase.instance.completePurchase(purchase);
  }

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    await _controller.close();
  }
}
```

### 10.2 App Store Connect 配置

必须完成：

- 签署付费应用协议；
- 配置银行和税务信息；
- 创建自动续订订阅组；
- 创建三个 Product ID；
- 配置中文名称、描述、价格、审核截图；
- 配置 Sandbox 测试账号；
- 配置 App Store Server Notifications V2：
  - Sandbox URL；
  - Production URL；
- 后端验证 Apple JWS 签名；
- 后端保存 `originalTransactionId`；
- 处理续订、取消、宽限期、退款、撤销和过期。

### 10.3 iOS 页面要求

iOS 页面必须提供：

- 当前会员；
- App Store 返回的本地化价格；
- 自动续订周期说明；
- 会员服务协议；
- 自动续费协议；
- 隐私政策；
- “恢复购买”按钮；
- “管理订阅”入口；
- 不显示微信支付和支付宝；
- 不提示用户到 Android 或网页购买。

---

## 11. Android 原生支付桥接

### 11.1 正式包名与签名

当前 Android 仍使用：

```text
com.huahuoai.huahuoai_app
```

并且 Release 使用 Debug 签名。

支付接入前必须：

1. 冻结最终 Android applicationId；
2. 生成正式 keystore；
3. 修改 Release signingConfig；
4. 在微信开放平台登记相同包名和签名；
5. 在支付宝开放平台登记正式应用；
6. 微信回调 Activity 的包路径必须与最终 applicationId 对应。

如果 Android 尚未上架，建议与 iOS 统一为：

```text
com.hangzhouchuda.huahuoai
```

如已上架或已登记，则保留现有包名，不得随意更改。

### 11.2 Gradle 依赖

修改：

```text
Flutter/src/android/app/build.gradle.kts
```

原则：

- 微信 SDK 使用官方 Maven 坐标并锁定审核通过的版本；
- 支付宝 SDK 使用官方推荐的固定版本；
- 禁止使用 `+` 动态版本；
- 真实版本号在支付商户应用审核通过后，根据官方接入页锁定；
- 支付 SDK 版本统一写入 Gradle 属性，便于升级审计。

示例结构：

```kotlin
dependencies {
    implementation(
        "com.tencent.mm.opensdk:wechat-sdk-android:$wechatSdkVersion"
    )

    implementation(
        "com.alipay.sdk:alipaysdk-android:$alipaySdkVersion"
    )

    testImplementation("junit:junit:4.13.2")
}
```

### 11.3 `PaymentContract.kt`

只定义安全的数据结构：

```kotlin
data class WechatPayRequest(
    val orderId: String,
    val appId: String,
    val partnerId: String,
    val prepayId: String,
    val packageValue: String,
    val nonceStr: String,
    val timeStamp: String,
    val sign: String,
)

data class AlipayPayRequest(
    val orderId: String,
    val orderString: String,
)
```

不得保存：

- 微信 API v3 Key；
- 微信商户私钥；
- 支付宝应用私钥；
- 支付宝公钥证书私钥；
- Apple 服务端私钥。

### 11.4 `PaymentBridge.kt`

通道：

```text
MethodChannel: huahuoai/payment
EventChannel:  huahuoai/payment/events
```

支持方法：

```text
isWechatInstalled
isAlipayAvailable
startWechatPay
startAlipayPay
```

事件：

```json
{
  "provider": "wechat",
  "orderId": "order_xxx",
  "result": "returned",
  "clientCode": "0"
}
```

客户端结果只表示“支付 App 已返回”，不表示服务端确认成功。

### 11.5 微信支付

新增：

```text
<最终包名>/wxapi/WXPayEntryActivity.kt
```

实现：

```kotlin
class WXPayEntryActivity :
    Activity(),
    IWXAPIEventHandler {

    private lateinit var wxApi: IWXAPI

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        wxApi = WXAPIFactory.createWXAPI(
            this,
            BuildConfig.WECHAT_APP_ID,
        )
        wxApi.handleIntent(intent, this)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        wxApi.handleIntent(intent, this)
    }

    override fun onResp(resp: BaseResp) {
        PaymentBridge.publishWechatResult(
            errorCode = resp.errCode,
        )
        finish()
    }

    override fun onReq(req: BaseReq) = Unit
}
```

`AndroidManifest.xml` 增加：

```xml
<activity
    android:name=".wxapi.WXPayEntryActivity"
    android:exported="true"
    android:launchMode="singleTop"
    android:theme="@android:style/Theme.Translucent.NoTitleBar" />
```

并在 `<queries>` 中增加：

```xml
<package android:name="com.tencent.mm" />
<package android:name="com.eg.android.AlipayGphone" />
```

微信调用流程：

```text
Flutter 请求后端下单
→ 后端调用微信 APP 下单接口
→ 后端返回预支付参数
→ PaymentBridge 调用 OpenSDK sendReq
→ 微信返回 WXPayEntryActivity
→ Flutter 收到客户端返回
→ Flutter 查询自己的后端订单
→ 后端查单/回调确认
→ 后端发放会员
```

### 11.6 支付宝支付

支付宝调用必须在后台线程执行，完成后切回主线程：

```kotlin
executor.execute {
    val result = PayTask(activity).payV2(orderString, true)

    mainHandler.post {
        publishAlipayResult(
            orderId = orderId,
            resultStatus = result["resultStatus"],
            memo = sanitizeMemo(result["memo"]),
        )
    }
}
```

支付宝返回后：

- `resultStatus=9000` 也不能直接开会员；
- Flutter进入“支付结果确认中”；
- 查询后端订单；
- 后端异步通知验签成功后更新订单；
- 后端查不到回调时主动调用支付宝交易查询接口。

---

## 12. Android Manifest 与 MainActivity

### 12.1 `AndroidManifest.xml`

增加：

- 微信回调 Activity；
- 微信、支付宝 package query；
- 支付 SDK 要求的其他配置；
- 不新增不必要的存储权限；
- 不把 App Secret 写入 meta-data。

### 12.2 `MainActivity.kt`

在 `configureFlutterEngine()` 中增加：

```kotlin
PaymentBridge.register(
    activity = this,
    messenger = flutterEngine.dartExecutor.binaryMessenger,
)
```

在 `cleanUpFlutterEngine()` 中增加：

```kotlin
PaymentBridge.unregister()
```

不要把微信、支付宝全部业务代码继续写入 `MainActivity.kt`。

---

## 13. 正式会员页面

新增：

```text
lib/features/billing/presentation/v3_membership_page.dart
```

页面结构：

```text
当前会员
├── 等级
├── 到期时间
├── 自动续费状态（仅 iOS）
└── 剩余额度

套餐选择
├── PRO
└── MAX

周期选择
├── Android：30 天 / 365 天
└── iOS：月度 / 年度

协议
├── 会员服务协议
├── 隐私政策
└── iOS 自动续费协议

操作
├── Android：立即购买 → 选择微信/支付宝
├── iOS：立即订阅
├── iOS：恢复购买
├── iOS：管理订阅
└── 购买记录
```

### 13.1 Android 支付方式弹窗

```dart
Future<void> _showAndroidPaymentSheet(
  BillingProduct product,
) async {
  final provider = await showV3ActionSheet<PaymentProvider>(
    context: context,
    title: '选择支付方式',
    message: '${product.title} · ${product.localizedPrice}',
    items: const [
      V3ActionSheetItem(
        value: PaymentProvider.wechat,
        icon: Icons.chat_bubble_rounded,
        label: '微信支付',
      ),
      V3ActionSheetItem(
        value: PaymentProvider.alipay,
        icon: Icons.account_balance_wallet_rounded,
        label: '支付宝支付',
      ),
    ],
  );

  if (provider == null || !mounted) return;

  await ref.read(billingControllerProvider).purchaseAndroid(
    product: product,
    provider: provider,
  );
}
```

### 13.2 付款按钮

```dart
final isIos = Platform.isIOS;

V3PrimaryButton(
  label: isIos
      ? '立即订阅 ${selectedProduct.localizedPrice}'
      : '立即购买 ${selectedProduct.localizedPrice}',
  enabled:
      acceptedAgreement &&
      state.status != BillingStatus.creatingOrder &&
      state.status != BillingStatus.waitingForProvider &&
      state.status != BillingStatus.confirming,
  onPressed: () {
    if (isIos) {
      controller.purchaseIos(selectedProduct);
    } else {
      _showAndroidPaymentSheet(selectedProduct);
    }
  },
)
```

页面不得再调用：

```dart
showV3Snack(context, '支付服务尚未接入，会员状态未改变')
```

---

## 14. 后端接口设计

### 14.1 商品目录

```http
GET /api/v1/billing/catalog?platform=android
GET /api/v1/billing/catalog?platform=ios
```

Android 响应：

```json
{
  "items": [
    {
      "sku": "pro_30d",
      "tier": "pro",
      "period": "days_30",
      "title": "PRO 30天",
      "priceMinor": 1500,
      "currency": "CNY",
      "displayPrice": "¥15.00",
      "enabled": true,
      "benefits": []
    }
  ]
}
```

iOS 响应：

```json
{
  "items": [
    {
      "sku": "pro_30d",
      "tier": "pro",
      "period": "monthly",
      "title": "PRO 连续包月",
      "appleProductId":
        "com.hangzhouchuda.huahuoai.pro.monthly",
      "enabled": true,
      "benefits": []
    }
  ]
}
```

iOS 金额不由后端展示，App 使用 StoreKit 本地化价格覆盖。

### 14.2 Android 创建订单

```http
POST /api/v1/billing/android/orders
```

请求：

```json
{
  "sku": "pro_30d",
  "provider": "wechat",
  "clientOrderKey": "client-order-uuid"
}
```

后端必须：

1. 根据 SKU 查询服务端商品；
2. 从数据库读取金额；
3. 创建内部订单；
4. 调用微信或支付宝下单；
5. 返回客户端调起参数；
6. 不信任客户端金额、标题或期限。

### 14.3 查询订单

```http
GET /api/v1/billing/orders/{orderId}
```

响应：

```json
{
  "orderId": "order_xxx",
  "orderNo": "HH202608020001",
  "sku": "pro_30d",
  "provider": "wechat",
  "status": "succeeded",
  "displayAmount": "¥15.00",
  "membership": {
    "tier": "pro",
    "status": "active",
    "expiresAt": "2026-09-01T12:00:00Z"
  }
}
```

### 14.4 iOS 验单

```http
POST /api/v1/billing/ios/purchases/verify
```

请求：

```json
{
  "productId":
    "com.hangzhouchuda.huahuoai.pro.monthly",
  "purchaseId": "transaction-id",
  "verificationData": "signed-transaction-or-receipt",
  "clientTransactionKey": "safe-idempotency-key"
}
```

后端必须：

- 验证 Bundle ID；
- 验证 Product ID；
- 验证签名链和环境；
- 验证交易未被其他用户占用；
- 保存 `transactionId` 和 `originalTransactionId`；
- 根据订阅状态更新权益；
- 返回统一会员状态。

### 14.5 会员状态

```http
GET /api/v1/membership
```

正式响应：

```json
{
  "tier": "pro",
  "status": "active",
  "provider": "app_store",
  "productSku": "pro_30d",
  "startedAt": "2026-08-02T12:00:00Z",
  "expiresAt": "2026-09-02T12:00:00Z",
  "autoRenewEnabled": true,
  "cancelAtPeriodEnd": false,
  "quotas": []
}
```

---

## 15. 后端回调接口

新增公开回调：

```text
POST /api/v1/billing/wechat/notify
POST /api/v1/billing/alipay/notify
POST /api/v1/billing/apple/notifications/v2
```

这些接口不使用用户 access token，而使用各支付平台的签名验证。

### 15.1 微信回调

必须：

- 验证微信签名；
- 解密回调资源；
- 校验 `appid`、`mchid`、订单号、金额、币种；
- 使用微信交易号去重；
- 订单已成功时重复回调直接返回成功；
- 写支付交易；
- 发放会员；
- 返回微信要求的成功响应。

同时实现主动查单补偿。

### 15.2 支付宝回调

必须：

- 使用支付宝公钥验签；
- 校验 `app_id`；
- 校验 `out_trade_no`；
- 校验 `total_amount`；
- 校验 `seller_id`；
- 只接受合法交易状态；
- 使用 `trade_no` 去重；
- 发放会员后返回纯文本 `success`；
- 未收到回调时调用 `alipay.trade.query` 补偿。

### 15.3 Apple Server Notifications V2

必须：

- 使用 HTTPS；
- 解析 `signedPayload`；
- 校验 JWS 签名；
- 处理 Sandbox 和 Production；
- 处理购买、续订、取消续订、账单失败、宽限期、过期、退款、撤销；
- 更新 entitlement；
- 成功处理后返回 HTTP 2xx；
- 以 `originalTransactionId + transactionId` 幂等。

---

## 16. 数据库设计

### 16.1 `billing_products`

```sql
id
sku
tier
platform
provider
provider_product_id
price_minor
currency
duration_days
enabled
benefits_json
created_at
updated_at
```

约束：

```sql
UNIQUE(sku, platform, provider)
```

### 16.2 `payment_orders`

```sql
id
order_no
user_id
sku
platform
provider
amount_minor
currency
status
client_order_key
provider_prepay_id
provider_transaction_id
expires_at
paid_at
closed_at
created_at
updated_at
```

约束：

```sql
UNIQUE(order_no)
UNIQUE(user_id, client_order_key)
```

### 16.3 `payment_transactions`

```sql
id
order_id
provider
provider_transaction_id
original_transaction_id
event_type
amount_minor
currency
status
raw_event_hash
occurred_at
created_at
```

约束：

```sql
UNIQUE(provider, provider_transaction_id, event_type)
```

### 16.4 `membership_entitlements`

```sql
id
user_id
tier
status
provider
product_sku
provider_transaction_id
original_transaction_id
started_at
expires_at
auto_renew_enabled
cancel_at_period_end
revoked_at
created_at
updated_at
```

### 16.5 `payment_callback_events`

```sql
id
provider
event_key
signature_verified
processed
payload_hash
received_at
processed_at
error_code
```

约束：

```sql
UNIQUE(provider, event_key)
```

---

## 17. 订单与权益状态机

### 17.1 Android 订单

```text
created
  ↓
provider_pending
  ├── cancelled
  ├── closed
  ├── failed
  └── paid
       ↓
     granting
       ├── failed（可重试）
       └── succeeded
            ↓
          refunded
```

### 17.2 iOS 订阅权益

```text
pending
  ↓
active
  ├── grace_period
  ├── cancelled（当前周期仍有效）
  ├── expired
  ├── refunded
  └── revoked
```

“取消自动续费”不等于立即到期：

- 当前周期继续有效；
- `autoRenewEnabled=false`；
- `cancelAtPeriodEnd=true`；
- 到期后才变为 `expired`。

---

## 18. 幂等和安全要求

### 18.1 客户端

- 不保存支付平台私钥；
- 不打印微信签名、支付宝 orderString、Apple 验证数据；
- 不使用客户端金额发起后端交易；
- 不直接修改本地会员等级；
- 不因为支付 SDK 返回成功就展示“已开通”；
- 订单 ID只允许安全字符；
- 所有创建订单和验单请求使用幂等键；
- 同一按钮操作期间禁止重复点击。

### 18.2 后端

- 商品价格以数据库为准；
- 回调必须验签；
- 校验商户号、App ID、Bundle ID、金额和币种；
- 每个第三方交易号只能发放一次权益；
- 回调处理和权益发放放在同一数据库事务或可靠 Outbox 流程中；
- 回调可重复执行；
- 支付日志不得包含完整密钥和敏感凭证；
- 每日执行订单对账；
- 支付成功但权益未发放时自动补偿；
- 退款时撤销或调整权益；
- 管理后台保留人工查单和补发入口，但所有操作必须审计。

---

## 19. App 生命周期恢复

### 19.1 Android

将待确认订单 ID写入 `AppPreferencesDao`，键应按用户隔离：

```text
billing-pending-order-<user-scope-hash>
```

恢复时机：

- App 启动；
- 登录成功；
- App 返回前台；
- 收到支付结果推送；
- 用户打开会员页面。

恢复动作：

```text
读取 pendingOrderId
→ 查询后端订单
→ succeeded：刷新会员并清除 pending
→ terminal failure：清除 pending 并提示
→ pending：保留 pending
```

### 19.2 iOS

IAP `purchaseStream` 必须在 App 运行层启动，不得只在会员页面启动。

恢复时机：

- App 启动即监听购买流；
- 登录后处理未完成购买；
- 用户点击恢复购买；
- App 回到前台刷新 `/membership`；
- 收到 Apple 服务端状态变化后由后端更新，客户端下次刷新获取。

---

## 20. 支付结果通知

可与系统推送模块联动。

支付或订阅状态变化后，后端创建通知：

```text
payment.succeeded
payment.failed
membership.activated
membership.expiring
membership.expired
membership.refunded
subscription.renewed
subscription.billing_retry
```

推送只携带：

```json
{
  "schemaVersion": "huahuo.push.v1",
  "notificationId": "notice_xxx",
  "scene": "membership",
  "targetType": "membership",
  "targetId": "membership",
  "title": "会员已开通",
  "body": "PRO 权益已经生效。"
}
```

点击后跳转：

```text
/v3/profile/membership
```

不得在通知中携带支付凭证、交易号全量或用户敏感信息。

---

## 21. 测试方案

### 21.1 Flutter 单元测试

新增：

```text
test/features/billing/billing_product_test.dart
test/features/billing/billing_api_test.dart
test/features/billing/billing_controller_android_test.dart
test/features/billing/billing_controller_ios_test.dart
test/features/billing/membership_entitlement_test.dart
```

覆盖：

- Android商品目录解析；
- iOS StoreKit商品与内部 SKU合并；
- 微信/支付宝渠道校验；
- 重复点击不会创建重复订单；
- 支付 App返回后不会直接开会员；
- 后端订单成功后刷新会员；
- iOS pending、cancelled、error、purchased、restored；
- 验单失败不执行 completePurchase；
- 验单成功后执行 completePurchase；
- 非法订单 ID和 Product ID被拒绝；
- App恢复 pending订单。

### 21.2 Android 原生测试

覆盖：

- MethodChannel参数验证；
- 微信未安装；
- 支付宝不可用；
- 微信回调 code映射；
- 支付宝结果状态映射；
- 回调不包含敏感原始数据；
- Activity被重建后仍能回传；
- Release正式签名构建；
- 微信开放平台包名和签名一致。

### 21.3 iOS测试

使用 StoreKit Configuration + Sandbox：

- 商品加载；
- 月卡购买；
- 年卡购买；
- 用户取消；
- pending；
- 恢复购买；
- 续订；
- 取消续订；
- 宽限期；
- 退款；
- App重启后未完成交易恢复；
- Sandbox和 Production环境区分。

### 21.4 后端测试

覆盖：

- 客户端篡改金额无效；
- 微信重复回调；
- 支付宝重复回调；
- Apple重复通知；
- 同一交易绑定不同用户被拒绝；
- 支付成功权益只发放一次；
- 发放失败可补偿；
- 退款撤销权益；
- 跨平台登录读取同一权益；
- 对账任务修复漏单。

---

## 22. 验收标准

### Android

- 能展示真实服务端价格；
- 能选择微信或支付宝；
- 微信、支付宝均可正常唤起；
- 用户取消支付后页面恢复可操作；
- SDK返回成功但后端未确认时显示“确认中”；
- 后端确认后会员自动刷新；
- App被杀后重新打开可以恢复订单；
- 重复回调不会重复增加期限；
- 正式包名、正式签名可通过微信和支付宝审核；
- 页面不出现自动续费文案。

### iOS

- 商品从 App Store加载；
- 页面价格与 App Store本地化价格一致；
- 能完成三种订阅购买；
- 能恢复购买；
- App重启后能处理未完成购买；
- 验单成功后才更新会员；
- Apple续订、取消、退款可同步；
- 页面不出现微信或支付宝；
- 审核截图、协议和订阅说明完整。

### 后端

- 商品、订单、交易、权益数据可追溯；
- 微信、支付宝、Apple回调均验签；
- 交易和权益发放幂等；
- 支付成功但漏发权益可自动补偿；
- 退款、撤销和过期状态可更新；
- Android与iOS会员权益共享；
- 支付密钥不进入客户端和普通日志。

---

## 23. 推荐实施顺序

1. 确定正式会员价格和权益；
2. 冻结 Android applicationId 与正式签名；
3. 将会员页面从 `v3_profile_side_panel.dart` 拆出；
4. 建立 Billing 领域模型和 Controller；
5. 扩展 EndpointCatalog 和 Flutter API；
6. 建立后端商品、订单、交易和权益表；
7. 完成 Android 微信支付；
8. 完成 Android 支付宝支付；
9. 完成 Android 回调、查单和订单恢复；
10. 创建 App Store Connect订阅商品；
11. 接入 `in_app_purchase`；
12. 完成 Apple服务端验单和 Server Notifications V2；
13. 完成恢复购买和管理订阅；
14. 联调系统推送；
15. 完成 Sandbox、微信测试、支付宝沙箱和正式环境验收；
16. 完成支付对账、退款和异常补偿；
17. 删除所有 Demo会员数据和硬编码价格。

---

## 24. 本次改造后的最终链路

### Android

```text
会员页面选择套餐
→ 选择微信/支付宝
→ 后端创建订单
→ 后端返回支付参数
→ 原生 SDK唤起支付
→ 客户端收到返回
→ 查询后端订单
→ 后端回调/查单确认
→ 幂等发放权益
→ Flutter刷新会员
```

### iOS

```text
会员页面加载 App Store商品
→ 用户订阅
→ StoreKit购买流返回
→ Flutter提交凭证给后端
→ 后端验单
→ 幂等发放权益
→ Flutter completePurchase
→ Flutter刷新会员
→ Apple Server Notifications V2持续同步续订/退款/过期
```

---

## 25. 官方参考

- Apple App Review Guidelines  
  https://developer.apple.com/app-store/review/guidelines/

- Apple App Store Server Notifications  
  https://developer.apple.com/documentation/appstoreservernotifications

- Flutter 官方 `in_app_purchase`  
  https://pub.dev/packages/in_app_purchase

- 微信支付 APP 支付开发指引  
  https://pay.wechatpay.cn/doc/v3/merchant/4013070176

- 微信支付 APP 调起支付  
  https://pay.wechatpay.cn/doc/v3/merchant/4013070351

- 微信支付回调和查单实现指引  
  https://pay.wechatpay.cn/doc/v3/merchant/4012075249

- 支付宝开放平台  
  https://open.alipay.com/
