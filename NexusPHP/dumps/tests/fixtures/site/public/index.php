<?php

declare(strict_types=1);

use Illuminate\Foundation\Http\HtmlDumper;
use Symfony\Component\VarDumper\VarDumper;

if (isset($_GET['format'])) {
    $_SERVER['VAR_DUMPER_FORMAT'] = $_GET['format'];
}

$app = require __DIR__.'/../bootstrap.php';

$action = $_GET['action'] ?? 'dump';

if ($action === 'dd') {
    dd(['order' => 7]);
}

if ($action === 'dump') {
    dump(['order' => 7]);
}

if ($action === 'twice') {
    dump(['order' => 7], ['order' => 8]);
    dump(['order' => 9]);
}

if ($action === 'direct') {
    dump(['order' => 7]);
    VarDumper::dump(['direct' => true]);
}

if ($action === 'reset') {
    dump(['order' => 7]);
    VarDumper::setHandler(null);
    dump(['order' => 8]);
}

if ($action === 'wrapper') {
    dump(['order' => 7]);

    $previous = null;
    $previous = VarDumper::setHandler(static function (mixed $value, ?string $label = null) use (&$previous): void {
        echo "WRAPPER:\n";
        $previous($value, $label);
    });

    dump(['order' => 8]);
}

$nexusClasses = array_values(array_filter(
    get_declared_classes(),
    static fn (string $class): bool => str_starts_with($class, 'Nexus\\'),
));

echo 'STATE:', json_encode([
    'nexusClasses' => $nexusClasses,
    'resolver' => class_exists(HtmlDumper::class, false) ? HtmlDumper::hasResolver() : false,
    'collected' => $GLOBALS['collected'] ?? [],
]), "\n";

echo "PAGE END\n";
