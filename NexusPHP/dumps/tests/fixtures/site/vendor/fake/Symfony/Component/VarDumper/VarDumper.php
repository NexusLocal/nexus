<?php

declare(strict_types=1);

namespace Symfony\Component\VarDumper;

final class VarDumper
{
    private static $handler;

    public static function dump(mixed $var, ?string $label = null): mixed
    {
        if (self::$handler === null) {
            self::register();
        }

        return (self::$handler)($var, $label);
    }

    public static function setHandler(?callable $callable): ?callable
    {
        $previous = self::$handler;

        if (isset($_SERVER['VAR_DUMPER_FORMAT'])) {
            return $previous;
        }

        self::$handler = $callable;

        return $previous;
    }

    private static function register(): void
    {
        self::$handler = static function (mixed $var, ?string $label = null): void {
            echo 'SYMFONY-DEFAULT:', json_encode($var), "\n";
        };
    }
}
