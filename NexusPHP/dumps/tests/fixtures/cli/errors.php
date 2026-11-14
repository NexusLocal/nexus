<?php

declare(strict_types=1);

trigger_error('A user warning.', E_USER_WARNING);
$last = error_get_last()['message'] ?? null;

@trigger_error('A silenced warning.', E_USER_WARNING);

error_reporting(E_ALL & ~E_USER_NOTICE);
trigger_error('A notice that error_reporting() leaves out.', E_USER_NOTICE);
error_reporting(E_ALL);

trigger_error('An old function.', E_USER_DEPRECATED);

$list = [];
$value = $list['missing'] ?? null;
$value = $list['missing'];

$nexusClasses = array_values(array_filter(
    get_declared_classes(),
    static fn (string $class): bool => str_starts_with($class, 'Nexus\\'),
));

echo 'STATE:', json_encode([
    'last' => $last,
    'previousHandler' => $GLOBALS['previousHandler'] ?? [],
    'nexusClasses' => $nexusClasses !== [],
]), "\n";
