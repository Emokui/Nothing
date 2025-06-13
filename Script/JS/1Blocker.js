// 1Blocker Premium Unlock Script
// Target: RevenueCat API responses

// 应用与产品标识符的映射关系
const mapping = {
  '1Blocker': ['premium']
};

// 获取请求头中的User-Agent
var ua = $request.headers['User-Agent'] || $request.headers['user-agent'];

// 解析RevenueCat API的响应体
var obj = JSON.parse($response.body);

// 设置request_date为当前时间戳
obj.request_date = '2022-09-08T01:04:17Z';

// 创建订阅信息对象
var subscriptionInfo = {
  is_sandbox: false,
  ownership_type: 'PURCHASED',
  billing_issues_detected_at: null,
  period_type: 'normal',
  expires_date: '2099-12-18T01:04:17Z',
  grace_period_expires_date: null,
  unsubscribe_detected_at: null,
  original_purchase_date: '2022-09-08T01:04:17Z',
  purchase_date: '2022-09-08T01:04:17Z',
  store: 'app_store'
};

// 创建权限信息对象
var entitlementInfo = {
  grace_period_expires_date: null,
  purchase_date: '2022-09-08T01:04:17Z',
  product_identifier: 'premium',
  expires_date: '2099-12-18T01:04:17Z'
};

// 根据User-Agent匹配对应的应用
const match = Object.keys(mapping).find(key => ua.includes(key));

if (match) {
  const [key, product_id] = [match, mapping[match][0]];
  
  if (product_id) {
    entitlementInfo.product_identifier = product_id;
    obj.subscriber.subscriptions[product_id] = subscriptionInfo;
  } else {
    obj.subscriber.subscriptions['premium'] = subscriptionInfo;
  }
  
  // 初始化权限对象
  obj.subscriber.entitlements = {};
  
  // 处理多个权限（用&分隔）
  if (key.includes('&')) {
    let parts = key.split('&');
    parts.forEach(part => {
      obj.subscriber.entitlements[part] = entitlementInfo;
    });
  } else {
    obj.subscriber.entitlements[key] = entitlementInfo;
  }
} else {
  // 默认设置
  obj.subscriber.subscriptions['premium'] = subscriptionInfo;
  obj.subscriber.entitlements['premium'] = entitlementInfo;
}

// 返回修改后的响应
$done({body: JSON.stringify(obj)});
