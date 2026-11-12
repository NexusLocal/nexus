<?php

declare(strict_types=1);

namespace Nexus\Dumps\Tests;

use Nexus\Dumps\Catcher;
use Nexus\Dumps\PageMode;
use Nexus\Dumps\Renderer;
use Nexus\Dumps\Source;
use Nexus\Dumps\Transport;
use Nexus\Dumps\VarDumper\Caster\ScalarStub;
use Nexus\Dumps\VarDumper\Cloner\VarCloner;
use Nexus\Dumps\VarDumper\Dumper\CliDumper;

final class Failure extends \RuntimeException
{
}

final class Context
{
    public static string $library;
    public static string $copyLoader;
    public static string $fixtures;
    public static string $php;
    public static string $temp;
    public static int $cases = 0;

    public static function caseFolder(): string
    {
        $folder = self::$temp.'/c'.++self::$cases;
        mkdir($folder, 0700, true);

        return $folder;
    }
}

#[\AllowDynamicProperties]
final class TreeBag extends \ArrayObject
{
    public string $name = 'bag';
    protected int $size = 3;
    private string $secret = 'hidden';
}

final class TreeItems
{
    public array $lines = ['apple', 'pear'];
}

final class TreeCart
{
    public int $id = 42;
    public string $total = '129.95';
    public TreeItems $items;

    public function __construct()
    {
        $this->items = new TreeItems();
    }
}

final class FakeNexusd
{
    public array $lines = [];
    public int $connectionCount = 0;

    private $server;
    private array $connections = [];
    private array $buffers = [];
    private array $nextRead = [];

    public function __construct(
        public readonly string $path,
        private readonly bool $accepts = true,
        private readonly int $readBytes = 65536,
        private readonly float $readDelay = 0.0,
    ) {
        $server = @stream_socket_server("unix://{$path}", $errorCode, $errorText);

        if ($server === false) {
            throw new Failure("The fake nexusd cannot listen on {$path}: {$errorText}");
        }

        $this->server = $server;
    }

    public function streams(): array
    {
        if (!$this->accepts) {
            return [];
        }

        $now = microtime(true);
        $due = array_filter(
            $this->connections,
            fn ($connection): bool => $now >= ($this->nextRead[(int) $connection] ?? 0.0),
        );

        return [$this->server, ...array_values($due)];
    }

    public function handle($stream): void
    {
        if ($stream === $this->server) {
            $connection = @stream_socket_accept($this->server, 0);

            if ($connection === false) {
                return;
            }

            $this->connections[(int) $connection] = $connection;
            $this->buffers[(int) $connection] = '';
            ++$this->connectionCount;

            return;
        }

        $id = (int) $stream;
        $this->buffers[$id] .= (string) fread($stream, $this->readBytes);
        $this->nextRead[$id] = microtime(true) + $this->readDelay;

        while (($end = strpos($this->buffers[$id], "\n")) !== false) {
            $this->lines[] = substr($this->buffers[$id], 0, $end);
            $this->buffers[$id] = substr($this->buffers[$id], $end + 1);
        }

        if (feof($stream)) {
            fclose($stream);
            unset($this->connections[$id]);
        }
    }

    public function drain(float $seconds = 3.0): void
    {
        $deadline = microtime(true) + $seconds;

        while (microtime(true) < $deadline) {
            $read = $this->streams();

            if ($read === []) {
                return;
            }

            $write = null;
            $except = null;
            $ready = stream_select($read, $write, $except, 0, 50000);

            if ($ready + count($this->connections) === 0) {
                return;
            }

            foreach ($read as $stream) {
                $this->handle($stream);
            }
        }
    }

    public function events(): array
    {
        return array_map(
            static fn (string $line): array => json_decode($line, true, 512, JSON_THROW_ON_ERROR),
            $this->lines,
        );
    }

    public function ofType(string $type): array
    {
        return array_values(array_filter($this->events(), static fn (array $event): bool => $event['type'] === $type));
    }

    public function close(): void
    {
        foreach ($this->connections as $connection) {
            fclose($connection);
        }

        fclose($this->server);
        @unlink($this->path);
    }
}

final class WebServer
{
    public readonly int $port;

    private $process;

    public function __construct(string $documentRoot, public readonly string $stub)
    {
        $probe = stream_socket_server('tcp://127.0.0.1:0', $errorCode, $errorText);

        if ($probe === false) {
            throw new Failure("No free port: {$errorText}");
        }

        $this->port = (int) substr(strrchr(stream_socket_get_name($probe, false), ':'), 1);
        fclose($probe);

        $log = Context::$temp."/web-{$this->port}.log";
        $command = [Context::$php, '-n', '-d', "auto_prepend_file={$stub}", '-S', "127.0.0.1:{$this->port}", '-t', $documentRoot];
        $process = proc_open($command, [0 => ['file', '/dev/null', 'r'], 1 => ['file', $log, 'a'], 2 => ['file', $log, 'a']], $pipes, $documentRoot, baseEnvironment());

        if ($process === false) {
            throw new Failure('The PHP web server did not start.');
        }

        $this->process = $process;
        $deadline = microtime(true) + 10;

        while (microtime(true) < $deadline) {
            $client = @stream_socket_client("tcp://127.0.0.1:{$this->port}", $errorCode, $errorText, 0.2);

            if ($client !== false) {
                fclose($client);

                return;
            }

            usleep(50000);
        }

        throw new Failure("The PHP web server does not answer on port {$this->port}. Log: {$log}");
    }

    public function get(string $path, array $headers, ?FakeNexusd $daemon = null): array
    {
        $client = stream_socket_client("tcp://127.0.0.1:{$this->port}", $errorCode, $errorText, 5);

        if ($client === false) {
            throw new Failure("No connection to the web server: {$errorText}");
        }

        $lines = ["GET {$path} HTTP/1.0", "Host: 127.0.0.1:{$this->port}", 'Connection: close'];

        foreach ($headers as $name => $value) {
            $lines[] = "{$name}: {$value}";
        }

        fwrite($client, implode("\r\n", $lines)."\r\n\r\n");

        $response = '';
        $deadline = microtime(true) + 20;

        while (!feof($client)) {
            if (microtime(true) > $deadline) {
                throw new Failure("The request {$path} did not end in 20 s.");
            }

            $read = [$client, ...($daemon?->streams() ?? [])];
            $write = null;
            $except = null;
            stream_select($read, $write, $except, 0, 20000);

            foreach ($read as $stream) {
                if ($stream === $client) {
                    $response .= (string) fread($client, 65536);

                    continue;
                }

                $daemon?->handle($stream);
            }
        }

        fclose($client);
        $daemon?->drain();

        [$head, $body] = array_pad(explode("\r\n\r\n", $response, 2), 2, '');
        preg_match('#^HTTP/\S+ (\d+)#', $head, $match);
        withoutPhpMessages($body, $path);

        return ['status' => (int) ($match[1] ?? 0), 'body' => $body];
    }

    public function stop(): void
    {
        proc_terminate($this->process);
        proc_close($this->process);
    }
}

function check(bool $condition, string $message): void
{
    if (!$condition) {
        throw new Failure($message);
    }
}

function same(mixed $expected, mixed $actual, string $message): void
{
    if ($expected !== $actual) {
        throw new Failure("{$message}: expected ".export($expected).', got '.export($actual).'.');
    }
}

function contains(string $haystack, string $needle, string $message): void
{
    if (!str_contains($haystack, $needle)) {
        throw new Failure("{$message}: '{$needle}' is not in:\n".substr($haystack, 0, 3000));
    }
}

function lacks(string $haystack, string $needle, string $message): void
{
    if (str_contains($haystack, $needle)) {
        throw new Failure("{$message}: '{$needle}' is in:\n".substr($haystack, 0, 3000));
    }
}

function export(mixed $value): string
{
    return json_encode($value, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PARTIAL_OUTPUT_ON_ERROR) ?: var_export($value, true);
}

function withoutPhpMessages(string $output, string $what): void
{
    if (preg_match('/(Deprecated|Warning|Notice|Fatal error|Parse error):/', $output) === 1) {
        throw new Failure("PHP printed a message for {$what}:\n".substr($output, 0, 3000));
    }
}

function baseEnvironment(): array
{
    return ['PATH' => (string) getenv('PATH'), 'HOME' => (string) getenv('HOME')];
}

function lineOf(string $file, string $code): int
{
    foreach (file($file) as $index => $line) {
        if (str_contains($line, $code)) {
            return $index + 1;
        }
    }

    throw new Failure("'{$code}' is not in {$file}.");
}

function settings(string $folder, array $overrides = []): array
{
    return $overrides + [
        'version' => 1,
        'socket' => "{$folder}/s.sock",
        'folder' => "{$folder}/dumps",
        'page' => PageMode::AUTOMATIC,
        'userPrepend' => null,
    ];
}

function writeCopyLoader(string $file, string $copy): void
{
    $template = <<<'PHP'
        <?php

        \spl_autoload_register(static function (string $class): void {
            if (!\str_starts_with($class, 'Nexus\\Dumps\\VarDumper\\')) {
                return;
            }

            $file = %copy%.'/'.\str_replace('\\', '/', \substr($class, 22)).'.php';

            if (!\is_file($file)) {
                \trigger_error("The copy has no file for {$class}.", \E_USER_WARNING);

                return;
            }

            require $file;
        }, true, true);

        PHP;

    file_put_contents($file, strtr($template, ['%copy%' => var_export($copy, true)]));
}

function writeStub(string $file, array $settings): string
{
    $template = <<<'PHP'
        <?php

        namespace Nexus\Dumps;

        const SETTINGS = %settings%;

        require %copyLoader%;
        require %prepend%;

        PHP;

    file_put_contents($file, strtr($template, [
        '%settings%' => var_export($settings, true),
        '%copyLoader%' => var_export(Context::$copyLoader, true),
        '%prepend%' => var_export(Context::$library.'/prepend.php', true),
    ]));

    return $file;
}

function scenario(array $overrides = [], ?string $stub = null, bool $accepts = true, int $readBytes = 65536, float $readDelay = 0.0): array
{
    $folder = Context::caseFolder();
    $daemon = new FakeNexusd("{$folder}/s.sock", $accepts, $readBytes, $readDelay);

    return [$folder, $daemon, writeStub($stub ?? "{$folder}/stub.php", settings($folder, $overrides))];
}

function runCli(string $stub, array $arguments, ?FakeNexusd $daemon = null, array $environment = [], ?string $cwd = null): array
{
    $command = [Context::$php, '-n', '-d', "auto_prepend_file={$stub}", ...$arguments];
    $process = proc_open($command, [0 => ['file', '/dev/null', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, $cwd ?? Context::$fixtures.'/cli', $environment + baseEnvironment());

    if ($process === false) {
        throw new Failure('The child PHP did not start.');
    }

    $started = microtime(true);
    $output = [1 => '', 2 => ''];
    $open = [1 => $pipes[1], 2 => $pipes[2]];

    while ($open !== []) {
        if (microtime(true) - $started > 30) {
            proc_terminate($process);

            throw new Failure('The child PHP did not end in 30 s.');
        }

        $read = [...array_values($open), ...($daemon?->streams() ?? [])];
        $write = null;
        $except = null;
        stream_select($read, $write, $except, 0, 20000);

        foreach ($read as $stream) {
            $index = array_search($stream, $open, true);

            if ($index === false) {
                $daemon?->handle($stream);

                continue;
            }

            $output[$index] .= (string) fread($stream, 65536);

            if (feof($stream)) {
                fclose($stream);
                unset($open[$index]);
            }
        }
    }

    $exit = proc_close($process);
    $daemon?->drain();

    withoutPhpMessages($output[1].$output[2], implode(' ', $arguments));

    return ['stdout' => $output[1], 'exit' => $exit];
}

function treeOf(mixed $value): array
{
    $rendered = (new Renderer())->render($value);

    check(is_string($rendered['tree']), 'The renderer made no tree.');

    return json_decode($rendered['tree'], true, 512, JSON_THROW_ON_ERROR);
}

function child(array $node, string $key): array
{
    foreach ($node['children'] ?? [] as $item) {
        if (($item['key'] ?? null) === $key) {
            return $item;
        }
    }

    throw new Failure("The node has no child '{$key}': ".export($node));
}

function elapsed(string $stdout): float
{
    check(preg_match('/ELAPSED:([0-9.Ee-]+)/', $stdout, $match) === 1, 'The script printed no time.');

    return (float) $match[1];
}

function removeTree(string $folder): void
{
    if (is_link($folder)) {
        @unlink($folder);

        return;
    }

    if (!is_dir($folder)) {
        @unlink($folder);

        return;
    }

    foreach (array_diff(scandir($folder), ['.', '..']) as $name) {
        removeTree("{$folder}/{$name}");
    }

    @rmdir($folder);
}

function state(string $body): array
{
    check(preg_match('/^STATE:(.+)$/m', $body, $match) === 1, "The page printed no state:\n".substr($body, 0, 3000));

    return json_decode($match[1], true, 512, JSON_THROW_ON_ERROR);
}

function pageModeTable(): void
{
    $browser = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';
    $rows = [
        ['browser page', PageMode::AUTOMATIC, ['HTTP_ACCEPT' => $browser], false, false, true],
        ['no Accept header', PageMode::AUTOMATIC, [], false, false, false],
        ['curl', PageMode::AUTOMATIC, ['HTTP_ACCEPT' => '*/*'], false, false, false],
        ['JSON API', PageMode::AUTOMATIC, ['HTTP_ACCEPT' => 'application/json'], false, false, false],
        ['Accept with HTML and JSON', PageMode::AUTOMATIC, ['HTTP_ACCEPT' => 'text/html, application/json'], false, false, false],
        ['JSON body', PageMode::AUTOMATIC, ['HTTP_ACCEPT' => $browser, 'CONTENT_TYPE' => 'application/json'], false, false, false],
        ['JSON:API body header', PageMode::AUTOMATIC, ['HTTP_ACCEPT' => $browser, 'HTTP_CONTENT_TYPE' => 'application/vnd.api+json'], false, false, false],
        ['XHR', PageMode::AUTOMATIC, ['HTTP_ACCEPT' => $browser, 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest'], false, false, false],
        ['Livewire', PageMode::AUTOMATIC, ['HTTP_ACCEPT' => $browser, 'HTTP_X_LIVEWIRE' => ''], false, false, false],
        ['Inertia', PageMode::AUTOMATIC, ['HTTP_ACCEPT' => $browser, 'HTTP_X_INERTIA' => 'true'], false, false, false],
        ['htmx', PageMode::AUTOMATIC, ['HTTP_ACCEPT' => $browser, 'HTTP_HX_REQUEST' => 'true'], false, false, false],
        ['Turbo frame', PageMode::AUTOMATIC, ['HTTP_ACCEPT' => $browser, 'HTTP_TURBO_FRAME' => 'cart'], false, false, false],
        ['Turbo stream', PageMode::AUTOMATIC, ['HTTP_ACCEPT' => 'text/vnd.turbo-stream.html, text/html, application/xhtml+xml'], false, false, false],
        ['Turbo Drive without Sec-Fetch-Dest', PageMode::AUTOMATIC, ['HTTP_ACCEPT' => 'text/html, application/xhtml+xml'], false, false, true],
        ['Sec-Fetch-Dest document', PageMode::AUTOMATIC, ['HTTP_SEC_FETCH_DEST' => 'document', 'HTTP_ACCEPT' => $browser], false, false, true],
        ['Sec-Fetch-Dest document with a JSON Accept', PageMode::AUTOMATIC, ['HTTP_SEC_FETCH_DEST' => 'document', 'HTTP_ACCEPT' => 'application/json'], false, false, true],
        ['Sec-Fetch-Dest iframe', PageMode::AUTOMATIC, ['HTTP_SEC_FETCH_DEST' => 'iframe'], false, false, true],
        ['Sec-Fetch-Dest frame', PageMode::AUTOMATIC, ['HTTP_SEC_FETCH_DEST' => 'frame'], false, false, true],
        ['Sec-Fetch-Dest empty with an HTML Accept', PageMode::AUTOMATIC, ['HTTP_SEC_FETCH_DEST' => 'empty', 'HTTP_ACCEPT' => $browser], false, false, false],
        ['Sec-Fetch-Dest image', PageMode::AUTOMATIC, ['HTTP_SEC_FETCH_DEST' => 'image', 'HTTP_ACCEPT' => $browser], false, false, false],
        ['Turbo Drive visit', PageMode::AUTOMATIC, ['HTTP_SEC_FETCH_DEST' => 'empty', 'HTTP_ACCEPT' => 'text/html, application/xhtml+xml', 'HTTP_X_TURBO_REQUEST_ID' => 'a1'], false, false, true],
        ['Turbo Drive form with a stream answer', PageMode::AUTOMATIC, ['HTTP_SEC_FETCH_DEST' => 'empty', 'HTTP_ACCEPT' => 'text/vnd.turbo-stream.html, text/html, application/xhtml+xml', 'HTTP_X_TURBO_REQUEST_ID' => 'a2'], false, false, false],
        ['Turbo frame with a request id', PageMode::AUTOMATIC, ['HTTP_SEC_FETCH_DEST' => 'empty', 'HTTP_ACCEPT' => $browser, 'HTTP_X_TURBO_REQUEST_ID' => 'a3', 'HTTP_TURBO_FRAME' => 'cart'], false, false, false],
        ['htmx boosted link', PageMode::AUTOMATIC, ['HTTP_SEC_FETCH_DEST' => 'empty', 'HTTP_ACCEPT' => $browser, 'HTTP_HX_REQUEST' => 'true', 'HTTP_HX_BOOSTED' => 'true'], false, false, true],
        ['htmx boosted link without Sec-Fetch-Dest', PageMode::AUTOMATIC, ['HTTP_ACCEPT' => $browser, 'HTTP_HX_REQUEST' => 'true', 'HTTP_HX_BOOSTED' => 'true'], false, false, true],
        ['Livewire wire:navigate', PageMode::AUTOMATIC, ['HTTP_SEC_FETCH_DEST' => 'empty', 'HTTP_ACCEPT' => '*/*', 'HTTP_X_LIVEWIRE_NAVIGATE' => ''], false, false, true],
        ['Livewire wire:navigate without Sec-Fetch-Dest', PageMode::AUTOMATIC, ['HTTP_ACCEPT' => $browser, 'HTTP_X_LIVEWIRE_NAVIGATE' => '1'], false, false, true],
        ['Livewire update', PageMode::AUTOMATIC, ['HTTP_SEC_FETCH_DEST' => 'empty', 'HTTP_ACCEPT' => $browser, 'HTTP_X_LIVEWIRE' => ''], false, false, false],
        ['dd in a JSON API', PageMode::AUTOMATIC, ['HTTP_ACCEPT' => 'application/json'], true, false, true],
        ['Always with JSON', PageMode::ALWAYS, ['HTTP_ACCEPT' => 'application/json'], false, false, true],
        ['Never with a page', PageMode::NEVER, ['HTTP_ACCEPT' => $browser], false, false, false],
        ['Never with dd', PageMode::NEVER, ['HTTP_ACCEPT' => $browser], true, false, true],
        ['Never in a command', PageMode::NEVER, [], false, true, true],
        ['unknown mode with a page', 'sometimes', ['HTTP_ACCEPT' => $browser], false, false, true],
        ['unknown mode with JSON', 'sometimes', ['HTTP_ACCEPT' => 'application/json'], false, false, false],
    ];

    foreach ($rows as [$name, $mode, $server, $isDd, $cli, $expected]) {
        same($expected, PageMode::showsInPage($mode, $server, $isDd, $cli), "Page mode, {$name}");
    }
}

function ddDetection(): void
{
    same(true, Source::isDd([['function' => 'handle', 'class' => 'Nexus\Dumps\Catcher'], ['function' => 'dumpValues', 'class' => 'Nexus\Dumps\Catcher'], ['function' => 'dd', 'file' => '/app/a.php', 'line' => 3]]), 'dd()');
    same(true, Source::isDd([['function' => 'dd', 'file' => '/v/Dumpable.php', 'line' => 9], ['function' => 'dd', 'class' => 'Illuminate\Support\Collection', 'file' => '/app/a.php', 'line' => 3]]), 'dd() of a collection');
    same(false, Source::isDd([['function' => 'dump', 'file' => '/app/a.php', 'line' => 3]]), 'dump()');
    same(false, Source::isDd([['function' => 'dd', 'class' => 'App\Debugger', 'file' => '/app/a.php', 'line' => 3]]), 'A method dd() alone');
    same(false, Source::isDd([['function' => 'App\dd', 'file' => '/app/a.php', 'line' => 3]]), 'A function dd() in a namespace');
}

function sourceOfDump(): void
{
    $varDumper = 'Symfony\Component\VarDumper\VarDumper';

    same(['file' => '/app/Http/Controllers/CartController.php', 'line' => 42], Source::find([
        ['function' => 'callContext', 'class' => 'Nexus\Dumps\Catcher', 'file' => '/nexus/src/Catcher.php', 'line' => 10],
        ['function' => 'dumpValues', 'class' => 'Nexus\Dumps\Catcher', 'file' => '/nexus/prepend.php', 'line' => 60],
        ['function' => 'dump', 'file' => '/app/Http/Controllers/CartController.php', 'line' => 42],
        ['function' => 'show', 'class' => 'App\Http\Controllers\CartController', 'file' => '/app/vendor/laravel/framework/src/Illuminate/Routing/Controller.php', 'line' => 54],
    ]), 'The source of dump()');

    same(['file' => '/app/Jobs/Import.php', 'line' => 12], Source::find([
        ['function' => 'dump', 'file' => '/app/vendor/laravel/framework/src/Illuminate/Collections/Traits/EnumeratesValues.php', 'line' => 210],
        ['function' => 'dump', 'class' => 'Illuminate\Support\Collection', 'file' => '/app/Jobs/Import.php', 'line' => 12],
    ]), 'The source of $collection->dump()');

    same(['file' => '/app/Repositories/Orders.php', 'line' => 8], Source::find([
        ['function' => 'dump', 'file' => '/app/vendor/laravel/framework/src/Illuminate/Database/Query/Builder.php', 'line' => 4100],
        ['function' => 'dump', 'class' => 'Illuminate\Database\Query\Builder', 'file' => '/app/vendor/laravel/framework/src/Illuminate/Support/Traits/ForwardsCalls.php', 'line' => 23],
        ['function' => 'forwardCallTo', 'class' => 'Illuminate\Database\Eloquent\Builder', 'file' => '/app/vendor/laravel/framework/src/Illuminate/Database/Eloquent/Builder.php', 'line' => 2100],
        ['function' => '__call', 'class' => 'Illuminate\Database\Eloquent\Builder', 'file' => '/app/Repositories/Orders.php', 'line' => 8],
        ['function' => 'all', 'class' => 'App\Repositories\Orders', 'file' => '/app/routes/web.php', 'line' => 5],
    ]), 'The source of a dump through the query builder');

    same(['file' => '/app/scripts/check.php', 'line' => 3], Source::find([
        ['function' => 'dump', 'class' => $varDumper, 'file' => '/app/scripts/check.php', 'line' => 3],
    ]), 'The source of VarDumper::dump()');

    same(['file' => null, 'line' => null], Source::find([
        ['function' => 'handle', 'class' => 'App\Kernel', 'file' => '/app/index.php', 'line' => 3],
    ]), 'A trace without a dump');

    $folder = Context::caseFolder();
    $compiled = "{$folder}/0f1e2d.php";
    $script = "{$folder}/script.php";
    file_put_contents($compiled, "<?php echo 'cart'; ?>\n<?php dump(\$cart); ?>\n<?php /**PATH /app/resources/views/cart.blade.php ENDPATH**/ ?>\n");
    file_put_contents($script, "<?php\n\ndump(\$cart);\n");

    same(['file' => '/app/resources/views/cart.blade.php', 'line' => null], Source::find([
        ['function' => 'dump', 'file' => $compiled, 'line' => 2],
    ]), 'A compiled view in any folder');

    same(['file' => $script, 'line' => 3], Source::find([
        ['function' => 'dump', 'file' => $script, 'line' => 3],
    ]), 'A file without the marker of a view');

    file_put_contents($compiled, "<?php dump(\$cart); ?>\n");

    same(['file' => '/app/resources/views/cart.blade.php', 'line' => null], Source::find([
        ['function' => 'dump', 'file' => $compiled, 'line' => 1],
    ]), 'Nexus reads each compiled view once');
}

function treeOfAnArray(): void
{
    $value = ['name' => 'Nexus', 'ports' => [80, 443], 'on' => true, 'none' => null, 'pi' => 3.14, 'whole' => 2.0];
    $tree = treeOf($value);

    same(['kind' => 'array', 'count' => 6], ['kind' => $tree['kind'], 'count' => $tree['count']], 'The root of the array');
    check(!isset($tree['key']), 'The root has no key.');
    same(['key' => 'name', 'kind' => 'string', 'value' => 'Nexus'], child($tree, 'name'), 'A string');
    same(['key' => 'on', 'kind' => 'bool', 'value' => 'true'], child($tree, 'on'), 'A bool');
    same(['key' => 'none', 'kind' => 'null', 'value' => 'null'], child($tree, 'none'), 'A null');
    same(['key' => 'pi', 'kind' => 'float', 'value' => '3.14'], child($tree, 'pi'), 'A float');
    same(['key' => 'whole', 'kind' => 'float', 'value' => '2.0'], child($tree, 'whole'), 'A whole float');

    $ports = child($tree, 'ports');

    same('array', $ports['kind'], 'A nested array');
    same(2, $ports['count'], 'The count of the nested array');
    same(['key' => '1', 'index' => true, 'kind' => 'int', 'value' => '443'], $ports['children'][1], 'An integer key');

    $cloner = new VarCloner();
    $cloner->setMaxString(Renderer::MAX_STRING);
    $cliDumper = new CliDumper();
    $cliDumper->setColors(false);
    $expected = rtrim((string) $cliDumper->dump($cloner->cloneVar($value), true), "\n");

    same($expected, (new Renderer())->render($value)['text'], 'The text is the output of CliDumper');
}

function treeOfAnObjectWithAllAccessKinds(): void
{
    $bag = new TreeBag(['inside' => 1]);
    $bag->extra = 'added';
    $tree = treeOf($bag);

    same('object', $tree['kind'], 'The kind of an object');
    same(TreeBag::class, $tree['class'], 'The class of an object');
    check(is_int($tree['ref']) && $tree['ref'] > 0, 'An object has its handle as ref.');
    same(count($tree['children']), $tree['count'], 'The count of an object');

    $accesses = [];

    foreach ($tree['children'] as $item) {
        $accesses[$item['key']] ??= $item['access'];
    }

    same('public', $accesses['name'] ?? null, 'A public property');
    same('protected', $accesses['size'] ?? null, 'A protected property');
    same('private', $accesses['secret'] ?? null, 'A private property');
    same('dynamic', $accesses['extra'] ?? null, 'A dynamic property');
    same('virtual', $accesses['storage'] ?? null, 'A caster value');
}

function treeOfANestedObject(): void
{
    $tree = treeOf(new TreeCart());
    $items = child($tree, 'items');

    same(['key' => 'id', 'access' => 'public', 'kind' => 'int', 'value' => '42'], child($tree, 'id'), 'A property of the outer object');
    same('object', $items['kind'], 'The nested object');
    same(TreeItems::class, $items['class'], 'The class of the nested object');
    check($items['ref'] !== $tree['ref'], 'The nested object has its own handle.');
    same(['apple', 'pear'], array_column(child($items, 'lines')['children'], 'value'), 'The items of the nested object');
}

function treeOfAReferenceToAShownObject(): void
{
    $user = new TreeItems();
    $tree = treeOf(['first' => $user, 'second' => $user]);
    $first = child($tree, 'first');
    $second = child($tree, 'second');

    check(isset($first['children']), 'The first place shows the object.');
    check(!isset($first['refersTo']), 'The first place does not refer.');
    same($first['ref'], $second['refersTo'] ?? null, 'The second place refers to the first');
    check(!isset($second['children']), 'A node that refers has no children.');
}

function treeOfACutStringAndACutArray(): void
{
    $tree = treeOf(['long' => str_repeat('é', 12000), 'list' => range(1, 3000)]);
    $long = child($tree, 'long');
    $list = child($tree, 'list');

    same(2000, $long['cut'], 'The characters that the cloner left out');
    same(12000, $long['length'], 'The full length of the string');
    same(10000, mb_strlen($long['value']), 'The kept characters');
    same(3000, $list['count'], 'The count of the cut array');
    same(3000 - count($list['children']), $list['cut'], 'The items that the cloner left out');
    check($list['cut'] > 0, 'The cloner cut the array.');
}

function treeOfAResourceAndALabel(): void
{
    $stream = fopen('php://memory', 'r');
    $tree = treeOf(['stream' => $stream, 'binary' => "\xE9t\xE9"]);
    $resource = child($tree, 'stream');
    fclose($stream);

    same('resource', $resource['kind'], 'The kind of a resource');
    same('stream', $resource['class'], 'The type of a resource');
    same(['virtual'], array_values(array_unique(array_map(static fn (array $item): string => $item['access'], $resource['children']))), 'The keys of a resource');
    same('été', child($tree, 'binary')['value'], 'A string that is not UTF-8');
    same(['kind' => 'label', 'value' => '🐛'], treeOf(new ScalarStub('🐛')), 'A label');
}

function treeTooLarge(): void
{
    $rendered = (new Renderer())->render(array_fill(0, 2400, str_repeat('y', 300)));

    same(null, $rendered['tree'], 'A tree above 512 KB');
    same(true, $rendered['truncated'], 'A text above 64 KB');
    check(strlen($rendered['text']) <= Renderer::TEXT_BYTES, 'The text stays below 64 KB.');
    check(str_ends_with($rendered['text'], '"'), 'The text ends with a whole line.');
}

function linesThatAreTooLong(): void
{
    $fittedLine = new \ReflectionMethod(Catcher::class, 'fittedLine');
    $text = implode("\n", array_fill(0, 2000, str_repeat('t', 40)."\u{2028}"));
    $event = ['v' => 1, 'type' => 'dump', 'dump' => ['text' => $text, 'tree' => str_repeat('"\\', 300000), 'truncated' => false]];

    $withoutTree = $fittedLine->invoke(null, $event);

    check(is_string($withoutTree), 'A line without its tree fits.');
    check(strlen($withoutTree) <= Catcher::MAX_LINE_BYTES, 'The line fits in 1 MB.');
    contains($withoutTree, "\u{2028}", 'JSON keeps a line separator as one character');

    $decoded = json_decode($withoutTree, true, 512, JSON_THROW_ON_ERROR);

    same(null, $decoded['dump']['tree'], 'A line that is too long goes without its tree');
    same($text, $decoded['dump']['text'], 'The text stays when the line fits without the tree');

    $longText = implode("\n", array_fill(0, 30000, str_repeat('u', 39)));
    $event['dump'] = ['text' => $longText, 'tree' => null, 'truncated' => false];
    $shorter = $fittedLine->invoke(null, $event);

    check(is_string($shorter), 'A line with a shorter text fits.');
    check(strlen($shorter) <= Catcher::MAX_LINE_BYTES, 'The line with a shorter text fits in 1 MB.');

    $cut = json_decode($shorter, true, 512, JSON_THROW_ON_ERROR)['dump'];

    same(true, $cut['truncated'], 'A shorter text is truncated');
    check(str_starts_with($longText, $cut['text']), 'The shorter text is the start of the text.');
    same(0, (strlen($cut['text']) + 1) % 40, 'The shorter text ends with a whole line');
}

function noContainerWithoutLaravel(): void
{
    [, $daemon, $stub] = scenario();
    $result = runCli($stub, [Context::$fixtures.'/cli/container.php'], $daemon);
    $daemon->close();

    contains($result['stdout'], 'INSTANCE:none', 'Nexus makes no Laravel container');
    same(1, count($daemon->ofType('dump')), 'Nexus sends the dump');
}

function commandSendsAndPrints(): void
{
    [, $daemon, $stub] = scenario(['page' => PageMode::NEVER]);
    $script = Context::$fixtures.'/cli/plain.php';
    $result = runCli($stub, [$script], $daemon);
    $daemon->close();

    same(0, $result['exit'], 'The exit code');
    contains($result['stdout'], '"name" => "Nexus"', 'A command prints each dump');
    contains($result['stdout'], 'SCRIPT END', 'The script runs to its end');

    $dumps = $daemon->ofType('dump');
    $ends = $daemon->ofType('end');

    same(3, count($dumps), 'The dump events');
    same(1, count($ends), 'The end events');
    same(1, $daemon->connectionCount, 'The connections of one process');

    $request = $dumps[0]['request'];
    $cwd = realpath(Context::$fixtures.'/cli');

    same('command', $request['kind'], 'The kind of a command');
    check(!isset($request['method']), 'A command sends no method.');
    check(!isset($request['url']), 'A command sends no URL.');
    same("php {$script}", str_replace("'", '', $request['command']), 'The command line');
    same($cwd, $request['cwd'], 'The folder of the command');
    same($cwd, $request['root'], 'The root of a command');
    same(1, preg_match('/^[0-9a-f]{12}$/', $request['id']), 'The request id');
    check(is_int($request['pid']), 'The request has a pid.');
    check(is_float($request['started']) || is_int($request['started']), 'The request has a start time.');

    foreach ([...$dumps, ...$ends] as $event) {
        same(1, $event['v'], 'The wire version');
        same($request, $event['request'], 'Each event carries the same request');
    }

    $first = $dumps[0]['dump'];

    same(1, $first['seq'], 'The first seq');
    same('dump', $first['kind'], 'The kind of a dump');
    same(realpath($script), $first['file'], 'The file of the dump');
    same(lineOf($script, "dump(['name' => 'Nexus']);"), $first['line'], 'The line of the dump');
    same(null, $first['label'], 'A dump without a label');
    same(false, $first['truncated'], 'A small dump is not cut');
    contains($first['text'], '"name" => "Nexus"', 'The text of the dump');
    check(is_string($first['tree']), 'The tree is one JSON string.');
    same('Nexus', child(json_decode($first['tree'], true), 'name')['value'], 'The tree of the dump');
    same(['1', '2'], [$dumps[1]['dump']['label'], $dumps[2]['dump']['label']], 'The labels of dump() with two values');
    same([2, 3], [$dumps[1]['dump']['seq'], $dumps[2]['dump']['seq']], 'The seq of the next dumps');
    same($dumps[1]['dump']['line'], $dumps[2]['dump']['line'], 'Two values of one call have one source');

    same(null, $ends[0]['status'], 'A command has no status');
    same(null, $ends[0]['exit'], 'A plain script has no known exit code');
    check($ends[0]['duration'] >= 0, 'The duration is a number.');
}

function commandDd(): void
{
    [, $daemon, $stub] = scenario();
    $result = runCli($stub, [Context::$fixtures.'/cli/stop.php'], $daemon);
    $daemon->close();

    same(1, $result['exit'], 'dd() ends the command with 1');
    contains($result['stdout'], 'stop here', 'dd() prints');
    same('dd', $daemon->ofType('dump')[0]['dump']['kind'] ?? null, 'The kind of a dd()');
    same(1, $daemon->ofType('end')[0]['exit'] ?? null, 'The exit code in the end event');
}

function artisanThroughTheSite(): void
{
    [, $daemon, $stub] = scenario();
    $site = realpath(Context::$fixtures.'/site');
    $artisan = "{$site}/artisan";
    $line = lineOf($artisan, "dump(['command'");
    $result = runCli($stub, [$artisan, 'migrate'], $daemon, [], $site);
    $daemon->close();

    same(3, $result['exit'], 'The exit code of artisan');
    contains($result['stdout'], "LARAVEL:{\"command\":\"migrate\"} SOURCE:[\"{$artisan}\",\"artisan\",{$line}]", 'The handler of Laravel prints the dump with its source');

    $dumps = $daemon->ofType('dump');

    same(1, count($dumps), 'The dump events of artisan');
    same($artisan, $dumps[0]['dump']['file'], 'The file of the dump in artisan');
    same($line, $dumps[0]['dump']['line'], 'The line of the dump in artisan');
    same($site, $dumps[0]['request']['root'], 'The root of artisan is its working folder');
    same(3, $daemon->ofType('end')[0]['exit'] ?? null, 'The exit code from CommandFinished');
}

function testRunsSendNothing(): void
{
    [, $daemon, $stub] = scenario(['userPrepend' => Context::$fixtures.'/cli/user-prepend.php']);

    $phpunit = runCli($stub, [Context::$fixtures.'/cli/phpunit'], $daemon);
    contains($phpunit['stdout'], 'CHECK:{"dump":true,"userPrepend":"global"}', 'A test run gets the prepend file of the user');
    contains($phpunit['stdout'], '"name" => "Nexus"', 'A test run prints its dumps');

    $testing = runCli($stub, [Context::$fixtures.'/cli/plain.php'], $daemon, ['APP_ENV' => 'testing']);
    contains($testing['stdout'], '"name" => "Nexus"', 'APP_ENV=testing prints its dumps');

    $site = Context::$fixtures.'/site';
    $artisan = runCli($stub, ["{$site}/artisan", 'migrate'], $daemon, ['APP_ENV' => 'testing'], $site);
    contains($artisan['stdout'], 'LARAVEL:{"command":"migrate"}', 'A test run keeps the handler of the site');

    $daemon->close();

    same(0, $daemon->connectionCount, 'Test runs connect to nexusd');
}

function otherStubVersion(): void
{
    $folder = Context::caseFolder();
    $stub = writeStub("{$folder}/stub.php", settings($folder, ['version' => 2, 'userPrepend' => Context::$fixtures.'/cli/user-prepend.php']));
    $result = runCli($stub, [Context::$fixtures.'/cli/check.php']);

    contains($result['stdout'], 'CHECK:{"dump":false,"userPrepend":"global"}', 'Another stub version only includes the prepend file of the user');
}

function relativeUserPrepend(): void
{
    $folder = Context::caseFolder();
    $stub = writeStub("{$folder}/stub.php", settings($folder, ['userPrepend' => 'user-prepend.php']));
    $check = Context::$fixtures.'/cli/check.php';

    $found = runCli($stub, ['-d', 'include_path='.Context::$fixtures.'/cli', $check], cwd: $folder);
    $missing = runCli($stub, ['-d', "include_path={$folder}", $check], cwd: $folder);

    contains($found['stdout'], 'CHECK:{"dump":true,"userPrepend":"global"}', 'A relative prepend file of the user is found through include_path');
    contains($missing['stdout'], 'CHECK:{"dump":true,"userPrepend":"missing"}', 'A relative prepend file that include_path does not find is skipped');
}

function pauseAfterAFailedConnect(): void
{
    $folder = Context::caseFolder();
    $stub = writeStub("{$folder}/stub.php", settings($folder));
    $result = runCli($stub, [Context::$fixtures.'/cli/plain.php']);

    same(0, $result['exit'], 'A missing nexusd does not stop the command');
    contains($result['stdout'], 'SCRIPT END', 'The script runs to its end without nexusd');
    check(is_file("{$folder}/dumps/".Transport::PAUSE_FILE), 'PHP touches the pause file.');
    same('0700', substr(sprintf('%o', fileperms("{$folder}/dumps")), -4), 'PHP makes the folder of the stub');

    $daemon = new FakeNexusd("{$folder}/s.sock");
    runCli($stub, [Context::$fixtures.'/cli/plain.php'], $daemon);

    same(0, $daemon->connectionCount, 'A process sends nothing during the pause');

    touch("{$folder}/dumps/".Transport::PAUSE_FILE, time() - Transport::PAUSE_SECONDS - 1);
    runCli($stub, [Context::$fixtures.'/cli/plain.php'], $daemon);
    $daemon->close();

    same(1, $daemon->connectionCount, 'A process sends again after the pause');
    same(4, count($daemon->events()), 'The events after the pause');
}

function writeDeadline(): void
{
    [$blockedFolder, $notReading, $blockedStub] = scenario(accepts: false);
    $blocked = runCli($blockedStub, [Context::$fixtures.'/cli/big.php'], $notReading);
    $notReading->close();

    contains($blocked['stdout'], 'SCRIPT END', 'The script runs to its end when nexusd does not read');
    check(is_file("{$blockedFolder}/dumps/".Transport::PAUSE_FILE), 'PHP touches the pause file after a write that did not end.');
    check(elapsed($blocked['stdout']) < 0.5, 'The dump waited '.elapsed($blocked['stdout']).' s for a nexusd that does not read.');

    [$slowFolder, $slow, $slowStub] = scenario(readBytes: 8192, readDelay: 0.03);
    $slowResult = runCli($slowStub, [Context::$fixtures.'/cli/big.php'], $slow);
    $slow->close();

    check(is_file("{$slowFolder}/dumps/".Transport::PAUSE_FILE), 'A line that needs more than 50 ms pauses the sending.');
    check(elapsed($slowResult['stdout']) < 0.5, 'The dump waited '.elapsed($slowResult['stdout']).' s for a slow nexusd.');
    same([], $slow->lines, 'nexusd gets no part of a line');
}

function plainSiteWithoutADump(WebServer $server): void
{
    [, $daemon] = scenario(stub: $server->stub);
    $response = $server->get('/index.php', ['Accept' => 'text/html'], $daemon);
    $daemon->close();

    same(200, $response['status'], 'The status of a page');
    same(['nexusClasses' => [], 'dump' => true, 'askedClasses' => []], state($response['body']), 'A page without a dump loads no class of Nexus');
    same(0, $daemon->connectionCount, 'A page without a dump does not connect');
}

function missingNexusdCostsNothing(WebServer $server): void
{
    $folder = Context::caseFolder();
    writeStub($server->stub, settings($folder));

    $first = state($server->get('/index.php?action=dump', ['Accept' => 'application/json'])['body']);
    $paused = state($server->get('/index.php?action=dump', ['Accept' => 'application/json'])['body']);

    check(is_file("{$folder}/dumps/".Transport::PAUSE_FILE), 'A missing nexusd starts the pause.');

    foreach ([$first, $paused] as $state) {
        lacks(implode(' ', $state['nexusClasses']), 'Renderer', 'A missing or paused nexusd costs no render');
        lacks(implode(' ', $state['nexusClasses']), 'VarCloner', 'A missing or paused nexusd costs no clone');
    }
}

function plainSiteDumps(WebServer $server): void
{
    [, $daemon] = scenario(stub: $server->stub);
    $index = Context::$fixtures.'/plain/index.php';

    $page = $server->get('/index.php?action=dump', ['Accept' => 'text/html'], $daemon);
    $api = $server->get('/index.php?action=dump', ['Accept' => 'application/json'], $daemon);
    $fetch = $server->get('/index.php?action=dump', ['Accept' => 'text/html', 'Sec-Fetch-Dest' => 'empty'], $daemon);
    $stop = $server->get('/index.php?action=dd', ['Accept' => 'application/json'], $daemon);
    $daemon->close();

    contains($page['body'], 'sf-dump', 'Nexus prints the dump in a page');
    lacks(implode(' ', state($page['body'])['askedClasses']), 'Symfony', 'Without Composer no autoloader of the site sees a Symfony name');
    lacks($api['body'], '"plain"', 'Nexus keeps the dump out of a JSON response');
    lacks($fetch['body'], 'sf-dump', 'Nexus keeps the dump out of a fetch() response');
    same(500, $stop['status'], 'The status after dd()');
    contains($stop['body'], 'stop here', 'dd() always prints');

    $dumps = $daemon->ofType('dump');
    $ends = $daemon->ofType('end');

    same(4, count($dumps), 'The dump events of four requests');
    same(4, count($ends), 'The end events of four requests');

    $request = $dumps[0]['request'];

    same('http', $request['kind'], 'The kind of a web request');
    same('GET', $request['method'], 'The method');
    same("http://127.0.0.1:{$server->port}/index.php?action=dump", $request['url'], 'The URL');
    same('127.0.0.1', $request['host'], 'The host without the port');
    same(realpath(Context::$fixtures.'/plain'), $request['root'], 'The root is the document root');
    same(realpath($index), $dumps[0]['dump']['file'], 'The file of the dump');
    same(lineOf($index, "dump(['plain' => true]);"), $dumps[0]['dump']['line'], 'The line of the dump');
    check($dumps[0]['request']['id'] !== $dumps[1]['request']['id'], 'Each request has its own id.');
    same('dd', $dumps[3]['dump']['kind'], 'The kind of dd()');
    same([200, 200, 200, 500], array_map(static fn (array $event): mixed => $event['status'], $ends), 'The status in the end events');
    same([null, null, null, null], array_map(static fn (array $event): mixed => $event['exit'], $ends), 'A web request has no exit code');
}

function laravelSiteKeepsItsHandler(WebServer $server): void
{
    [$folder, $daemon] = scenario(stub: $server->stub);
    $index = Context::$fixtures.'/site/public/index.php';
    $source = '["'.realpath($index).'","public/index.php",'.lineOf($index, "dump(['order' => 7]);").']';

    $page = $server->get('/index.php', ['Accept' => 'text/html'], $daemon);
    $api = $server->get('/index.php', ['Accept' => 'application/json'], $daemon);
    $stop = $server->get('/index.php?action=dd', ['Accept' => 'application/json'], $daemon);

    writeStub($server->stub, settings($folder, ['page' => PageMode::NEVER]));
    $never = $server->get('/index.php', ['Accept' => 'text/html'], $daemon);

    writeStub($server->stub, settings($folder, ['page' => PageMode::ALWAYS]));
    $always = $server->get('/index.php', ['Accept' => 'application/json'], $daemon);

    writeStub($server->stub, settings($folder));
    $quiet = $server->get('/index.php?action=none', ['Accept' => 'text/html'], $daemon);
    $daemon->close();

    contains($page['body'], "LARAVEL:{\"order\":7} SOURCE:{$source}", 'The handler of the site prints in a page with its source');
    contains($page['body'], '"resolver":false', 'Nexus removes its source resolver after the dump');
    lacks($page['body'], 'SYMFONY-DEFAULT', 'Only the handler of the site prints');
    lacks($api['body'], 'LARAVEL:', 'The handler of the site does not run for JSON');
    contains($api['body'], 'PAGE END', 'The JSON response goes on');
    same(500, $stop['status'], 'The status after dd()');
    contains($stop['body'], 'LARAVEL:{"order":7}', 'dd() always prints');
    lacks($never['body'], 'LARAVEL:', 'Never keeps the dump out of a page');
    contains($always['body'], 'LARAVEL:{"order":7}', 'Always prints in a JSON response');
    same([], state($quiet['body'])['nexusClasses'], 'A Laravel request without a dump loads no class of Nexus');

    $dumps = $daemon->ofType('dump');

    same(5, count($dumps), 'Each dump reaches nexusd');
    same(['dump', 'dump', 'dd', 'dump', 'dump'], array_map(static fn (array $event): string => $event['dump']['kind'], $dumps), 'The kinds');
    same(realpath($index), $dumps[0]['dump']['file'], 'The file of the dump in the site');
    same(realpath(Context::$fixtures.'/site/public'), $dumps[0]['request']['root'], 'The root is the document root');
    same([200, 200, 500, 200, 200], array_map(static fn (array $event): mixed => $event['status'], $daemon->ofType('end')), 'The status in the end events');
}

function collectorGetsEachDump(WebServer $server): void
{
    [, $daemon] = scenario(stub: $server->stub);
    $api = $server->get('/index.php?mode=collector', ['Accept' => 'application/json'], $daemon);
    $page = $server->get('/index.php?mode=collector', ['Accept' => 'text/html'], $daemon);
    $daemon->close();

    lacks($api['body'], 'COLLECTOR:', 'The output of the handler stays out of a JSON response');
    same([['order' => 7]], state($api['body'])['collected'], 'The handler of the site gets a dump that does not show');
    contains($page['body'], 'COLLECTOR:{"order":7}', 'The handler of the site prints in a page');
    same([['order' => 7]], state($page['body'])['collected'], 'The handler of the site gets a dump that shows');
    same(2, count($daemon->ofType('dump')), 'Nexus sends both dumps');
}

function siteDefaultAfterAReset(WebServer $server): void
{
    [, $daemon] = scenario(stub: $server->stub);
    $response = $server->get('/index.php?action=reset', ['Accept' => 'text/html'], $daemon);
    $daemon->close();

    contains($response['body'], 'LARAVEL:{"order":7}', 'The first dump reaches the handler of the site');
    contains($response['body'], 'SYMFONY-DEFAULT:{"order":8}', 'After setHandler(null) the default handler of the site prints');
    lacks($response['body'], 'LARAVEL:{"order":8}', 'Nexus forgets the handler that the site removed');
}

function composerLoadsTheVarDumperOfTheSite(WebServer $server): void
{
    [, $daemon] = scenario(stub: $server->stub);
    $response = $server->get('/index.php?mode=none', ['Accept' => 'text/html'], $daemon);
    $daemon->close();

    contains($response['body'], 'SYMFONY-DEFAULT:{"order":7}', 'Nexus loads VarDumper of the site through Composer');
    same(1, count($daemon->ofType('dump')), 'Nexus sends the dump');
}

function handlerThatReplacesItself(WebServer $server): void
{
    [, $daemon] = scenario(stub: $server->stub);
    $response = $server->get('/index.php?mode=selfreplace&action=twice', ['Accept' => 'text/html'], $daemon);
    $daemon->close();

    contains($response['body'], "FIRST:{\"order\":7}\nSECOND:{\"order\":8}\nSECOND:{\"order\":9}", 'Each value reaches the current handler of the site');
    same(['1', '2', null], array_map(static fn (array $event): ?string => $event['dump']['label'], $daemon->ofType('dump')), 'Nexus sends each value');
}

function directVarDumperCall(WebServer $server): void
{
    [, $daemon] = scenario(stub: $server->stub);
    $index = Context::$fixtures.'/site/public/index.php';
    $response = $server->get('/index.php?action=direct', ['Accept' => 'text/html'], $daemon);
    $daemon->close();

    contains($response['body'], 'LARAVEL:{"direct":true}', 'The handler of the site prints a direct VarDumper::dump()');

    $dumps = $daemon->ofType('dump');

    same(2, count($dumps), 'Nexus sends a direct VarDumper::dump() after the first dump');
    same(lineOf($index, "VarDumper::dump(['direct' => true]);"), $dumps[1]['dump']['line'], 'The line of a direct VarDumper::dump()');
}

function varDumperFormatBlocks(WebServer $server): void
{
    [$folder, $daemon] = scenario(stub: $server->stub);

    $first = $server->get('/index.php?format=server', ['Accept' => 'text/html'], $daemon);
    $second = $server->get('/index.php?format=server', ['Accept' => 'text/html'], $daemon);
    $daemon->close();

    contains($first['body'], 'SYMFONY-DEFAULT:{"order":7}', 'The site keeps its own handler');
    contains($second['body'], 'PAGE END', 'The second page works');

    $blocked = $daemon->ofType('blocked');

    same(1, count($daemon->events()), 'One event for two requests');
    same('var_dumper_format', $blocked[0]['reason'] ?? null, 'The reason of the block');
    same('server', $blocked[0]['detail'] ?? null, 'The value of VAR_DUMPER_FORMAT');
    same('127.0.0.1', $blocked[0]['request']['host'] ?? null, 'The host of the block');
    check(is_file("{$folder}/dumps/blocked-127.0.0.1"), 'PHP keeps a stamp for the host.');
}

function emptyVarDumperFormatBlocks(WebServer $server): void
{
    [, $daemon] = scenario(stub: $server->stub);

    $response = $server->get('/index.php?format=', ['Accept' => 'text/html'], $daemon);
    $daemon->close();

    contains($response['body'], 'SYMFONY-DEFAULT:{"order":7}', 'setHandler() of VarDumper ignores Nexus also for an empty value');

    $blocked = $daemon->ofType('blocked');

    same(1, count($daemon->events()), 'Only the block event');
    same('var_dumper_format', $blocked[0]['reason'] ?? null, 'The reason of the block');
    same('', $blocked[0]['detail'] ?? null, 'The empty value of VAR_DUMPER_FORMAT');
}

function handlerThatCallsNexusAgain(WebServer $server): void
{
    [, $daemon] = scenario(stub: $server->stub);
    $response = $server->get('/index.php?action=wrapper', ['Accept' => 'text/html'], $daemon);
    $daemon->close();

    same(200, $response['status'], 'The status of the page');
    contains($response['body'], 'LARAVEL:{"order":7}', 'The first dump reaches the handler of Laravel');
    same(1, substr_count($response['body'], 'WRAPPER:'), 'The wrapper of the site runs once');
    same(1, substr_count($response['body'], 'SYMFONY-DEFAULT:{"order":8}'), 'The default handler prints the second dump once');
    same(2, count($daemon->ofType('dump')), 'Nexus sends each dump once');
}

$copy = realpath($argv[1] ?? __DIR__.'/../vendor/var-dumper');

if ($copy === false) {
    fwrite(STDERR, "FAILED: the copy of VarDumper is not there. Give its folder as the first argument.\n");
    exit(1);
}

$temp = rtrim(sys_get_temp_dir(), '/').'/nexus-dumps-'.bin2hex(random_bytes(4));

if (strlen("{$temp}/c99/s.sock") > 100) {
    $temp = '/tmp/nexus-dumps-'.bin2hex(random_bytes(4));
}

mkdir($temp, 0700, true);

Context::$temp = (string) realpath($temp);
Context::$library = (string) realpath(__DIR__.'/..');
Context::$fixtures = (string) realpath(__DIR__.'/fixtures');
Context::$php = PHP_BINARY;
Context::$copyLoader = Context::$temp.'/copy-loader.php';

register_shutdown_function(static fn () => removeTree(Context::$temp));

set_error_handler(static function (int $level, string $message, string $file, int $line): bool {
    if ((error_reporting() & $level) === 0) {
        return false;
    }

    throw new Failure("PHP message: {$message} in {$file}:{$line}");
});

writeCopyLoader(Context::$copyLoader, $copy);
require Context::$copyLoader;
require Context::$library.'/prepend.php';
\Nexus\Dumps\library();

$tests = [
    'the page-mode table' => pageModeTable(...),
    'dd detection' => ddDetection(...),
    'the source of a dump' => sourceOfDump(...),
    'the tree of an array and its text' => treeOfAnArray(...),
    'the tree of an object with all access kinds' => treeOfAnObjectWithAllAccessKinds(...),
    'the tree of a nested object' => treeOfANestedObject(...),
    'the tree of a reference to a shown object' => treeOfAReferenceToAShownObject(...),
    'the tree of a cut string and a cut array' => treeOfACutStringAndACutArray(...),
    'the tree of a resource, a binary string and a label' => treeOfAResourceAndALabel(...),
    'a tree above 512 KB' => treeTooLarge(...),
    'lines that are too long' => linesThatAreTooLong(...),
    'no Laravel container without Laravel' => noContainerWithoutLaravel(...),
    'a command sends to the socket and prints' => commandSendsAndPrints(...),
    'dd() in a command' => commandDd(...),
    'artisan through the VarDumper of the site' => artisanThroughTheSite(...),
    'test runs send nothing' => testRunsSendNothing(...),
    'another stub version' => otherStubVersion(...),
    'a relative prepend file of the user' => relativeUserPrepend(...),
    'the pause after a failed connect' => pauseAfterAFailedConnect(...),
    'the deadline of a line' => writeDeadline(...),
];

$webTests = [
    'plain' => [
        'a page without a dump' => plainSiteWithoutADump(...),
        'dump() and dd() of Nexus in web requests' => plainSiteDumps(...),
        'a missing or paused nexusd costs no render' => missingNexusdCostsNothing(...),
    ],
    'site/public' => [
        'a Laravel site keeps its handler and its source link' => laravelSiteKeepsItsHandler(...),
        'a collector of the site gets each dump' => collectorGetsEachDump(...),
        'the default handler after setHandler(null)' => siteDefaultAfterAReset(...),
        'Composer loads the VarDumper of the site' => composerLoadsTheVarDumperOfTheSite(...),
        'a handler of the site that replaces itself' => handlerThatReplacesItself(...),
        'a direct VarDumper::dump() after the first dump' => directVarDumperCall(...),
        'the VAR_DUMPER_FORMAT block event' => varDumperFormatBlocks(...),
        'an empty VAR_DUMPER_FORMAT blocks too' => emptyVarDumperFormatBlocks(...),
        'a handler of the site that calls Nexus again' => handlerThatCallsNexusAgain(...),
    ],
];

$failures = [];

$run = static function (string $name, \Closure $test, array $arguments = []) use (&$failures): void {
    try {
        $test(...$arguments);
        echo "ok   {$name}\n";
    } catch (\Throwable $exception) {
        $failures[] = $name;
        $where = $exception instanceof Failure ? '' : ' ('.$exception::class." in {$exception->getFile()}:{$exception->getLine()})";
        echo "FAIL {$name}: {$exception->getMessage()}{$where}\n";
    }
};

echo 'PHP '.PHP_VERSION.", VarDumper copy {$copy}\n";

foreach ($tests as $name => $test) {
    $run($name, $test);
}

foreach ($webTests as $documentRoot => $group) {
    try {
        $server = new WebServer(Context::$fixtures."/{$documentRoot}", Context::$temp.'/web-stub-'.str_replace('/', '-', $documentRoot).'.php');
    } catch (\Throwable $exception) {
        $failures[] = "the web server for {$documentRoot}";
        echo "FAIL the web server for {$documentRoot}: {$exception->getMessage()}\n";

        continue;
    }

    foreach ($group as $name => $test) {
        $run($name, $test, [$server]);
    }

    $server->stop();
}

if ($failures !== []) {
    echo "\nFAILED: ".count($failures)." of the tests.\n";
    exit(1);
}

echo "\nOK\n";
