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

    function hasUserPrepend(): bool
    {
        $file = SETTINGS['userPrepend'] ?? null;

        if (!\is_string($file)) {
            return false;
        }

        return \is_file($file);
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
    if (\Nexus\Dumps\hasUserPrepend()) {
        include_once \Nexus\Dumps\SETTINGS['userPrepend'];
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
