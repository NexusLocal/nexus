<?php

declare(strict_types=1);

namespace Illuminate\Foundation\Http;

use Symfony\Component\VarDumper\VarDumper;

final class HtmlDumper
{
    protected static $dumpSourceResolver;

    public static function register(): void
    {
        VarDumper::setHandler(static function (mixed $value): void {
            echo 'LARAVEL:', json_encode($value), ' SOURCE:', json_encode(self::resolveDumpSource(), JSON_UNESCAPED_SLASHES), "\n";
        });
    }

    public static function resolveDumpSourceUsing($callable): void
    {
        static::$dumpSourceResolver = $callable;
    }

    public static function hasResolver(): bool
    {
        return static::$dumpSourceResolver !== null;
    }

    private static function resolveDumpSource(): ?array
    {
        return static::$dumpSourceResolver === null ? null : (static::$dumpSourceResolver)();
    }
}
