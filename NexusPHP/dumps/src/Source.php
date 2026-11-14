<?php

declare(strict_types=1);

namespace Nexus\Dumps;

/*
 * Finds the file and the line of a dump() or a dd() in a trace of debug_backtrace() with
 * DEBUG_BACKTRACE_IGNORE_ARGS. A query or a log line gets the first frame in the code of the site.
 */
final class Source
{
    // Methods that pass a dump on to the global dump() or dd(), for example
    // $collection->dump() or the query builder of Laravel.
    private const FORWARDS = ['dump', 'dd', 'dumpRawSql', 'ddRawSql', '__call', '__callStatic', 'forwardCallTo', 'forwardDecoratedCallTo'];

    // A compiled view of Laravel ends with this marker. The marker fits in the last 4 KB of the file.
    private const VIEW_MARKER = '#/\*\*PATH (.+) ENDPATH\*\*/ \?>\s*$#';
    private const TAIL_BYTES = 4096;

    // The code of the site is mostly in the first frames. So Nexus asks PHP for this many frames
    // first and for the whole trace only when it must.
    public const FRAMES = 40;

    // The code of WordPress itself. Its own files in the root of the site are not in these folders.
    private const WORDPRESS_FOLDERS = ['/wp-includes/', '/wp-admin/'];

    /** @var array<string, ?string> The Blade file of each compiled view, or null for another file. */
    private static array $views = [];

    private static ?string $library = null;

    private static ?string $laravelVendor = null;

    private static ?string $contentFolder = null;

    /** @return array{file: ?string, line: ?int} */
    public static function here(): array
    {
        return self::inSite(\debug_backtrace(\DEBUG_BACKTRACE_IGNORE_ARGS, self::FRAMES));
    }

    // A short trace can end before the code of the site. Then Nexus takes the whole trace.
    /** @return array{file: ?string, line: ?int} */
    public static function inSite(array $trace): array
    {
        $site = self::site();
        [$frame, $final] = self::search($trace, $site);

        if (!$final && \count($trace) >= self::FRAMES) {
            [$frame] = self::search(\debug_backtrace(\DEBUG_BACKTRACE_IGNORE_ARGS), $site);
        }

        return $frame === null ? ['file' => null, 'line' => null] : self::located($frame);
    }

    // PHP gives the file and the line of an error. Nexus takes a trace only when that place is not
    // the source by the rules of the site.
    /** @return array{file: ?string, line: ?int} */
    public static function ofError(string $file, int $line): array
    {
        $site = self::site();
        $isSource = $site['wordPress'] ? self::isInContent($file) : !self::isSkipped($file, $site);

        return $isSource ? self::at($file, $line) : self::here();
    }

    /** @return array{file: ?string, line: ?int} */
    public static function at(string $file, int $line): array
    {
        if ($file === '') {
            return ['file' => null, 'line' => null];
        }

        return self::located(['file' => $file, 'line' => $line]);
    }

    // The rules of the site. In WordPress a theme, a plugin or a mu-plugin on the trace wins.
    // Without one the first file outside the code of WordPress itself is the source, for example
    // wp-blog-header.php.
    /** @return array{vendor: ?string, wordPress: bool} */
    private static function site(): array
    {
        return ['vendor' => self::laravelVendor(), 'wordPress' => \defined('WPINC')];
    }

    // The frame of the source, and if a frame later in the trace cannot change the choice. The
    // caller of the last frame is not known. So that frame is never final.
    /**
     * @param array{vendor: ?string, wordPress: bool} $site
     * @return array{0: ?array, 1: bool}
     */
    private static function search(array $trace, array $site): array
    {
        $fallback = null;
        $last = \array_key_last($trace);

        foreach ($trace as $index => $frame) {
            $file = $frame['file'] ?? null;

            if (!\is_string($file) || self::isSkipped($file, $site)) {
                continue;
            }

            if ($site['wordPress'] && self::isInsideDatabase($trace, $index)) {
                continue;
            }

            if (!$site['wordPress'] || self::isInContent($file)) {
                return [$frame, $index !== $last];
            }

            $fallback ??= $frame;
        }

        return [$fallback, false];
    }

    /** @param array{vendor: ?string, wordPress: bool} $site */
    private static function isSkipped(string $file, array $site): bool
    {
        if (self::isLibrary($file)) {
            return true;
        }

        if ($site['vendor'] !== null && \str_starts_with($file, $site['vendor'])) {
            return true;
        }

        if (!$site['wordPress']) {
            return false;
        }

        foreach (self::WORDPRESS_FOLDERS as $folder) {
            if (\str_contains($file, $folder)) {
                return true;
            }
        }

        return false;
    }

    // WordPress defines WP_CONTENT_DIR when it loads. Bedrock moves the folder to app/.
    private static function isInContent(string $file): bool
    {
        if (self::$contentFolder === null && \defined('WP_CONTENT_DIR')) {
            $folder = (string) \constant('WP_CONTENT_DIR');
            self::$contentFolder = \rtrim(\realpath($folder) ?: $folder, '/').'/';
        }

        if (self::$contentFolder === null) {
            return \str_contains($file, '/wp-content/');
        }

        return \str_starts_with($file, self::$contentFolder);
    }

    // A plugin such as Query Monitor replaces wpdb with a subclass in the content folder. A frame
    // inside a method of that subclass is not the source of a query.
    private static function isInsideDatabase(array $trace, int $index): bool
    {
        $caller = $trace[$index + 1]['class'] ?? null;

        return \is_string($caller) && \is_a($caller, 'wpdb', true);
    }

    // The code of Nexus: prepend.php, hooks.php, src/ and the copy of VarDumper.
    private static function isLibrary(string $file): bool
    {
        $library = self::$library ??= \dirname(__DIR__).'/';

        if (!\str_starts_with($file, $library)) {
            return false;
        }

        $name = \substr($file, \strlen($library));

        return \in_array($name, ['prepend.php', 'hooks.php'], true)
            || \str_starts_with($name, 'src/')
            || \str_starts_with($name, 'vendor/');
    }

    // The vendor folder of a Laravel site. Nexus asks again until the application exists.
    private static function laravelVendor(): ?string
    {
        if (self::$laravelVendor !== null) {
            return self::$laravelVendor;
        }

        $basePath = Laravel::basePath();

        if ($basePath === '') {
            return null;
        }

        return self::$laravelVendor = \rtrim(\realpath($basePath) ?: $basePath, '/').'/vendor/';
    }

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
