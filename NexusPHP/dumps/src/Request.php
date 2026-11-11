<?php

declare(strict_types=1);

namespace Nexus\Dumps;

/*
 * The request object of the wire format (Part 3). Each event carries it in full. So nexusd can
 * join the events in any order.
 */
final class Request
{
    public static function describe(array $server, bool $cli): array
    {
        $common = [
            'id' => \bin2hex(\random_bytes(6)),
            'root' => self::root($server, $cli),
            'started' => (float) ($server['REQUEST_TIME_FLOAT'] ?? \microtime(true)),
            'pid' => \getmypid() ?: null,
        ];

        if ($cli) {
            return [
                'kind' => 'command',
                'command' => self::command($server),
                'cwd' => \getcwd() ?: null,
            ] + $common;
        }

        $hostHeader = (string) ($server['HTTP_HOST'] ?? $server['SERVER_NAME'] ?? 'localhost');

        return [
            'kind' => 'http',
            'method' => (string) ($server['REQUEST_METHOD'] ?? 'GET'),
            'url' => self::scheme($server)."://{$hostHeader}".($server['REQUEST_URI'] ?? '/'),
            'host' => \strtolower(\preg_replace('/:\d+$/', '', $hostHeader) ?? $hostHeader),
        ] + $common;
    }

    // nexusd finds the site or the workspace from the host first and then from this folder.
    private static function root(array $server, bool $cli): ?string
    {
        $folder = $cli ? \getcwd() : (string) ($server['DOCUMENT_ROOT'] ?? '');

        if ($folder === false) {
            return null;
        }

        if ($folder === '') {
            return null;
        }

        return \realpath($folder) ?: $folder;
    }

    private static function scheme(array $server): string
    {
        $https = \strtolower((string) ($server['HTTPS'] ?? ''));

        if ($https === '') {
            return 'http';
        }

        if ($https === 'off') {
            return 'http';
        }

        return 'https';
    }

    private static function command(array $server): string
    {
        $arguments = \is_array($server['argv'] ?? null) ? $server['argv'] : [];
        $words = \array_map(
            static fn (mixed $argument): string => self::quoted((string) $argument),
            $arguments,
        );

        return \implode(' ', ['php', ...$words]);
    }

    private static function quoted(string $argument): string
    {
        return \preg_match('#^[\w./:=@%+,-]+$#', $argument) === 1
            ? $argument
            : \escapeshellarg($argument);
    }
}
