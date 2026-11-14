<?php

declare(strict_types=1);

namespace Nexus\Dumps;

/*
 * The request object of the wire format (Part 3). Each event carries it in full. So nexusd can
 * join the events in any order.
 */
final class Request
{
    // Each line carries the request object. A very long command or URL would leave no room for the
    // entries in a line of 1 MB. So the object keeps the start of it with a marker.
    public const TEXT_BYTES = 4096;
    public const CUT_MARKER = ' [...]';

    public static function describe(array $server, bool $cli): array
    {
        $common = [
            'id' => self::newId(),
            'root' => self::root($server, $cli),
            'started' => (float) ($server['REQUEST_TIME_FLOAT'] ?? \microtime(true)),
            'pid' => \getmypid() ?: null,
        ];

        if ($cli) {
            return [
                'kind' => 'command',
                'command' => self::shortened(self::command($server)),
                'cwd' => \getcwd() ?: null,
            ] + $common;
        }

        $hostHeader = (string) ($server['HTTP_HOST'] ?? $server['SERVER_NAME'] ?? 'localhost');

        return [
            'kind' => 'http',
            'method' => (string) ($server['REQUEST_METHOD'] ?? 'GET'),
            'url' => self::shortened(self::scheme($server)."://{$hostHeader}".($server['REQUEST_URI'] ?? '/')),
            'host' => \strtolower(\preg_replace('/:\d+$/', '', $hostHeader) ?? $hostHeader),
        ] + $common;
    }

    private static function shortened(string $text): string
    {
        if (\strlen($text) <= self::TEXT_BYTES) {
            return $text;
        }

        return \mb_strcut($text, 0, self::TEXT_BYTES, 'UTF-8').self::CUT_MARKER;
    }

    // A job of a worker is a request of its own. It keeps the command or the URL, the folders and
    // the pid of the request that runs it. So nexusd finds the same site.
    public static function forJob(array $parent, array $job): array
    {
        return [
            'id' => self::newId(),
            'kind' => 'job',
            'started' => \microtime(true),
            'job' => \array_filter($job, static fn (mixed $value): bool => $value !== null),
        ] + $parent;
    }

    private static function newId(): string
    {
        return \bin2hex(\random_bytes(6));
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
