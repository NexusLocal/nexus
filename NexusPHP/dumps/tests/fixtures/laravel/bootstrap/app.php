<?php

declare(strict_types=1);

use Illuminate\Config\Repository;
use Illuminate\Database\Connection;
use Illuminate\Events\Dispatcher;
use Illuminate\Foundation\Application;
use Illuminate\Log\LogManager;

$app = new Application(dirname(__DIR__));
$events = new Dispatcher();

$app->instance('events', $events);
$app->instance('log', new LogManager($events));
$app->instance('db', ['mysql' => new Connection('mysql', $events), 'legacy' => new Connection('legacy', $events)]);
$app->instance('config', new Repository(['queue' => ['connections' => [
    'sync' => ['driver' => 'sync'],
    'redis' => ['driver' => 'redis', 'queue' => 'default'],
]]]));

// As HandleExceptions of Laravel: a fatal error becomes a log line of the application.
register_shutdown_function(static function () use ($app): void {
    $error = error_get_last();

    if ($error !== null && in_array($error['type'], [E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR], true)) {
        $app->make('log')->error($error['message']);
    }
});

return $app;
