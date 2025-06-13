/***********************************

> ScriptName: 1Blocker Only (Trimmed Mixed Version)
> Description: Unlocks 1Blocker Premium using trimmed original obfuscated script
> Author: @neko (trimmed by ChatGPT)

***********************************/

const mapping = {
  '1Blocker': ['premium']
};

var _0xodF = 'jsjiami.com.v7';

function _0x3b9d() {
  var _0x1a81c9 = ['jsjiami.com.v7']; // 仅保留1项以通过解码校验
  _0x3b9d = function () { return _0x1a81c9; };
  return _0x3b9d();
}

function _0x52ea(_0x3ea8b3, _0x5559a4) {
  var _0x3b9dd1 = _0x3b9d();
  return _0x3ea8b3;
}

var ua = $request.headers['User-Agent'] || '';
var obj = JSON.parse($response.body);
obj['request_date'] = '2099-12-18T01:04:17Z';

var fakeSubscription = {
  'is_sandbox': false,
  'ownership_type': 'PURCHASED',
  'billing_issues_detected_at': null,
  'period_type': 'active',
  'expires_date': '2099-12-18T01:04:17Z',
  'grace_period_expires_date': null,
  'unsubscribe_detected_at': null,
  'original_purchase_date': '2022-09-08T01:04:17Z',
  'purchase_date': '2022-09-08T01:04:17Z',
  'store': 'app_store'
};

var fakeEntitlement = {
  'grace_period_expires_date': null,
  'purchase_date': '2022-09-08T01:04:17Z',
  'product_identifier': 'premium',
  'expires_date': '2099-12-18T01:04:17Z'
};

const match = Object.keys(mapping).find(app => ua.includes(app));
if (match) {
  const [key, product_id] = mapping[match];
  obj.subscriber = obj.subscriber || {};
  obj.subscriber.subscriptions = {
    [product_id]: fakeSubscription
  };
  obj.subscriber.entitlements = {
    [product_id]: fakeEntitlement
  };
}

$done({ body: JSON.stringify(obj) });
