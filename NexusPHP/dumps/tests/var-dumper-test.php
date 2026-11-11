<?php

declare(strict_types=1);

namespace Doctrine\Persistence {
    interface ObjectManager
    {
    }
}

namespace {
    use Doctrine\Persistence\ObjectManager;
    use Nexus\Dumps\VarDumper\Cloner\AbstractCloner;
    use Nexus\Dumps\VarDumper\Cloner\VarCloner;
    use Nexus\Dumps\VarDumper\Dumper\CliDumper;
    use Nexus\Dumps\VarDumper\Dumper\HtmlDumper;

    const PREFIX = 'Nexus\\Dumps\\VarDumper\\';

    final class TestUser
    {
        public string $name = 'Ada';
        protected int $age = 36;
        private array $roles = ['admin'];
    }

    final class TestManager implements ObjectManager
    {
        public array $cache = ['token' => 'internal-value'];
    }

    function render(mixed $value, int $maxString = -1): string
    {
        $cloner = new VarCloner();
        $cloner->setMaxString($maxString);

        $dumper = new CliDumper();
        $dumper->setColors(false);

        return $dumper->dump($cloner->cloneVar($value), true);
    }

    function renderHtml(mixed $value): string
    {
        return (new HtmlDumper())->dump((new VarCloner())->cloneVar($value), true);
    }

    function shorten(string $output): string
    {
        return strlen($output) > 2000
            ? substr($output, 0, 2000)."\n[...]"
            : $output;
    }

    function exists(string $name): bool
    {
        return class_exists($name) || interface_exists($name) || trait_exists($name);
    }

    $copy = realpath($argv[1] ?? __DIR__.'/../vendor/var-dumper');
    $failures = [];

    $expect = static function (string $check, string $output, array $fragments) use (&$failures): void {
        foreach ($fragments as $fragment) {
            if (!str_contains($output, $fragment)) {
                $failures[] = "{$check}: the output does not contain '{$fragment}'. The output:\n".shorten($output);
            }
        }
    };

    $reject = static function (string $check, string $output, string $fragment, string $problem) use (&$failures): void {
        if (str_contains($output, $fragment)) {
            $failures[] = "{$check}: {$problem} The output:\n".shorten($output);
        }
    };

    if ($copy === false) {
        fwrite(STDERR, "FAILED: the copy is not in NexusPHP/dumps/vendor/var-dumper. Run Config/var-dumper.sh first.\n");
        exit(1);
    }

    set_error_handler(static function (int $level, string $message, string $file, int $line) use (&$failures): bool {
        $failures[] = "PHP message: {$message} in {$file}:{$line}";

        return true;
    });

    spl_autoload_register(static function (string $class) use ($copy): void {
        if (!str_starts_with($class, PREFIX)) {
            return;
        }

        $file = $copy.'/'.str_replace('\\', '/', substr($class, strlen(PREFIX))).'.php';

        if (is_file($file)) {
            require $file;
        }
    });

    try {
        $files = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($copy, FilesystemIterator::SKIP_DOTS));

        foreach ($files as $file) {
            if ($file->getExtension() !== 'php') {
                continue;
            }

            $class = PREFIX.str_replace('/', '\\', substr($file->getPathname(), strlen($copy) + 1, -4));

            if (!exists($class)) {
                $failures[] = "Loading: {$file->getPathname()} does not declare {$class}.";
            }
        }

        $expect('Array', render(['name' => 'Nexus', 'ports' => [80, 443], 'on' => true, 'none' => null]), [
            'array:4 [',
            '"name" => "Nexus"',
            '"ports" => array:2 [',
            '1 => 443',
            '"on" => true',
            '"none" => null',
        ]);

        $expect('Object', render(new TestUser()), [
            'TestUser {#',
            '+name: "Ada"',
            '#age: 36',
            '-roles: array:1 [',
        ]);

        $expect('Closure', render(static fn (int $count): int => $count * 2), [
            'Closure(int $count): int {#',
            'var-dumper-test.php',
        ]);

        $longString = render(str_repeat('a', 12000), 10000);

        $expect('Long string', $longString, [str_repeat('a', 10000).'"…2000']);
        $reject('Long string', $longString, str_repeat('a', 10001), 'maxString 10000 did not cut the string.');

        $expect('Date', render(new DateTimeImmutable('2024-01-02 03:04:05', new DateTimeZone('UTC'))), [
            'DateTimeImmutable @1704164645 {#',
            'date: 2024-01-02 03:04:05.0 UTC (+00:00)',
        ]);

        $managerOutput = render(['manager' => new TestManager()]);

        $expect('Doctrine', $managerOutput, ['"manager" => TestManager {#']);
        $reject('Doctrine', $managerOutput, 'internal-value', 'the caster for Doctrine\\Persistence\\ObjectManager did not hide the properties.');

        $expect('HTML', renderHtml(['name' => 'Nexus', 'user' => new TestUser()]), [
            '<pre class=sf-dump',
            'Nexus',
            'TestUser',
        ]);

        $casters = defined(AbstractCloner::class.'::DEFAULT_CASTERS')
            ? constant(AbstractCloner::class.'::DEFAULT_CASTERS')
            : AbstractCloner::$defaultCasters;

        foreach ($casters as $type => [$casterClass, $method]) {
            if (str_contains($type, 'Symfony\\Component\\VarDumper')) {
                $failures[] = "Caster list: {$type} still names Symfony\\Component\\VarDumper.";
            }

            if (!str_starts_with($casterClass, PREFIX)) {
                $failures[] = "Caster list: the caster {$casterClass} of {$type} is not in the Nexus namespace.";
            }

            if (!method_exists($casterClass, $method)) {
                $failures[] = "Caster list: {$casterClass}::{$method}() of {$type} does not exist.";
            }

            if (str_starts_with($type, PREFIX) && !exists($type)) {
                $failures[] = "Caster list: the key {$type} names a class that is not in the copy.";
            }

            if (str_starts_with($type, 'Nexus\\') && !str_starts_with($type, PREFIX)) {
                $failures[] = "Caster list: the key {$type} got the Nexus prefix, but it is a class of another package.";
            }
        }

        $vendorKeys = array_filter(array_keys($casters), static fn (string $type): bool => !str_starts_with($type, 'Nexus\\'));

        if ($vendorKeys === []) {
            $failures[] = 'Caster list: no key of another package is left.';
        }
    } catch (Throwable $exception) {
        $failures[] = 'The test stopped: '.get_class($exception).": {$exception->getMessage()} in {$exception->getFile()}:{$exception->getLine()}";
    }

    if ($failures !== []) {
        fwrite(STDERR, "FAILED: the copy in {$copy}\n\n".implode("\n\n", $failures)."\n");
        exit(1);
    }

    echo "OK\n";
}
