// 获取响应体内容
let body = $response.body;

// 移除顶部广告
body = body.replace(/<div id="top-ad-banner".*?<\/div>/g, '');

// 移除中部广告
body = body.replace(/<div id="middle-ad-banner".*?<\/div>/g, '');

// 移除底部广告
body = body.replace(/<div id="bottom-ad-banner".*?<\/div>/g, '');

// 返回修改后的结果
$done({ body });
