/***********************************

> ScriptName        𝐑𝐞𝐯𝐞𝐧𝐮𝐞𝐂𝐚𝐭
> Author            @ddgksf2013

[rewrite_local]

^https:\/\/api\.(revenuecat|rc-backup)\.com\/.+\/(receipts$|subscribers\/[^/]+$) url script-response-body https://raw.githubusercontent.com/Emokui/Nothing/Zero/Script/1blocker.js
^https:\/\/api\.(revenuecat|rc-backup)\.com\/.+\/(receipts|subscribers) url script-request-header https://raw.githubusercontent.com/Emokui/Nothing/Zero/Script/deleteheader.js

[mitm]

hostname=api.revenuecat.com, api.rc-backup.com

***********************************/

const mapping = {
  '1Blocker': ['premium']
};

var ua = $request.headers['user-agent'] || $request['user-agent'];
var obj = JSON.parse($response.body);
var ddgksf2013 = {
  'is_sandbox': false,
  'ownership_type': 'PURCHASED',
  'billing_issues_detected_at': null,
  'period_type': 'normal',
  'expires_date': '2099-12-18T01:04:17Z',
  'grace_period_expires_date': null,
  'unsubscribe_detected_at': null,
  'original_purchase_date': '2022-09-08T01:04:17Z',
  'purchase_date': '2022-09-08T01:04:17Z',
  'store': 'app_store'
};

var ddgksf2021 = {
  'grace_period_expires_date': null,
  'purchase_date': '2022-09-08T01:04:17Z',
  'product_identifier': 'com.oneblocker.subscription.yearly',
  'expires_date': '2099-12-18T01:04:17Z'
};

obj['subscriber']['subscriptions'][ddgksf2021['product_identifier']] = ddgksf2013;
obj['subscriber']['entitlements'] = {};
obj['subscriber']['entitlements']['premium'] = ddgksf2021;

$done({
  'body': JSON.stringify(obj)
});