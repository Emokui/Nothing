/***********************************

> ScriptName        1Blocker (Clean Version)
> Description       Unlocks premium for 1Blocker by faking RevenueCat subscription
> Author            @neko (cleaned by ChatGPT)

***********************************/

const mapping = {
  '1Blocker': ['premium']
};

let ua = $request.headers['User-Agent'] || '';
let body = JSON.parse($response.body);

// Prepare fake subscription info
let fakeEntitlement = {
  "grace_period_expires_date": null,
  "purchase_date": "2022-09-08T01:04:17Z",
  "product_identifier": "premium",
  "expires_date": "2099-12-18T01:04:17Z"
};

let fakeSubscription = {
  "is_sandbox": false,
  "ownership_type": "PURCHASED",
  "billing_issues_detected_at": null,
  "period_type": "active",
  "expires_date": "2099-12-18T01:04:17Z",
  "grace_period_expires_date": null,
  "unsubscribe_detected_at": null,
  "original_purchase_date": "2022-09-08T01:04:17Z",
  "purchase_date": "2022-09-08T01:04:17Z",
  "store": "app_store"
};

// Match app by user-agent
if (ua.includes("1Blocker")) {
  const productId = mapping["1Blocker"][0];

  // Inject into response
  body.subscriber = body.subscriber || {};
  body.subscriber.entitlements = {
    [productId]: fakeEntitlement
  };
  body.subscriber.subscriptions = {
    [productId]: fakeSubscription
  };
}

$done({ body: JSON.stringify(body) });
