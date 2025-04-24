let body = $response.body;

body = body.replace(/<div id="top-ad-banner".*?<\/div>/g, '');

body = body.replace(/<div id="middle-ad-banner".*?<\/div>/g, '');

body = body.replace(/<div id="bottom-ad-banner".*?<\/div>/g, '');

body = body.replace(/padding-top:.*?;/g, 'padding-top: 0px;'); // 删除顶部空白
body = body.replace(/padding-bottom:.*?;/g, 'padding-bottom: 0px;'); // 删除底部空白
body = body.replace(/<div class="ad-container".*?<\/div>/g, ''); // 针对通用广告容器

$done({ body });
