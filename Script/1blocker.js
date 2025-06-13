/***********************************

> ScriptName        1Blocker
> Author            @neko

[rewrite_local]

^https:\/\/api\.(revenuecat|rc-backup)\.com\/.+\/(receipts$|subscribers\/[^/]+$) url script-response-body https://raw.githubusercontent.com/Emokui/Nothing/Zero/Script/1blocker.js
^https:\/\/api\.(revenuecat|rc-backup)\.com\/.+\/(receipts|subscribers) url script-request-header https://raw.githubusercontent.com/Emokui/Nothing/Zero/Script/deleteheader.js

[mitm]

hostname=api.revenuecat.com, api.rc-backup.com

***********************************/


const mapping = {
  '1Blocker': ['premium']
};

var _0xodF = 'jsjiami.com.v7';

function _0x52ea(_0x3ea8b3, _0x5559a4) {
  var _0x3b9dd1 = _0x3b9d();
  return _0x52ea = function (_0x52eaee, _0x3ab28b) {
    _0x52eaee = _0x52eaee - 0x167;
    var _0xa7cab = _0x3b9dd1[_0x52eaee];
    if (_0x52ea['ggTMmB'] === undefined) {
      var _0x950288 = function (_0x37bf5b) {
        var _0x78e8dd = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/=';
        var _0x192f0b = '', _0x31676d = '';
        for (var _0x400f1d = 0x0, _0x110761, _0x902d8a, _0x2991a3 = 0x0; _0x902d8a = _0x37bf5b.charAt(_0x2991a3++); ~_0x902d8a && (_0x110761 = _0x400f1d % 0x4 ? _0x110761 * 0x40 + _0x902d8a : _0x902d8a, _0x400f1d++ % 0x4) ? _0x192f0b += String.fromCharCode(0xff & _0x110761 >> (-2 * _0x400f1d & 0x6)) : 0x0) {
          _0x902d8a = _0x78e8dd.indexOf(_0x902d8a);
        }
        for (var _0x15ba08 = 0x0, _0x32e6ee = _0x192f0b.length; _0x15ba08 < _0x32e6ee; _0x15ba08++) {
          _0x31676d += '%' + ('00' + _0x192f0b.charCodeAt(_0x15ba08).toString(0x10)).slice(-2);
        }
        return decodeURIComponent(_0x31676d);
      };
      var _0x2a013a = function (_0x5333c4, _0x5070d0) {
        var _0x56aa5a = [], _0x65ca10 = 0x0, _0x87bf3, _0x1bcb39 = '';
        _0x5333c4 = _0x950288(_0x5333c4);
        var _0xbd10e0;
        for (_0xbd10e0 = 0x0; _0xbd10e0 < 0x100; _0xbd10e0++) {
          _0x56aa5a[_0xbd10e0] = _0xbd10e0;
        }
        for (_0xbd10e0 = 0x0; _0xbd10e0 < 0x100; _0xbd10e0++) {
          _0x65ca10 = (_0x65ca10 + _0x56aa5a[_0xbd10e0] + _0x5070d0.charCodeAt(_0xbd10e0 % _0x5070d0.length)) % 0x100;
          _0x87bf3 = _0x56aa5a[_0xbd10e0];
          _0x56aa5a[_0xbd10e0] = _0x56aa5a[_0x65ca10];
          _0x56aa5a[_0x65ca10] = _0x87bf3;
        }
        _0xbd10e0 = 0x0;
        _0x65ca10 = 0x0;
        for (var _0x3e48a9 = 0x0; _0x3e48a9 < _0x5333c4.length; _0x3e48a9++) {
          _0xbd10e0 = (_0xbd10e0 + 0x1) % 0x100;
          _0x65ca10 = (_0x65ca10 + _0x56aa5a[_0xbd10e0]) % 0x100;
          _0x87bf3 = _0x56aa5a[_0xbd10e0];
          _0x56aa5a[_0xbd10e0] = _0x56aa5a[_0x65ca10];
          _0x56aa5a[_0x65ca10] = _0x87bf3;
          _0x1bcb39 += String.fromCharCode(_0x5333c4.charCodeAt(_0x3e48a9) ^ _0x56aa5a[(_0x56aa5a[_0xbd10e0] + _0x56aa5a[_0x65ca10]) % 0x100]);
        }
        return _0x1bcb39;
      };
      _0x52ea['jOOxrV'] = _0x2a013a;
      _0x52ea['ggTMmB'] = !![];
    }
    var _0x46d478 = _0x3b9dd1[0x0], _0x4a3bdb = _0x52eaee + _0x46d478, _0x26d14e = _0x3ea8b3[_0x4a3bdb];
    if (!_0x26d14e) {
      if (_0x52ea['kXBdra'] === undefined) _0x52ea['kXBdra'] = !![];
      _0xa7cab = _0x52ea['jOOxrV'](_0xa7cab, _0x3ab28b);
      _0x3ea8b3[_0x4a3bdb] = _0xa7cab;
    } else _0xa7cab = _0x26d14e;
    return _0xa7cab;
  }, _0x52ea(_0x3ea8b3, _0x5559a4);
}

function _0x3b9d() {
  var _0x1a81c9 = (function () {
    return [
      _0xodF,
      'HWHjxsIjCinpaNOmQyig.ncFoem.bvI7unpGuXlY==',
      'W7rUxZtcImo3pmkL',
      'W5XtWOe1bdBcJ8kCWRCGiCoZW48fW4JdHSoCW5VcG8oz',
      'WQu1zv3cPColnSkeWRivW5aAW4HeqCkcySoJW7RdRmkfWOtdHr8YWOtcLHLj',
      'bSozWP7dQvupW4DCAG',
      'ECoMW6WTy8k/BmkhWRFcO0OUWQG',
      'W4WJfhOLhKlcNIBcQmkBca',
      'WQnuWP3dHSkWyazXmCkyWO7dQ8kU',
      'WQ0Zra',
      'WQn7DCoqrIzkr8ozvCkTjmokW68',
      'W7ajW5JcMmo8o1DuoSkXWPhdLa',
      'sSkxvM/cG8oymx7dVbBdP8oytZDqWQtcPGdcR8kVCtS5oCo/W4vuWO1Z',
      'WQ4JWPNdVCkzWPeFWQbuWQNdHmke',
      '5OcY5zw05l625OMD5yQa5ysr5PEs5O6C772755sp5AgF6Bkh5yMr5lIL77+e6k+85yMx5zE75y+U5OUZ5yIb5lI65lMg5lQ677+C',
      'W57dM8oXWPHEBbDPWPBdSa',
      'xmk6vsiTESo/WPr8W4dcP04'
    ];
  })();
  _0x3b9d = function () { return _0x1a81c9; };
  return _0x1a81c9;
}

var _0x31b760 = _0x52ea;

var ua = $request['headers'][_0x31b760(0x17d, 'HT[1')] || $request[_0x31b760(0x17f, '3PCZ')]['user-agent'];
var obj = JSON.parse($response['body']);

var ddgksf2013 = {
  'is_sandbox': !1,
  'ownership_type': _0x31b760(0x179, 'JPYr'), // 'PURCHASED'
  'billing_issues_detected_at': null,
  'period_type': _0x31b760(0x168, 'XJf3'), // 'normal'
  'expires_date': _0x31b760(0x184, 'xFMr'), // '2099-12-18T01:04:17Z'
  'grace_period_expires_date': null,
  'unsubscribe_detected_at': null,
  'original_purchase_date': _0x31b760(0x192, 'raX*'), // '2022-09-08T01:04:17Z'
  'purchase_date': '2022-09-08T01:04:17Z',
  'store': 'app_store'
};

var ddgksf2021 = {
  'grace_period_expires_date': null,
  'purchase_date': _0x31b760(0x171, '^b@I'), // '2022-09-08T01:04:17Z'
  'product_identifier': _0x31b760(0x194, '!sYB'), // 'com.oneblocker.subscription.yearly'
  'expires_date': _0x31b760(0x184, 'xFMr') 
};

obj['subscriber']['subscriptions'][ddgksf2021['product_identifier']] = ddgksf2013;
obj['subscriber']['entitlements'] = {};
obj['subscriber']['entitlements']['premium'] = ddgksf2021;

console[_0x31b760(0x18a, '!sYB')]('解锁1Blocker会员');
$done({ 'body': JSON.stringify(obj) });

var version_ = 'jsjiami.com.v7';
