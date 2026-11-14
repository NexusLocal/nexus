<?php

declare(strict_types=1);

spl_autoload_register(static function (string $class): void {
    $GLOBALS['askedClasses'][] = $class;
});

$action = $_GET['action'] ?? 'none';

if ($action === 'dump') {
    dump(['plain' => true]);
}

if ($action === 'dd') {
    dd('stop here');
}

$nexusClasses = array_values(array_filter(
    get_declared_classes(),
    static fn (string $class): bool => str_starts_with($class, 'Nexus\\'),
));

$errorHandler = set_error_handler(static fn (): bool => false);
restore_error_handler();

echo 'STATE:', json_encode([
    'nexusClasses' => $nexusClasses,
    'dump' => function_exists('dump'),
    'askedClasses' => $GLOBALS['askedClasses'] ?? [],
    'errorHandler' => $errorHandler !== null,
]), "\n";
