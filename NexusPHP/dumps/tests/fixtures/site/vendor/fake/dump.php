<?php

declare(strict_types=1);

use Symfony\Component\VarDumper\VarDumper;

if (!function_exists('dump')) {
    function dump(mixed ...$vars): mixed
    {
        foreach ($vars as $key => $value) {
            VarDumper::dump($value, is_int($key) ? null : (string) $key);
        }

        return $vars[0] ?? null;
    }
}

if (!function_exists('dd')) {
    function dd(mixed ...$vars): never
    {
        if (!headers_sent()) {
            header('HTTP/1.1 500 Internal Server Error');
        }

        foreach ($vars as $value) {
            VarDumper::dump($value);
        }

        exit(1);
    }
}
