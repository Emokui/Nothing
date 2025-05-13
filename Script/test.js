// ==Script==
// @name         Host Header Rewriter
// ==/Script==
let newHost = $argument.host;
$httpRequest.headers['Host'] = newHost;
$done({headers: $httpRequest.headers});
