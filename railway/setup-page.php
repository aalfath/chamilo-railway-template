<?php
// Router for the temporary server that answers on PORT during Chamilo's first install
// (2-3 minutes), so Railway's health check doesn't time out. Replaced by Apache afterwards.
if ('/healthz' === parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH)) {
    header('Content-Type: text/plain');
    echo "installing\n";
    return true;
}
http_response_code(503);
header('Retry-After: 30');
header('Content-Type: text/html; charset=utf-8');
echo '<!doctype html><meta http-equiv="refresh" content="20"><title>Chamilo is being installed</title>',
     '<body style="font-family:sans-serif;max-width:40em;margin:4em auto">',
     '<h1>Chamilo is being installed</h1><p>The first start takes 2 to 3 minutes. This page reloads by itself.</p>';
return true;
