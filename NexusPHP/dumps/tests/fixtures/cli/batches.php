<?php

declare(strict_types=1);

$mode = $argv[1] ?? 'count';

if ($mode === 'count') {
    for ($number = 1; $number <= 120; ++$number) {
        trigger_error("Warning {$number}.", E_USER_WARNING);
    }
}

if ($mode === 'time') {
    trigger_error('First.', E_USER_WARNING);
    usleep(1_100_000);
    trigger_error('Second.', E_USER_WARNING);
    trigger_error('Third.', E_USER_WARNING);
}

if ($mode === 'size') {
    for ($number = 1; $number <= 60; ++$number) {
        trigger_error(str_repeat(chr(97 + $number % 26), 60_000), E_USER_WARNING);
    }
}

echo "SCRIPT END\n";
