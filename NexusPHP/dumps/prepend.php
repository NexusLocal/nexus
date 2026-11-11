<?php

declare(strict_types=1);

/*
 * Nexus runs this file before each PHP script through the stub of the PHP version (see "Stub
 * contract" in docs/dump-viewer-build.md). PHP runs it for every request of every site. So it only
 * defines dump() and dd(). The library loads at the first dump.
 */

namespace Nexus\Dumps {
    // The one check of the library for a command. The embed SAPI counts as a command, as in
    // VarDumper of Symfony.
    function isCli(): bool
    {
        return \in_array(\PHP_SAPI, ['cli', 'phpdbg', 'embed'], true);
    }

    // PHP finds a relative prepend file through include_path, as without Nexus. An absolute path
    // stays as it is.
    function userPrepend(): ?string
    {
        $file = SETTINGS['userPrepend'] ?? null;

        if (!\is_string($file)) {
            return null;
        }

        if ($file === '') {
            return null;
        }

        if (!\str_starts_with($file, '/')) {
            $file = \stream_resolve_include_path($file);
        }

        if ($file === false) {
            return null;
        }

        return \is_file($file) ? $file : null;
    }

    // A class name of this namespace that does not exist must not stop the script with an error.
    function library(): void
    {
        static $registered = false;

        if ($registered) {
            return;
        }

        $registered = true;

        \spl_autoload_register(static function (string $class): void {
            if (!\str_starts_with($class, 'Nexus\\Dumps\\')) {
                return;
            }

            $name = \str_replace('\\', '/', \substr($class, 12));
            $file = \str_starts_with($name, 'VarDumper/')
                ? __DIR__.'/vendor/var-dumper/'.\substr($name, 10).'.php'
                : __DIR__."/src/{$name}.php";

            if (\is_file($file)) {
                require $file;
            }
        });
    }
}

namespace {
    if (!\defined('Nexus\Dumps\SETTINGS')) {
        return;
    }

    // The prepend file of the user runs first and in the global scope, as PHP runs it without Nexus.
    // A variable here would be a global variable of the site. So the path is found two times.
    if (\Nexus\Dumps\userPrepend() !== null) {
        include_once \Nexus\Dumps\userPrepend();
    }

    if ((\Nexus\Dumps\SETTINGS['version'] ?? null) !== 1) {
        return;
    }

    // The site loads its own dump() later. Each such file of a package checks function_exists()
    // first, as the dump.php file of Symfony does.
    if (!\function_exists('dump')) {
        function dump(mixed ...$vars): mixed
        {
            \Nexus\Dumps\library();

            return \Nexus\Dumps\Catcher::instance()->dumpValues($vars);
        }
    }

    if (!\function_exists('dd')) {
        function dd(mixed ...$vars): never
        {
            \Nexus\Dumps\library();
            \Nexus\Dumps\Catcher::instance()->dumpAndExit($vars);
        }
    }
}
