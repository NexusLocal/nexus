<?php

declare(strict_types=1);

namespace Nexus\Dumps;

/*
 * What Nexus needs from a Laravel application. Nexus uses only classes and objects that the
 * application has already made.
 */
final class Laravel
{
    private const CONTAINER = 'Illuminate\Container\Container';
    private const COMMAND_FINISHED = 'Illuminate\Console\Events\CommandFinished';
    private const DUMPERS = ['Illuminate\Foundation\Http\HtmlDumper', 'Illuminate\Foundation\Console\CliDumper'];

    public static ?int $exitCode = null;

    private static ?object $app = null;

    // PHP gives a shutdown function no exit code. So the end event of an artisan command takes it
    // from Laravel.
    public static function listenForExitCode(): void
    {
        if (!isCli()) {
            return;
        }

        $app = self::app();

        if ($app === null) {
            return;
        }

        if (!\method_exists($app, 'bound')) {
            return;
        }

        if (!$app->bound('events')) {
            return;
        }

        $app->make('events')->listen(self::COMMAND_FINISHED, static function (object $event): void {
            self::$exitCode = (int) $event->exitCode;
        });
    }

    // Laravel finds the source of a dump through the dump.php file of Symfony in the trace. dump()
    // of Nexus takes the place of that file. So Nexus gives Laravel the source for the time of the
    // call, unless the application has its own resolver.
    /** @param array{file: ?string, line: ?int} $source */
    public static function withSource(array $source, \Closure $call): void
    {
        $dumpers = $source['file'] === null ? [] : self::dumpersWithoutResolver();

        if ($dumpers === []) {
            $call();

            return;
        }

        $resolved = [$source['file'], self::relative($source['file']), $source['line']];
        $resolver = static fn (): array => $resolved;

        foreach ($dumpers as $dumper) {
            $dumper::resolveDumpSourceUsing($resolver);
        }

        try {
            $call();
        } finally {
            foreach ($dumpers as $dumper) {
                $dumper::resolveDumpSourceUsing(null);
            }
        }
    }

    /** @return list<string> */
    private static function dumpersWithoutResolver(): array
    {
        $dumpers = [];

        foreach (self::DUMPERS as $dumper) {
            if (!\class_exists($dumper, false)) {
                continue;
            }

            if (!\method_exists($dumper, 'resolveDumpSourceUsing')) {
                continue;
            }

            if (self::staticProperty($dumper, 'dumpSourceResolver') === null) {
                $dumpers[] = $dumper;
            }
        }

        return $dumpers;
    }

    private static function relative(string $file): string
    {
        $basePath = \rtrim(self::basePath(), '/');

        if ($basePath === '') {
            return $file;
        }

        if (!\str_starts_with($file, "{$basePath}/")) {
            return $file;
        }

        return \substr($file, \strlen($basePath) + 1);
    }

    private static function basePath(): string
    {
        $app = self::app();

        if ($app === null) {
            return '';
        }

        if (!\method_exists($app, 'basePath')) {
            return '';
        }

        return (string) $app->basePath();
    }

    // Container::getInstance() makes a new container when there is none. So Nexus reads the
    // instance that the application made. It keeps the instance after the first time.
    private static function app(): ?object
    {
        if (self::$app !== null) {
            return self::$app;
        }

        if (!\class_exists(self::CONTAINER, false)) {
            return null;
        }

        $instance = self::staticProperty(self::CONTAINER, 'instance');

        return self::$app = \is_object($instance) ? $instance : null;
    }

    // Laravel keeps these values in protected static properties.
    private static function staticProperty(string $class, string $property): mixed
    {
        try {
            return \Closure::bind(static fn (): mixed => $class::$$property, null, $class)();
        } catch (\Throwable) {
            return null;
        }
    }
}
