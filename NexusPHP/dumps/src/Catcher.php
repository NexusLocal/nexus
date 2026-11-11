<?php

declare(strict_types=1);

namespace Nexus\Dumps;

use Nexus\Dumps\VarDumper\Caster\ScalarStub;
use Nexus\Dumps\VarDumper\Cloner\Data;
use Nexus\Dumps\VarDumper\Dumper\HtmlDumper;

/*
 * Sends each dump of this request or command to nexusd and decides if the dump also shows in the
 * page. One instance lives for the whole process.
 */
final class Catcher
{
    public const WIRE_VERSION = 1;

    public const JSON_FLAGS = \JSON_UNESCAPED_SLASHES | \JSON_UNESCAPED_UNICODE | \JSON_UNESCAPED_LINE_TERMINATORS | \JSON_INVALID_UTF8_SUBSTITUTE | \JSON_PRESERVE_ZERO_FRACTION;

    // nexusd refuses a line above 1 MB. A line that is too large goes without its tree. When it is
    // still too large, it goes with a shorter text.
    public const MAX_LINE_BYTES = 1_000_000;

    // The JSON of a dump event without its text and its tree, with room to spare.
    private const EVENT_BYTES = 8192;

    private const BLOCKED_SECONDS = 60;

    private const FATAL_ERRORS = [\E_ERROR, \E_PARSE, \E_CORE_ERROR, \E_COMPILE_ERROR, \E_USER_ERROR, \E_RECOVERABLE_ERROR];

    private const TEST_CASE = 'PHPUnit\Framework\TestCase';

    private static ?self $instance = null;

    private int $seq = 0;

    private ?array $request = null;

    private ?Transport $transport = null;

    private ?Renderer $renderer = null;

    private bool $sending = false;

    private bool $ddCalled = false;

    private bool $blockedChecked = false;

    /** @var array{send: bool, isDd: bool, source: array{file: ?string, line: ?int}, shows: bool}|null */
    private ?array $call = null;

    private int $depth = 0;

    private ?\Closure $handler = null;

    private ?\Closure $siteDefault = null;

    private ?\Closure $ownPrinter = null;

    private function __construct(private readonly array $settings)
    {
    }

    public static function instance(): self
    {
        return self::$instance ??= new self(\defined('Nexus\Dumps\SETTINGS') ? \Nexus\Dumps\SETTINGS : []);
    }

    // dump() of Nexus. It returns what dump() of Symfony returns.
    public function dumpValues(array $vars): mixed
    {
        $siteVarDumper = SiteVarDumper::exists();
        $outerCall = $this->call;
        $this->call = $this->callContext();

        try {
            foreach (self::labelled($vars, $siteVarDumper) as [$value, $label]) {
                $siteVarDumper
                    ? $this->dumpThroughSite($value, $label)
                    : $this->dumpWithOwnPrinter($value, $label);
            }
        } finally {
            $this->call = $outerCall;
        }

        if ($vars === []) {
            return null;
        }

        return \count($vars) > 1 ? $vars : $vars[\array_key_last($vars)];
    }

    public function dumpAndExit(array $vars): never
    {
        self::sendErrorStatus();
        $this->dumpValues($vars);

        exit(1);
    }

    public function finish(): void
    {
        $fatal = self::isFatal(\error_get_last());

        try {
            $this->send('end', [
                'status' => self::status($fatal),
                'exit' => isCli() ? $this->exitCode($fatal) : null,
                'duration' => \round(\max(0.0, \microtime(true) - $this->request()['started']), 6),
            ]);
        } catch (\Throwable) {
            // PHP prints an error of a shutdown function at the end of the page. A lost end event
            // is the smaller problem.
        }
    }

    // dd() of Symfony sets this status.
    private static function sendErrorStatus(): void
    {
        if (isCli()) {
            return;
        }

        if (\headers_sent()) {
            return;
        }

        \header('HTTP/1.1 500 Internal Server Error');
    }

    private static function isFatal(?array $error): bool
    {
        if ($error === null) {
            return false;
        }

        return \in_array($error['type'], self::FATAL_ERRORS, true);
    }

    /** @return list<array{0: mixed, 1: ?string}> */
    private static function labelled(array $vars, bool $siteVarDumper): array
    {
        if ($vars === []) {
            return [[$siteVarDumper ? SiteVarDumper::bugStub() : new ScalarStub('🐛'), null]];
        }

        if (\array_keys($vars) === [0]) {
            return [[$vars[0], null]];
        }

        $labelled = [];

        foreach ($vars as $key => $value) {
            $labelled[] = [$value, \is_int($key) ? (string) (1 + $key) : $key];
        }

        return $labelled;
    }

    // One trace and one decision for each call of dump(), also with more than one value.
    /** @return array{send: bool, isDd: bool, source: array{file: ?string, line: ?int}, shows: bool} */
    private function callContext(): array
    {
        $trace = \debug_backtrace(\DEBUG_BACKTRACE_IGNORE_ARGS, 20);
        $isDd = Source::isDd($trace);

        return [
            'send' => !self::isTestRun(),
            'isDd' => $isDd,
            'source' => Source::find($trace),
            'shows' => PageMode::showsInPage((string) ($this->settings['page'] ?? PageMode::AUTOMATIC), $_SERVER, $isDd, isCli()),
        ];
    }

    // A test run prints its dumps as without Nexus and sends nothing.
    private static function isTestRun(): bool
    {
        if (\class_exists(self::TEST_CASE, false)) {
            return true;
        }

        return ($_SERVER['APP_ENV'] ?? $_ENV['APP_ENV'] ?? \getenv('APP_ENV')) === 'testing';
    }

    // The handler of the site prints the dump. So Laravel keeps its source link and Symfony keeps
    // its DebugBundle.
    private function dumpThroughSite(mixed $value, ?string $label): void
    {
        $this->prepareSite();
        Laravel::withSource($this->call['source'], static fn () => SiteVarDumper::dump($value, $label));
    }

    // Before each value, because a handler of the site can replace the handler of Nexus at any time.
    private function prepareSite(): void
    {
        if (!$this->call['send']) {
            return;
        }

        if (SiteVarDumper::isBlocked()) {
            $this->blocked();

            return;
        }

        SiteVarDumper::wrap($this->handler());
    }

    private function dumpWithOwnPrinter(mixed $value, ?string $label): void
    {
        $data = $this->call['send'] ? $this->sendDump($value, $label, $this->call) : null;

        if (!$this->call['shows']) {
            return;
        }

        ($this->ownPrinter())($data ?? $this->renderer()->cloneVar($value), $label);
    }

    private function handler(): \Closure
    {
        return $this->handler ??= function (mixed $var, mixed $label = null): void {
            $this->handle($var, \is_scalar($label) ? (string) $label : null);
        };
    }

    // The site calls this handler through VarDumper::dump(). Outside dump() of Nexus it makes its
    // own decision.
    private function handle(mixed $var, ?string $label): void
    {
        // A handler of the site that wrapped the handler of Nexus calls it again. Nexus then prints
        // the dump with the default handler. So the two handlers do not call each other without end.
        if ($this->depth > 0) {
            ($this->siteDefault())($var, $label);

            return;
        }

        ++$this->depth;

        try {
            $call = $this->call ?? $this->callContext();
            $previous = SiteVarDumper::previous();

            if ($call['send']) {
                $this->sendDump($var, $label, $call);
            }

            if ($call['shows']) {
                ($previous ?? $this->siteDefault())($var, $label);

                return;
            }

            if ($previous !== null) {
                self::withoutOutput(static fn () => $previous($var, $label));
            }
        } finally {
            --$this->depth;
        }
    }

    // A dump that does not show in the page still reaches the handler of the site. So a collector
    // such as the Symfony profiler or Laravel Telescope gets it. Its output stays out of the
    // response.
    private static function withoutOutput(\Closure $call): void
    {
        $level = \ob_get_level();
        \ob_start();

        try {
            $call();
        } finally {
            while (\ob_get_level() > $level) {
                \ob_end_clean();
            }
        }
    }

    // Returns the cloned value, or null when Nexus did not send it. Without a connection Nexus
    // makes no clone, no text and no tree.
    /** @param array{send: bool, isDd: bool, source: array{file: ?string, line: ?int}, shows: bool} $call */
    private function sendDump(mixed $var, ?string $label, array $call): ?Data
    {
        try {
            $time = \microtime(true);
            $this->ddCalled = $this->ddCalled || $call['isDd'];

            if (!$this->transport()->connect()) {
                return null;
            }

            $this->startSending();
            $rendered = $this->renderer()->render($var);

            $this->send('dump', ['dump' => [
                'seq' => ++$this->seq,
                'time' => $time,
                'kind' => $call['isDd'] ? 'dd' : 'dump',
                'file' => $call['source']['file'],
                'line' => $call['source']['line'],
                'label' => $label,
                'text' => $rendered['text'],
                'tree' => self::treeThatFits($rendered['text'], $rendered['tree']),
                'truncated' => $rendered['truncated'],
            ]]);

            return $rendered['data'];
        } catch (\Throwable) {
            // A dump that Nexus cannot send must never break the page or the command.
            return null;
        }
    }

    // A tree that cannot fit is left out before the first json_encode. So Nexus encodes it once.
    private static function treeThatFits(string $text, ?string $tree): ?string
    {
        if ($tree === null) {
            return null;
        }

        if (self::jsonLength($text) + self::jsonLength($tree) + self::EVENT_BYTES > self::MAX_LINE_BYTES) {
            return null;
        }

        return $tree;
    }

    // The length of a string in the JSON of the event. The text and the tree have no control
    // characters other than a new line.
    private static function jsonLength(string $value): int
    {
        return \strlen($value) + \substr_count($value, '"') + \substr_count($value, '\\') + \substr_count($value, "\n");
    }

    private function send(string $type, array $fields): void
    {
        $line = self::fittedLine(['v' => self::WIRE_VERSION, 'type' => $type, 'request' => $this->request()] + $fields);

        if ($line === null) {
            return;
        }

        $this->transport()->send($line);
    }

    // The line of the event, without the tree and then with a shorter text when it is too long.
    // Null when the line cannot fit.
    private static function fittedLine(array $event): ?string
    {
        $line = self::encode($event);

        if (!self::isTooLong($line)) {
            return $line;
        }

        if (!isset($event['dump'])) {
            return null;
        }

        $event['dump']['tree'] = null;
        $line = self::encode($event);

        if (!self::isTooLong($line)) {
            return $line;
        }

        $event['dump']['text'] = self::shorterText((string) $event['dump']['text'], \strlen((string) $line) - self::MAX_LINE_BYTES);
        $event['dump']['truncated'] = true;
        $line = self::encode($event);

        return self::isTooLong($line) ? null : $line;
    }

    private static function encode(array $event): ?string
    {
        $line = \json_encode($event, self::JSON_FLAGS);

        return $line === false ? null : $line;
    }

    private static function isTooLong(?string $line): bool
    {
        if ($line === null) {
            return false;
        }

        return \strlen($line) > self::MAX_LINE_BYTES;
    }

    // Each byte that goes from the text takes at least one byte from the line. The text ends with
    // a whole line when it has one.
    private static function shorterText(string $text, int $extraBytes): string
    {
        $length = \max(0, \strlen($text) - $extraBytes);
        $lastNewLine = \strrpos(\substr($text, 0, $length), "\n");

        if ($lastNewLine === false) {
            return \mb_strcut($text, 0, $length, 'UTF-8');
        }

        return \substr($text, 0, $lastNewLine);
    }

    private function startSending(): void
    {
        if ($this->sending) {
            return;
        }

        $this->sending = true;
        \register_shutdown_function($this->finish(...));
        Laravel::listenForExitCode();
    }

    // The app explains why it shows no dumps of the site.
    private function blocked(): void
    {
        if ($this->blockedChecked) {
            return;
        }

        $this->blockedChecked = true;

        try {
            $stamp = "blocked-{$this->blockKey()}";

            if ($this->transport()->touchedWithin($stamp, self::BLOCKED_SECONDS)) {
                return;
            }

            $this->transport()->touch($stamp);
            $this->send('blocked', ['reason' => 'var_dumper_format', 'detail' => SiteVarDumper::format()]);
        } catch (\Throwable) {
            // The note in the app is a help. It must never break the page or the command.
        }
    }

    // One stamp for each host. So one site with the key does not hide the note of another site.
    private function blockKey(): string
    {
        $request = $this->request();
        $host = (string) ($request['host'] ?? '');

        if ($host !== '') {
            return \preg_replace('/[^a-z0-9.-]/', '_', \strtolower($host)) ?? 'host';
        }

        return 'cli-'.\substr(\sha1((string) ($request['root'] ?? '')), 0, 12);
    }

    private static function status(bool $fatal): ?int
    {
        if (isCli()) {
            return null;
        }

        if ($fatal) {
            return 500;
        }

        $code = \http_response_code();

        return \is_int($code) ? $code : null;
    }

    private function exitCode(bool $fatal): ?int
    {
        if ($fatal) {
            return 255;
        }

        if ($this->ddCalled) {
            return 1;
        }

        return Laravel::$exitCode;
    }

    private function request(): array
    {
        return $this->request ??= Request::describe($_SERVER, isCli());
    }

    private function transport(): Transport
    {
        return $this->transport ??= new Transport(
            (string) ($this->settings['socket'] ?? ''),
            \rtrim((string) ($this->settings['folder'] ?? ''), '/'),
        );
    }

    private function renderer(): Renderer
    {
        return $this->renderer ??= new Renderer();
    }

    // Without a handler of its own, VarDumper of the site makes one. The printer of Nexus follows
    // the same rules when that fails.
    private function siteDefault(): \Closure
    {
        return $this->siteDefault ??= SiteVarDumper::defaultHandler()
            ?? fn (mixed $var, ?string $label = null) => ($this->ownPrinter())($this->renderer()->cloneVar($var), $label);
    }

    // The same choice of dumper as VarDumper 7.4 makes without VAR_DUMPER_FORMAT.
    private function ownPrinter(): \Closure
    {
        if ($this->ownPrinter !== null) {
            return $this->ownPrinter;
        }

        $cli = isCli();
        $accept = (string) ($_SERVER['HTTP_ACCEPT'] ?? ($cli ? 'txt' : 'html'));

        $dumper = match (true) {
            \str_contains($accept, 'html'), \str_contains($accept, '*/*') => new HtmlDumper(),
            $cli => new NexusCliDumper(),
            default => new NexusCliDumper('php://output'),
        };

        return $this->ownPrinter = static function (Data $data, ?string $label) use ($dumper): void {
            $dumper->dump($label === null ? $data : $data->withContext(['label' => $label]));
        };
    }
}
