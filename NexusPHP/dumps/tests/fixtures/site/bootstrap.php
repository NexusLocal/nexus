<?php

declare(strict_types=1);

use Illuminate\Events\Dispatcher;
use Illuminate\Foundation\Application;
use Illuminate\Foundation\Http\HtmlDumper;
use Symfony\Component\VarDumper\VarDumper;

require __DIR__.'/vendor/autoload.php';

$app = new Application(__DIR__);
$app->instance('events', new Dispatcher());

$mode = $_GET['mode'] ?? 'laravel';

if ($mode === 'laravel') {
    HtmlDumper::register();
}

if ($mode === 'collector') {
    VarDumper::setHandler(static function (mixed $value): void {
        $GLOBALS['collected'][] = $value;
        echo 'COLLECTOR:', json_encode($value), "\n";
    });
}

if ($mode === 'selfreplace') {
    VarDumper::setHandler(static function (mixed $value): void {
        VarDumper::setHandler(static function (mixed $value): void {
            echo 'SECOND:', json_encode($value), "\n";
        });

        echo 'FIRST:', json_encode($value), "\n";
    });
}

return $app;
