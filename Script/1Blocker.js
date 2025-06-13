/***********************************

> ScriptName 1Blocker
> Author @neko

[rewrite_local]
^https:\/\/api\.(revenuecat|rc-backup)\.com\/.+\/(receipts$|subscribers\/[^/]+$) url script-response-body https://raw.githubusercontent.com/Emokui/Nothing/Zero/Script/1Blocker.js
^https:\/\/api\.(revenuecat|rc-backup)\.com\/.+\/(receipts|subscribers) url script-request-header https://raw.githubusercontent.com/Emokui/Nothing/Zero/Script/deleteheader.js

[mitm]
hostname=api.revenuecat.com, api.rc-backup.com

***********************************/

const mapping = {
'1Blocker': ['premium']
};

// Base64解码函数
function base64Decode(input) {
    const keyStr = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/=';
    let output = '';
    let chr1, chr2, chr3;
    let enc1, enc2, enc3, enc4;
    let i = 0;

    input = input.replace(/[^A-Za-z0-9\+\/\=]/g, '');

    while (i < input.length) {
        enc1 = keyStr.indexOf(input.charAt(i++));
        enc2 = keyStr.indexOf(input.charAt(i++));
        enc3 = keyStr.indexOf(input.charAt(i++));
        enc4 = keyStr.indexOf(input.charAt(i++));

        chr1 = (enc1 << 2) | (enc2 >> 4);
        chr2 = ((enc2 & 15) << 4) | (enc3 >> 2);
        chr3 = ((enc3 & 3) << 6) | enc4;

        output += String.fromCharCode(chr1);

        if (enc3 !== 64) {
            output += String.fromCharCode(chr2);
        }
        if (enc4 !== 64) {
            output += String.fromCharCode(chr3);
        }
    }

    // URL解码
    let result = '';
    for (let j = 0; j < output.length; j++) {
        result += '%' + ('00' + output.charCodeAt(j).toString(16)).slice(-2);
    }
    return decodeURIComponent(result);
}

// RC4解密函数
function rc4Decrypt(data, key) {
    let s = [];
    let j = 0;
    let temp;
    let result = '';
    
    // 密钥调度算法 (KSA)
    for (let i = 0; i < 256; i++) {
        s[i] = i;
    }
    
    for (let i = 0; i < 256; i++) {
        j = (j + s[i] + key.charCodeAt(i % key.length)) % 256;
        temp = s[i];
        s[i] = s[j];
        s[j] = temp;
    }
    
    // 伪随机生成算法 (PRGA)
    let m = 0;
    j = 0;
    for (let n = 0; n < data.length; n++) {
        m = (m + 1) % 256;
        j = (j + s[m]) % 256;
        temp = s[m];
        s[m] = s[j];
        s[j] = temp;
        result += String.fromCharCode(data.charCodeAt(n) ^ s[(s[m] + s[j]) % 256]);
    }
    
    return result;
}

// 字符串解密主函数
function decryptString(encryptedStr, encryptionKey) {
    const decoded = base64Decode(encryptedStr);
    return rc4Decrypt(decoded, encryptionKey);
}

// 获取用户代理
const ua = $request.headers['User-Agent'] || $request.headers['user-agent'];

// 解析响应体
const obj = JSON.parse($response.body);

// 设置应用版本
obj.subscriber.original_application_version = "1.0";

// 订阅信息配置
const subscriptionData = {
    is_sandbox: false,
    ownership_type: "PURCHASED",
    billing_issues_detected_at: null,
    period_type: "normal",
    expires_date: "2099-12-18T01:04:17Z",
    grace_period_expires_date: null,
    unsubscribe_detected_at: null,
    original_purchase_date: "2022-09-08T01:04:17Z",
    purchase_date: "2022-09-08T01:04:17Z",
    store: "app_store"
};

// 权限信息配置
const entitlementData = {
    grace_period_expires_date: null,
    purchase_date: "2022-09-08T01:04:17Z",
    product_identifier: "premium",
    expires_date: "2099-12-18T01:04:17Z"
};

// 应用映射配置
const mapping = {
    'Spotify': ['music_premium', 'com.spotify.premium'],
    'YouTube': ['youtube_premium', 'com.google.youtube.premium'],
    'Netflix': ['netflix_premium', 'com.netflix.premium'],
    'Adobe': ['creative_cloud', 'com.adobe.cc.premium'],
    'Microsoft': ['office_365', 'com.microsoft.office365'],
    'Apple': ['icloud_premium', 'com.apple.icloud.premium'],
    'Disney': ['disney_plus', 'com.disney.plus.premium'],
    'HBO': ['hbo_max', 'com.hbo.max.premium'],
    'Prime': ['amazon_prime', 'com.amazon.prime.video']
};

// 查找匹配的用户代理
const match = Object.keys(mapping).find(key => ua.includes(key));

if (match) {
    const [entitlementKey, productId] = mapping[match];
    
    if (productId) {
        entitlementData.product_identifier = productId;
        obj.subscriber.subscriptions[productId] = subscriptionData;
    } else {
        obj.subscriber.subscriptions.premium = subscriptionData;
    }
    
    // 初始化权限对象
    obj.subscriber.entitlements = {};
    
    // 处理多权限情况
    if (entitlementKey.includes('&')) {
        const parts = entitlementKey.split('&');
        parts.forEach(part => {
            obj.subscriber.entitlements[part] = entitlementData;
        });
    } else {
        obj.subscriber.entitlements[entitlementKey] = entitlementData;
    }
} else {
    // 默认配置
    obj.subscriber.subscriptions.premium = subscriptionData;
    obj.subscriber.entitlements.premium = entitlementData;
}

// 返回修改后的响应
$done({
    body: JSON.stringify(obj)
});