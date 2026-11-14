<?php

declare(strict_types=1);

namespace Nexus\Dumps;

use Nexus\Dumps\VarDumper\Caster\ScalarStub;
use Nexus\Dumps\VarDumper\Cloner\Data;
use Nexus\Dumps\VarDumper\Dumper\HtmlDumper;

/*
 * Sends each dump, query, log line and job row of this request or command to nexusd and decides if
 * a dump also shows in the page. One instance lives for the whole process. A job of a worker is a
 * request of its own for the time of the job.
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

    private static ?self $instance = null;

    private ?Batch $batch = null;

    /** @var list<Batch> The requests that a job interrupted, the newest last. */
    private array $outer = [];

    private ?Transport $transport = null;

    private ?Renderer $renderer = null;

    private bool $sending = false;

    private bool $ddCalled = false;

    private bool $blockedChecked = false;

    // An error that Nexus silences with @ replaces the last error of PHP. So Nexus keeps the fatal
    // error of the request before it works at the shutdown.
    private bool $fatal = false;

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

    // One query, log line or job row. A missing or paused nexusd and a query after the first 500
    // cost no text and no tree. So the fields come from a closure that runs only when the entry
    // goes out. The source comes from a trace unless the fields hold a file.
    /** @param \Closure(): array<string, mixed> $fields */
    public function entry(string $kind, \Closure $fields): void
    {
        $time = \microtime(true);

        if (!$this->accepts()) {
            return;
        }

        if ($kind === 'query' && !$this->batch()->takesQuery()) {
            return;
        }

        $entry = $fields();
        $source = \array_key_exists('file', $entry) ? $entry : Source::here();
        [$text, $truncated] = Renderer::cut((string) ($entry['text'] ?? ''));

        $this->add([
            'time' => $entry['time'] ?? $time,
            'kind' => $kind,
            'file' => $source['file'] ?? null,
            'line' => $source['line'] ?? null,
            'label' => $entry['label'] ?? null,
            'text' => $text,
            'tree' => $entry['tree'] ?? null,
            'pattern' => \is_string($entry['pattern'] ?? null) ? Renderer::cut($entry['pattern'])[0] : null,
            'ms' => $entry['ms'] ?? null,
            'detail' => $entry['detail'] ?? null,
            'ref' => $entry['ref'] ?? null,
            'truncated' => $truncated,
        ]);
    }

    // The context of a log line gets the same tree as a dump.
    public function tree(mixed $value): ?string
    {
        return $this->renderer()->tree($value);
    }

    // The entries of the request before the job go out first. So a worker keeps nothing of its
    // own in memory during a job.
    /** @param ?\Closure(): ?string $settle */
    public function startJob(array $job, mixed $handle, ?\Closure $settle = null): void
    {
        if (isTestRun($_SERVER)) {
            return;
        }

        $this->startSending();
        $this->flush();

        $outer = $this->batch();
        $this->outer[] = $outer;
        $this->batch = new Batch(Request::forJob($outer->request, $job), $handle, $settle);
    }

    public function runsJob(): bool
    {
        return $this->outer !== [];
    }

    // Each system ends its own job. The handle tells which job an event is about.
    public function endJob(mixed $handle, string $outcome): void
    {
        if ($this->job()?->handle !== $handle) {
            return;
        }

        $this->closeJob($outcome);
    }

    // An event can know the outcome of a job before the job ends.
    public function noteOutcome(mixed $handle, string $outcome): void
    {
        $job = $this->job();

        if ($job?->handle === $handle) {
            $job->outcome ??= $outcome;
        }
    }

    // A job that did not reach its own end. An outcome that an event gave comes first. Then the
    // state of the job decides. Without both the job failed.
    public function endOpenJob(): void
    {
        $job = $this->job();

        if ($job === null) {
            return;
        }

        $settled = $job->settle === null ? null : ($job->settle)();

        $this->closeJob($job->outcome ?? $settled ?? 'failed');
    }

    // The app explains why it shows no dumps or no queries of the site. A stamp file keeps the
    // note to one in 60 s for each host and reason.
    public function block(string $reason, ?string $detail): void
    {
        if (isTestRun($_SERVER)) {
            return;
        }

        try {
            $stamp = $reason === 'var_dumper_format'
                ? "blocked-{$this->blockKey()}"
                : "blocked-{$reason}-{$this->blockKey()}";

            if ($this->transport()->touchedWithin($stamp, self::BLOCKED_SECONDS)) {
                return;
            }

            $this->transport()->touch($stamp);
            $this->send('blocked', ['reason' => $reason, 'detail' => $detail]);
        } catch (\Throwable) {
            // The note in the app is a help. It must never break the page or the command.
        }
    }

    public function noteFatal(): void
    {
        $this->fatal = true;
    }

    public function finish(): void
    {
        $fatal = $this->fatal || self::isFatal(\error_get_last());

        try {
            $this->endOpenJobs();
            $this->flush();

            if (!$this->batch()->wasSent()) {
                return;
            }

            $this->send('end', [
                'status' => self::status($fatal),
                'exit' => isCli() ? $this->exitCode($fatal) : null,
                'duration' => self::since($this->request()['started']),
            ] + $this->batch()->dropped());
        } catch (\Throwable) {
            // PHP prints an error of a shutdown function at the end of the page. A lost end event
            // is the smaller problem.
        }
    }

    // A job that is still open at the end of the process did not end in a normal way.
    private function endOpenJobs(): void
    {
        while ($this->outer !== []) {
            $this->endOpenJob();
        }
    }

    private function accepts(): bool
    {
        if (isTestRun($_SERVER)) {
            return false;
        }

        try {
            return $this->transport()->connect();
        } catch (\Throwable) {
            return false;
        }
    }

    private function add(array $entry): void
    {
        $this->startSending();

        $batch = $this->batch();
        $batch->add($entry);

        if ($batch->isDue(\microtime(true))) {
            $this->flush();
        }
    }

    private function job(): ?Batch
    {
        return $this->outer === [] ? null : $this->batch;
    }

    // A worker sends and forgets each job at its end. So its memory stays the same.
    private function closeJob(string $outcome): void
    {
        $job = $this->batch();
        $this->flush();
        $this->send('end', [
            'status' => null,
            'exit' => null,
            'duration' => self::since($job->request['started']),
            'outcome' => $outcome,
        ] + $job->dropped());

        $this->batch = \array_pop($this->outer);
    }

    private static function since(mixed $started): float
    {
        return \round(\max(0.0, \microtime(true) - (float) $started), 6);
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
            'send' => !isTestRun($_SERVER),
            'isDd' => $isDd,
            'source' => Source::find($trace),
            'shows' => PageMode::showsInPage((string) ($this->settings['page'] ?? PageMode::AUTOMATIC), $_SERVER, $isDd, isCli()),
        ];
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
                'seq' => $this->batch()->nextSeq(),
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

        $this->batch()->markSent();
        $this->transport()->send($line);
    }

    // The waiting entries of the request that runs now go out in as few lines as fit.
    private function flush(): void
    {
        $batch = $this->batch;

        if ($batch === null) {
            return;
        }

        $entries = $batch->take(\microtime(true));

        if ($entries === []) {
            return;
        }

        // A request with entries gets its end event, also when an entry could not fit in a line.
        $batch->markSent();

        foreach (self::entryLines($batch->request, $entries) as $line) {
            $this->transport()->send($line);
        }
    }

    // Each entry is encoded once. The lines are joined from the parts. An entry that cannot fit
    // in a line alone goes without its tree and then with a shorter text, as a dump does.
    /**
     * @param list<array<string, mixed>> $entries
     * @return list<string>
     */
    private static function entryLines(array $request, array $entries): array
    {
        $requestJson = self::encode($request);

        if ($requestJson === null) {
            return [];
        }

        $head = '{"v":'.self::WIRE_VERSION.',"type":"entries","request":'.$requestJson.',"entries":[';
        $room = self::MAX_LINE_BYTES - \strlen($head) - 2;
        $lines = [];
        $parts = [];
        $length = 0;

        foreach ($entries as $entry) {
            $json = self::fitted($entry, $room, self::encode(...));

            if ($json === null) {
                continue;
            }

            if ($parts !== [] && $length + 1 + \strlen($json) > $room) {
                $lines[] = $head.\implode(',', $parts).']}';
                $parts = [];
                $length = 0;
            }

            $length += ($parts === [] ? 0 : 1) + \strlen($json);
            $parts[] = $json;
        }

        if ($parts !== []) {
            $lines[] = $head.\implode(',', $parts).']}';
        }

        return $lines;
    }

    // The line of the event. Only a dump has a tree and a text that can go or get shorter.
    private static function fittedLine(array $event): ?string
    {
        if (isset($event['dump'])) {
            return self::fitted($event['dump'], self::MAX_LINE_BYTES, static fn (array $dump): ?string => self::encode(\array_replace($event, ['dump' => $dump])));
        }

        $line = self::encode($event);

        return $line !== null && \strlen($line) > self::MAX_LINE_BYTES ? null : $line;
    }

    // The JSON that $encode makes from the fields. When it is longer than $room the fields go
    // without their tree and then with a shorter text. Null when they still cannot fit.
    /** @param \Closure(array): ?string $encode */
    private static function fitted(array $fields, int $room, \Closure $encode): ?string
    {
        $json = $encode($fields);

        if ($json === null || \strlen($json) <= $room) {
            return $json;
        }

        $fields['tree'] = null;
        $json = $encode($fields);

        if ($json === null || \strlen($json) <= $room) {
            return $json;
        }

        $fields['text'] = self::shorterText((string) ($fields['text'] ?? ''), \strlen($json) - $room);
        $fields['truncated'] = true;
        $json = $encode($fields);

        return $json !== null && \strlen($json) <= $room ? $json : null;
    }

    private static function encode(array $event): ?string
    {
        $line = \json_encode($event, self::JSON_FLAGS);

        return $line === false ? null : $line;
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
        \register_shutdown_function($this->finishLast(...));
        Laravel::listenForExitCode();
    }

    // Other shutdown functions can still log, for example the handler of Laravel for a fatal
    // error. So the end goes to the end of the queue when the shutdown starts.
    private function finishLast(): void
    {
        $this->fatal = $this->fatal || self::isFatal(\error_get_last());
        \register_shutdown_function($this->finish(...));
    }

    // The app explains why it shows no dumps of the site.
    private function blocked(): void
    {
        if ($this->blockedChecked) {
            return;
        }

        $this->blockedChecked = true;
        $this->block('var_dumper_format', SiteVarDumper::format());
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
        return $this->batch()->request;
    }

    private function batch(): Batch
    {
        return $this->batch ??= new Batch(Request::describe($_SERVER, isCli()));
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
