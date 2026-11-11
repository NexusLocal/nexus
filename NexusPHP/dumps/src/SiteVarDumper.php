<?php

declare(strict_types=1);

namespace Nexus\Dumps;

/*
 * The VarDumper of the site (symfony/var-dumper). Nexus puts its handler in front of the handler
 * of the site, as Ignition does. The handler of the site then runs only when the dump shows in the
 * page.
 */
final class SiteVarDumper
{
    public const CLASS_NAME = 'Symfony\Component\VarDumper\VarDumper';

    private const SCALAR_STUB = 'Symfony\Component\VarDumper\Caster\ScalarStub';

    private const COMPOSER = 'Composer\Autoload\ClassLoader';

    private static ?\Closure $previous = null;

    // Only Composer may look for the class. The autoloader of a WordPress plugin can break on a
    // name that it does not know.
    public static function exists(): bool
    {
        if (\class_exists(self::CLASS_NAME, false)) {
            return true;
        }

        if (!\class_exists(self::COMPOSER, false)) {
            return false;
        }

        return \class_exists(self::CLASS_NAME);
    }

    // VarDumper ignores setHandler() while this key is set.
    public static function isBlocked(): bool
    {
        return isset($_SERVER['VAR_DUMPER_FORMAT']);
    }

    public static function format(): string
    {
        return (string) ($_SERVER['VAR_DUMPER_FORMAT'] ?? '');
    }

    // The site can set a new handler at any time, for example the DebugBundle of Symfony at its
    // first dump. So Nexus wraps again before each dump and keeps the handler that it replaces.
    // Without a handler of the site, the default handler of the site runs.
    public static function wrap(\Closure $handler): void
    {
        $varDumper = self::CLASS_NAME;
        $current = $varDumper::setHandler($handler);

        if ($current === $handler) {
            return;
        }

        self::$previous = $current === null ? null : \Closure::fromCallable($current);
    }

    public static function previous(): ?\Closure
    {
        return self::$previous;
    }

    public static function dump(mixed $value, ?string $label): void
    {
        $varDumper = self::CLASS_NAME;
        $varDumper::dump($value, $label);
    }

    // dump() without a value shows a bug. The site then gets the stub of its own VarDumper.
    public static function bugStub(): mixed
    {
        $scalarStub = self::SCALAR_STUB;

        return \class_exists($scalarStub) ? new $scalarStub('🐛') : '🐛';
    }

    // The handler that VarDumper of the site makes when nobody set one. Its register() method is
    // private, as Ignition also found.
    public static function defaultHandler(): ?\Closure
    {
        $varDumper = self::CLASS_NAME;

        if (!\class_exists($varDumper, false)) {
            return null;
        }

        if (!\method_exists($varDumper, 'register')) {
            return null;
        }

        try {
            $made = \Closure::bind(static function (): mixed {
                $current = self::$handler;
                self::register();
                $made = self::$handler;
                self::$handler = $current;

                return $made;
            }, null, $varDumper)();
        } catch (\Throwable) {
            return null;
        }

        return \is_callable($made) ? \Closure::fromCallable($made) : null;
    }
}
