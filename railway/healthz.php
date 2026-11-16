<?php
// Railway health check: 200 only when Chamilo is installed and its database answers.
header('Content-Type: text/plain');
header('Cache-Control: no-store');
$env = @file_get_contents('/var/www/chamilo/.env');
$get = static function (string $k) use ($env): string {
    return preg_match('/^'.$k."='?([^'\\n]*)'?\$/m", (string) $env, $m) ? $m[1] : '';
};
if ('1' !== $get('APP_INSTALLED')) {
    http_response_code(503);
    exit("not installed\n");
}
try {
    $pdo = new PDO(
        sprintf('mysql:host=%s;port=%s;dbname=%s', $get('DATABASE_HOST'), $get('DATABASE_PORT'), $get('DATABASE_NAME')),
        $get('DATABASE_USER'),
        $get('DATABASE_PASSWORD'),
        [PDO::ATTR_TIMEOUT => 3, PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
    );
    $pdo->query('SELECT 1 FROM access_url LIMIT 1');
} catch (Throwable $e) {
    http_response_code(503);
    exit("database unavailable\n");
}
echo "ok\n";
