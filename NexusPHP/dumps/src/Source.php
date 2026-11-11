<?php

declare(strict_types=1);

namespace Nexus\Dumps;

/*
 * Finds the file and the line of a dump() or a dd() in a trace of debug_backtrace() with
 * DEBUG_BACKTRACE_IGNORE_ARGS.
 */
final class Source
{
    // Methods that pass a dump on to the global dump() or dd(), for example
    // $collection->dump() or the query builder of Laravel.
    private const FORWARDS = ['dump', 'dd', 'dumpRawSql', 'ddRawSql', '__call', '__callStatic', 'forwardCallTo', 'forwardDecoratedCallTo'];

    // A compiled view of Laravel ends with this marker. The marker fits in the last 4 KB of the file.
    private const VIEW_MARKER = '#/\*\*PATH (.+) ENDPATH\*\*/ \?>\s*$#';
    private const TAIL_BYTES = 4096;

    /** @var array<string, ?string> The Blade file of each compiled view, or null for another file. */
    private static array $views = [];

    public static function isDd(array $trace): bool
    {
        foreach ($trace as $frame) {
            if (self::isGlobalCall($frame, ['dd'])) {
                return true;
            }
        }

        return false;
    }

    /** @return array{file: ?string, line: ?int} */
    public static function find(array $trace): array
    {
        $index = self::callIndex($trace);

        if ($index === null) {
            return ['file' => null, 'line' => null];
        }

        while (self::isForward($trace[$index + 1] ?? null)) {
            ++$index;
        }

        return self::located($trace[$index]);
    }

    // The frame of a call to the global dump() or dd(). Its file and line are those of the call.
    // A direct call of VarDumper::dump() comes second.
    private static function callIndex(array $trace): ?int
    {
        foreach ($trace as $index => $frame) {
            if (self::isGlobalCall($frame, ['dump', 'dd'])) {
                return $index;
            }
        }

        foreach ($trace as $index => $frame) {
            if (self::isVarDumperCall($frame)) {
                return $index;
            }
        }

        return null;
    }

    /** @param list<string> $functions */
    private static function isGlobalCall(array $frame, array $functions): bool
    {
        if (isset($frame['class'])) {
            return false;
        }

        return \in_array($frame['function'] ?? null, $functions, true);
    }

    private static function isVarDumperCall(array $frame): bool
    {
        if (($frame['class'] ?? null) !== SiteVarDumper::CLASS_NAME) {
            return false;
        }

        return ($frame['function'] ?? null) === 'dump';
    }

    private static function isForward(?array $frame): bool
    {
        if ($frame === null) {
            return false;
        }

        if (!isset($frame['class'])) {
            return false;
        }

        return \in_array($frame['function'] ?? null, self::FORWARDS, true);
    }

    /** @return array{file: ?string, line: ?int} */
    private static function located(array $frame): array
    {
        $file = isset($frame['file']) ? (string) $frame['file'] : null;
        $view = $file === null ? null : self::viewOf($file);

        // The line of a compiled view does not match the line of its Blade file.
        if ($view !== null) {
            return ['file' => $view, 'line' => null];
        }

        return ['file' => $file, 'line' => isset($frame['line']) ? (int) $frame['line'] : null];
    }

    // A compiled view can be in any folder. So Nexus reads the end of each file once.
    private static function viewOf(string $file): ?string
    {
        if (\array_key_exists($file, self::$views)) {
            return self::$views[$file];
        }

        $size = @\filesize($file);
        $tail = $size === false ? false : @\file_get_contents($file, false, null, \max(0, $size - self::TAIL_BYTES));
        $isView = \is_string($tail) && \preg_match(self::VIEW_MARKER, $tail, $match) === 1;

        return self::$views[$file] = $isView ? $match[1] : null;
    }
}
