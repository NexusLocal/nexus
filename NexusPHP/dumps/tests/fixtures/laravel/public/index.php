<?php

declare(strict_types=1);

use Illuminate\Foundation\Bootstrap\BootProviders;

require __DIR__.'/../vendor/autoload.php';

$app = require __DIR__.'/../bootstrap/app.php';
$app->bootstrapWith([BootProviders::class]);

App\Actions::run($app, $_GET['action'] ?? 'none');

$nexusClasses = array_values(array_filter(
    get_declared_classes(),
    static fn (string $class): bool => str_starts_with($class, 'Nexus\\'),
));

$loaders = array_map(
    static fn (callable $loader): string => $loader instanceof Closure ? basename((new ReflectionFunction($loader))->getFileName()) : implode('::', (array) $loader),
    spl_autoload_functions(),
);

echo 'STATE:', json_encode([
    'nexusClasses' => $nexusClasses,
    'loaders' => $loaders,
    'booted' => $app->booted,
    'written' => $GLOBALS['written'] ?? [],
]), "\n";
