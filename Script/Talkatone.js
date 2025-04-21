// 获取响应体内容
let body = $response.body;

// 移除顶部广告
body = body.replace(/<div id="top-ad-banner".*?<\/div>/g, '');

// 移除中部广告
body = body.replace(/<div id="middle-ad-banner".*?<\/div>/g, '');

// 移除底部广告
body = body.replace(/<div id="bottom-ad-banner".*?<\/div>/g, '');

// 优化布局
body = body.replace(/padding-top:.*?;/g, 'padding-top: 0px;'); // 删除顶部空白
body = body.replace(/padding-bottom:.*?;/g, 'padding-bottom: 0px;'); // 删除底部空白
body = body.replace(/<div class="ad-container".*?<\/div>/g, ''); // 针对通用广告容器

// 返回修改后的结果
$done({ body });
