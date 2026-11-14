<?php

declare(strict_types=1);

namespace Nexus\Dumps;

/*
 * The SQL of a query with its values in the place of each ?. Laravel 10 has no toRawSql() on its
 * query event, and toRawSql() fails on a binary value. A ? inside a string literal and the ?? of
 * PostgreSQL stay as they are, as in Laravel.
 */
final class Sql
{
    private const PLACES = "/'(?:[^'\\\\]|\\\\.|'')*'|\\?\\?|\\?/s";

    public static function withBindings(string $sql, array $bindings): string
    {
        $values = \array_values($bindings);
        $index = 0;

        $result = \preg_replace_callback(self::PLACES, static function (array $match) use ($values, &$index): string {
            if ($match[0] !== '?') {
                return $match[0];
            }

            if (!\array_key_exists($index, $values)) {
                return '?';
            }

            return self::literal($values[$index++]);
        }, $sql);

        return $result ?? $sql;
    }

    private static function literal(mixed $value): string
    {
        return match (true) {
            $value === null => 'null',
            \is_bool($value) => $value ? '1' : '0',
            \is_int($value), \is_float($value) => (string) $value,
            $value instanceof \BackedEnum => self::literal($value->value),
            $value instanceof \DateTimeInterface => "'{$value->format('Y-m-d H:i:s')}'",
            \is_string($value) => self::stringLiteral($value),
            $value instanceof \Stringable => self::stringLiteral((string) $value),
            default => '?',
        };
    }

    // A binary value shows as hex, as MySQL writes it. The text of the query stops at 64 KB. So
    // a longer value is cut first.
    private static function stringLiteral(string $value): string
    {
        [$value] = Renderer::cut($value);

        if (\str_contains($value, "\0") || \preg_match('//u', $value) !== 1) {
            return "x'".\bin2hex($value)."'";
        }

        $escaped = \str_replace("'", "''", $value);

        return "'{$escaped}'";
    }
}
