// 1Blocker Premium Unlock Script (Deobfuscated)
// Target: RevenueCat API v1/v2 endpoints

const appMapping = {
  '1Blocker': { 
    productID: 'premium',
    entitlements: ['premium']
  }
};

// 核心响应修改逻辑
function modifyResponse(originalResponse) {
  try {
    const response = JSON.parse(originalResponse.body);
    
    // 基础订阅信息模板
    const baseSubscription = {
      is_sandbox: false,
      ownership_type: "PURCHASED",
      period_type: "normal",
      expires_date: "2099-12-31T23:59:59Z",
      purchase_date: new Date().toISOString(),
      original_purchase_date: "2022-09-08T00:00:00Z",
      store: "app_store"
    };

    // 高级权限模板
    const premiumEntitlement = {
      product_identifier: "premium",
      expires_date: "2099-12-31T23:59:59Z",
      purchase_date: new Date().toISOString(),
      is_sandbox: false
    };

    // 获取User-Agent识别应用
    const userAgent = $request.headers['User-Agent'] || $request.headers['user-agent'];
    const matchedApp = Object.keys(appMapping).find(app => userAgent.includes(app));

    if (matchedApp) {
      const { productID, entitlements } = appMapping[matchedApp];
      
      // 更新订阅信息
      response.subscriber.subscriptions = {
        [productID]: { ...baseSubscription }
      };

      // 设置权限
      response.subscriber.entitlements = entitlements.reduce((acc, entitlement) => {
        acc[entitlement] = { ...premiumEntitlement };
        return acc;
      }, {});
    } else {
      // 默认配置
      response.subscriber.subscriptions = {
        'premium': { ...baseSubscription }
      };
      response.subscriber.entitlements = {
        'premium': { ...premiumEntitlement }
      };
    }

    // 修复时间戳验证
    response.request_date = new Date().toISOString();
    response.subscriber.original_application_version = "1.0";
    response.subscriber.original_purchase_date = "2022-09-08T00:00:00Z";
    
    return { body: JSON.stringify(response) };
    
  } catch (error) {
    console.log(`处理错误: ${error}`);
    return { body: originalResponse.body };
  }
}

// MITM处理逻辑
const isTargetRequest = 
  /^https:\/\/api\.(revenuecat|rc-backup)\.com\/v[12]\/.+\/(receipts|subscribers)/.test($request.url);

if (isTargetRequest) {
  $done(modifyResponse($response));
} else {
  $done({});
}
