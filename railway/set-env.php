<?php
// php set-env.php FILE KEY VALUE: replace or append KEY='VALUE' in a dotenv file.
[, $file, $key, $value] = $argv;
$value = str_replace("'", '', $value);
$line = $key."='".$value."'";
$content = file_exists($file) ? file_get_contents($file) : '';
$pattern = '/^'.preg_quote($key, '/').'=.*$/m';
if (preg_match($pattern, $content)) {
    $content = preg_replace_callback($pattern, static fn () => $line, $content);
} else {
    $content = rtrim($content)."\n".$line."\n";
}
file_put_contents($file, $content);
