let body = $response.body;

const adPatterns = [
  /<div id="(?:top|middle|bottom)-ad-banner".*?<\/div>/gs,
  /<div class="ad-container".*?<\/div>/gs
];

adPatterns.forEach(pattern => {
  body = body.replace(pattern, '');
});

body = body.replace(/padding-top:.*?;/g, 'padding-top: 0px;');
body = body.replace(/padding-bottom:.*?;/g, 'padding-bottom: 0px;');

$done({ body });
