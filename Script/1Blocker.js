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

var _0xodF='jsjiami.com.v7';

function _0x52ea(_0x3ea8b3,_0x5559a4){
    var _0x3b9dd1=_0x3b9d();
    return _0x52ea=function(_0x52eaee,_0x3ab28b){
        _0x52eaee=_0x52eaee-0x167;
        var _0xa7cab=_0x3b9dd1[_0x52eaee];
        
        if(_0x52ea['ggTMmB']===undefined){
            var _0x950288=function(_0x37bf5b){
                var _0x78e8dd='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/=';
                var _0x192f0b='',_0x31676d='';
                
                for(var _0x400f1d=0x0,_0x110761,_0x902d8a,_0x2991a3=0x0;_0x902d8a=_0x37bf5b['charAt'](_0x2991a3++);~_0x902d8a&&(_0x110761=_0x400f1d%0x4?_0x110761*0x40+_0x902d8a:_0x902d8a,_0x400f1d++%0x4)?_0x192f0b+=String['fromCharCode'](0xff&_0x110761>>(-0x2*_0x400f1d&0x6)):0x0){
                    _0x902d8a=_0x78e8dd['indexOf'](_0x902d8a);
                }
                
                for(var _0x15ba08=0x0,_0x32e6ee=_0x192f0b['length'];_0x15ba08<_0x32e6ee;_0x15ba08++){
                    _0x31676d+='%'+('00'+_0x192f0b['charCodeAt'](_0x15ba08)['toString'](0x10))['slice'](-0x2);
                }
                return decodeURIComponent(_0x31676d);
            };
            
            var _0x2a013a=function(_0x5333c4,_0x5070d0){
                var _0x56aa5a=[],_0x65ca10=0x0,_0x87bf3,_0x1bcb39='';
                _0x5333c4=_0x950288(_0x5333c4);
                
                var _0xbd10e0;
                for(_0xbd10e0=0x0;_0xbd10e0<0x100;_0xbd10e0++){
                    _0x56aa5a[_0xbd10e0]=_0xbd10e0;
                }
                
                for(_0xbd10e0=0x0;_0xbd10e0<0x100;_0xbd10e0++){
                    _0x65ca10=(_0x65ca10+_0x56aa5a[_0xbd10e0]+_0x5070d0['charCodeAt'](_0xbd10e0%_0x5070d0['length']))%0x100;
                    _0x87bf3=_0x56aa5a[_0xbd10e0];
                    _0x56aa5a[_0xbd10e0]=_0x56aa5a[_0x65ca10];
                    _0x56aa5a[_0x65ca10]=_0x87bf3;
                }
                
                _0xbd10e0=0x0;_0x65ca10=0x0;
                for(var _0x3e48a9=0x0;_0x3e48a9<_0x5333c4['length'];_0x3e48a9++){
                    _0xbd10e0=(_0xbd10e0+0x1)%0x100;
                    _0x65ca10=(_0x65ca10+_0x56aa5a[_0xbd10e0])%0x100;
                    _0x87bf3=_0x56aa5a[_0xbd10e0];
                    _0x56aa5a[_0xbd10e0]=_0x56aa5a[_0x65ca10];
                    _0x56aa5a[_0x65ca10]=_0x87bf3;
                    _0x1bcb39+=String['fromCharCode'](_0x5333c4['charCodeAt'](_0x3e48a9)^_0x56aa5a[(_0x56aa5a[_0xbd10e0]+_0x56aa5a[_0x65ca10])%0x100]);
                }
                return _0x1bcb39;
            };
            
            _0x52ea['jOOxrV']=_0x2a013a;
            _0x3ea8b3=arguments;
            _0x52ea['ggTMmB']=!![];
        }
        
        var _0x46d478=_0x3b9dd1[0x0];
        var _0x4a3bdb=_0x52eaee+_0x46d478;
        var _0x26d14e=_0x3ea8b3[_0x4a3bdb];
        
        return!_0x26d14e?(_0x52ea['kXBdra']===undefined&&(_0x52ea['kXBdra']=!![]),_0xa7cab=_0x52ea['jOOxrV'](_0xa7cab,_0x3ab28b),_0x3ea8b3[_0x4a3bdb]=_0xa7cab):_0xa7cab=_0x26d14e,_0xa7cab;
    },_0x52ea(_0x3ea8b3,_0x5559a4);
}

function _0x3b9d(){
    var _0x1a81c9=[
        'jsjiami.com.v7',
        'HsKAwozDhuiNvOWOpueVi+aKmuS7nOeTq8K4eMKyw5bCocKK',
        'User-Agent',
        'user-agent',
        'body',
        'subscriber',
        'original_application_version',
        'subscriptions',
        'entitlements',
        'Apple',
        '1Blocker',
        'icloud_premium',
        'com.apple.icloud.premium',
        'blocker_premium',
        'com.salavat.1blocker.premium',
        'PURCHASED',
        'normal',
        '2099-12-18T01:04:17Z',
        '2022-09-08T01:04:17Z',
        'app_store',
        'premium',
        'find',
        'includes',
        'keys',
        'product_identifier',
        'stringify'
    ];
    
    _0x3b9d=function(){return _0x1a81c9;};
    return _0x3b9d();
}

var _0x31b760=_0x52ea;

(function(_0x743d38,_0x1bf72e,_0x279e3b,_0x9f43dc,_0xe2a57e,_0x2b8876,_0x3d39f0){
    return _0x743d38=_0x743d38>>0x8,_0x2b8876='hs',_0x3d39f0='hs',
    function(_0x65a64c,_0x1f16db,_0x210d0c,_0x3978be,_0x357e70){
        var _0x5b590d=_0x52ea;
        _0x3978be='tfi',_0x2b8876=_0x3978be+_0x2b8876,_0x357e70='up',_0x3d39f0+=_0x357e70,_0x2b8876=_0x210d0c(_0x2b8876),_0x3d39f0=_0x210d0c(_0x3d39f0),_0x210d0c=0x0;
        
        var _0xc23658=_0x65a64c();
        while(!![]&&--_0x9f43dc+_0x1f16db){
            try{
                _0x3978be=-parseInt(_0x5b590d(0x17c,'DplK'))/0x1+parseInt(_0x5b590d(0x169,'CQUZ'))/0x2*(-parseInt(_0x5b590d(0x188,'LaW^'))/0x3)+parseInt(_0x5b590d(0x191,'7yWD'))/0x4+parseInt(_0x5b590d(0x178,'!FyN'))/0x5*(parseInt(_0x5b590d(0x195,'VEJ('))/0x6)+-parseInt(_0x5b590d(0x196,'7yWD'))/0x7*(-parseInt(_0x5b590d(0x183,'XJf3'))/0x8)+-parseInt(_0x5b590d(0x189,'I8D4'))/0x9+parseInt(_0x5b590d(0x18b,'aWAg'))/0xa*(parseInt(_0x5b590d(0x16d,'VEJ('))/0xb);
            }catch(_0x4d5ec9){
                _0x3978be=_0x210d0c;
            }finally{
                _0x357e70=_0xc23658[_0x2b8876]();
                if(_0x743d38<=_0x9f43dc)_0x210d0c?_0xe2a57e?_0x3978be=_0x357e70:_0xe2a57e=_0x357e70:_0x210d0c=_0x357e70;
                else{
                    if(_0x210d0c==_0xe2a57e['replace'](/[XgnNbFyYlCuIOpxeQGWH=]/g,'')){
                        if(_0x3978be===_0x1f16db){
                            _0xc23658['un'+_0x2b8876](_0x357e70);
                            break;
                        }
                        _0xc23658[_0x3d39f0](_0x357e70);
                    }
                }
            }
        }
    }(_0x279e3b,_0x1bf72e,function(_0x224e4d,_0x54cf0f,_0x3dc40b,_0x3427ec,_0x4f99ea,_0x1742b5,_0xfbe07a){
        return _0x54cf0f='\x73\x70\x6c\x69\x74',_0x224e4d=arguments[0x0],_0x224e4d=_0x224e4d[_0x54cf0f](''),_0x3dc40b='\x72\x65\x76\x65\x72\x73\x65',_0x224e4d=_0x224e4d[_0x3dc40b]('\x76'),_0x3427ec='\x6a\x6f\x69\x6e',(0x192085,_0x224e4d[_0x3427ec](''));
    });
}(0xc900,0x5ac5b,_0x3b9d,0xcb),_0x3b9d)&&(_0xodF=0xb35);

// 核心执行逻辑(混淆)
var ua=$request[_0x31b760(0x17d,'HT[1')][_0x31b760(0x169,'CQUZ')]||$request[_0x31b760(0x17f,'3PCZ')][_0x31b760(0x16f,'user-agent')];
var obj=JSON[_0x31b760(0x175,'parse')]($response[_0x31b760(0x177,'body')]);

obj[_0x31b760(0x174,'subscriber')][_0x31b760(0x18c,'original_application_version')]="1.0";

var subscriptionData={
    'is_sandbox':![],
    'ownership_type':_0x31b760(0x179,'PURCHASED'),
    'billing_issues_detected_at':null,
    'period_type':_0x31b760(0x168,'normal'),
    'expires_date':_0x31b760(0x184,'2099-12-18T01:04:17Z'),
    'grace_period_expires_date':null,
    'unsubscribe_detected_at':null,
    'original_purchase_date':_0x31b760(0x192,'2022-09-08T01:04:17Z'),
    'purchase_date':_0x31b760(0x171,'2022-09-08T01:04:17Z'),
    'store':_0x31b760(0x194,'app_store')
};

var entitlementData={
    'grace_period_expires_date':null,
    'purchase_date':_0x31b760(0x193,'2022-09-08T01:04:17Z'),
    'product_identifier':_0x31b760(0x185,'premium'),
    'expires_date':_0x31b760(0x180,'2099-12-18T01:04:17Z')
};

const mapping={'Apple':[_0x31b760(0x172,'icloud_premium'),_0x31b760(0x182,'com.apple.icloud.premium')],'1Blocker':[_0x31b760(0x16c,'blocker_premium'),_0x31b760(0x190,'com.salavat.1blocker.premium')]};

const match=Object[_0x31b760(0x16b,'keys')](mapping)[_0x31b760(0x181,'find')](_0x2d4787=>ua[_0x31b760(0x16a,'includes')](_0x2d4787));

if(match){
    const [entitlementKey,productId]=mapping[match];
    if(productId){
        entitlementData[_0x31b760(0x18d,'product_identifier')]=productId;
        obj[_0x31b760(0x18e,'subscriber')][_0x31b760(0x17a,'subscriptions')][productId]=subscriptionData;
    }else{
        obj[_0x31b760(0x186,'subscriber')][_0x31b760(0x17b,'subscriptions')][_0x31b760(0x178,'premium')]=subscriptionData;
    }
    obj[_0x31b760(0x189,'subscriber')][_0x31b760(0x16d,'entitlements')]={};
    obj[_0x31b760(0x195,'subscriber')][_0x31b760(0x196,'entitlements')][entitlementKey]=entitlementData;
}else{
    obj[_0x31b760(0x183,'subscriber')][_0x31b760(0x188,'subscriptions')][_0x31b760(0x18b,'premium')]=subscriptionData;
    obj[_0x31b760(0x17c,'subscriber')][_0x31b760(0x191,'entitlements')][_0x31b760(0x178,'premium')]=entitlementData;
}

$done({'body':JSON[_0x31b760(0x18f,'stringify')](obj)});

var version_='jsjiami.com.v7';