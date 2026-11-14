<?php

declare(strict_types=1);

namespace Nexus\Dumps;

/*
 * The listeners for the events of a Laravel application, Laravel 10 to 13. The prepend file adds
 * them when BootProviders loads. Nexus checks each property and each method first, because the
 * events changed between the versions.
 */
final class LaravelEvents
{
    private const SYNC_JOB = 'Illuminate\Queue\Jobs\SyncJob';
    private const LOGGER = 'Illuminate\Log\Logger';
    private const SYNC_DRIVERS = ['sync', 'deferred'];
    private const WORKER_COMMANDS = ['queue:work', 'queue:listen', 'horizon:work', 'horizon:supervisor'];

    /** @var array<int, array{time: float, source: array{file: ?string, line: ?int}}> */
    private static array $syncJobs = [];

    // A command that ran a job of a queue is a worker from then on.
    private static bool $worker = false;

    // The first argument of artisan that is not an option. An empty text for none.
    private static ?string $command = null;

    public static function query(object $event): void
    {
        $catcher = Catcher::instance();

        if (self::isWorkerPoll($catcher)) {
            return;
        }

        $catcher->entry('query', static function () use ($event): array {
            $sql = \is_string($event->sql ?? null) ? $event->sql : '';

            return [
                'label' => self::text($event->connectionName ?? null),
                'text' => self::rawSql($event, $sql),
                'pattern' => $sql,
                'ms' => \is_numeric($event->time ?? null) ? \round((float) $event->time, 3) : null,
            ];
        });
    }

    // The trace with its objects gives the logger and so the channel.
    public static function log(object $event): void
    {
        $catcher = Catcher::instance();

        $catcher->entry('log', static function () use ($event, $catcher): array {
            $trace = \debug_backtrace(\DEBUG_BACKTRACE_IGNORE_ARGS | \DEBUG_BACKTRACE_PROVIDE_OBJECT, Source::FRAMES);
            $context = \is_array($event->context ?? null) ? $event->context : [];

            return [
                ...Source::inSite($trace),
                'label' => \strtolower(self::text($event->level ?? null) ?? 'info'),
                'text' => self::message($event->message ?? ''),
                'tree' => $context === [] ? null : $catcher->tree($context),
                'detail' => self::channel($trace),
            ];
        });
    }

    // A job on the sync connection runs at once and shows as a sync row.
    public static function queued(object $event): void
    {
        $connection = self::text($event->connectionName ?? null) ?? '';

        if (\in_array(Laravel::config("queue.connections.{$connection}.driver"), self::SYNC_DRIVERS, true)) {
            return;
        }

        Catcher::instance()->entry('job', static function () use ($event, $connection): array {
            $payload = self::payload($event->payload ?? null);
            $job = $event->job ?? null;

            return [
                'label' => 'queued',
                'text' => self::text($payload['displayName'] ?? null) ?? self::queuedName($job),
                'detail' => self::where($connection, self::queuedQueue($event, $job, $connection)),
                'ref' => self::text($payload['uuid'] ?? null),
            ];
        });
    }

    // A job of a worker becomes a request of its own. A sync job becomes a row of the request
    // that runs it.
    public static function processing(object $event): void
    {
        $job = $event->job ?? null;

        if (!\is_object($job)) {
            return;
        }

        if (\is_a($job, self::SYNC_JOB)) {
            self::$syncJobs[\spl_object_id($job)] = [
                'time' => \microtime(true),
                'source' => Source::here(),
            ];

            return;
        }

        if (!isCli()) {
            return;
        }

        self::$worker = true;
        $catcher = Catcher::instance();
        $catcher->endOpenJob();

        $catcher->startJob([
            'system' => 'laravel',
            'name' => self::jobName($job),
            'queue' => self::text(self::call($job, 'getQueue')),
            'connection' => self::text($event->connectionName ?? null) ?? self::text(self::call($job, 'getConnectionName')),
            'uuid' => self::text(self::call($job, 'uuid')),
            'attempt' => self::number(self::call($job, 'attempts')),
            'maxTries' => self::number(self::call($job, 'maxTries')),
        ], $job, static fn (): ?string => self::stateOf($job));
    }

    // A job that called $this->fail() or $this->release() still ends with this event.
    public static function processed(object $event): void
    {
        $job = $event->job ?? null;

        if (!\is_object($job)) {
            return;
        }

        if (self::endSyncJob($job, self::stateOf($job) === 'failed' ? 'failed' : 'sync')) {
            return;
        }

        Catcher::instance()->endJob($job, self::stateOf($job) ?? 'done');
    }

    // The worker reports the exception of a failed job after this event. So the job stays open
    // until the worker loops or takes the next job. Then its log line belongs to the job.
    public static function failed(object $event): void
    {
        self::remember($event, 'failed');
    }

    public static function released(object $event): void
    {
        self::remember($event, 'released');
    }

    // The worker loops after it reported the exception of a job. That job ends now.
    public static function looping(): void
    {
        Catcher::instance()->endOpenJob();
    }

    private static function remember(object $event, string $outcome): void
    {
        $job = $event->job ?? null;

        if (!\is_object($job)) {
            return;
        }

        if (self::endSyncJob($job, $outcome === 'failed' ? 'failed' : 'sync')) {
            return;
        }

        Catcher::instance()->noteOutcome($job, $outcome);
    }

    // The row of a sync job that worked has the label sync. A sync job that threw has the label
    // failed.
    private static function endSyncJob(object $job, string $label): bool
    {
        $id = \spl_object_id($job);
        $started = self::$syncJobs[$id] ?? null;

        if ($started === null) {
            return false;
        }

        unset(self::$syncJobs[$id]);

        Catcher::instance()->entry('job', static fn (): array => [
            ...$started['source'],
            'time' => $started['time'],
            'label' => $label,
            'text' => self::jobName($job),
            'ms' => \round((\microtime(true) - $started['time']) * 1000, 3),
            'detail' => self::where(self::text(self::call($job, 'getConnectionName')) ?? 'sync', self::text(self::call($job, 'getQueue'))),
        ]);

        return true;
    }

    // A worker polls its queue with queries between its jobs. A worker that runs for an hour would
    // fill the list with them. Its dumps and log lines outside a job still go out.
    private static function isWorkerPoll(Catcher $catcher): bool
    {
        if ($catcher->runsJob()) {
            return false;
        }

        return self::$worker || \in_array(self::command(), self::WORKER_COMMANDS, true);
    }

    private static function command(): string
    {
        if (self::$command !== null) {
            return self::$command;
        }

        $arguments = isCli() && \is_array($_SERVER['argv'] ?? null) ? \array_slice($_SERVER['argv'], 1) : [];

        foreach ($arguments as $argument) {
            if (\is_string($argument) && !\str_starts_with($argument, '-')) {
                return self::$command = $argument;
            }
        }

        return self::$command = '';
    }

    private static function stateOf(object $job): ?string
    {
        if (self::call($job, 'hasFailed') === true) {
            return 'failed';
        }

        if (self::call($job, 'isReleased') === true) {
            return 'released';
        }

        return null;
    }

    // Laravel 11 and later give the SQL with its values. They can fail on a binary value.
    private static function rawSql(object $event, string $sql): string
    {
        if (\method_exists($event, 'toRawSql')) {
            try {
                return (string) $event->toRawSql();
            } catch (\Throwable) {
                // The values go in below.
            }
        }

        return Sql::withBindings($sql, \is_array($event->bindings ?? null) ? $event->bindings : []);
    }

    // MessageLogged has no channel. The logger that sent it is in the trace, and the log manager
    // knows the name of each channel that it made.
    private static function channel(array $trace): ?string
    {
        foreach ($trace as $frame) {
            $logger = $frame['object'] ?? null;

            if (!\is_object($logger) || !\is_a($logger, self::LOGGER)) {
                continue;
            }

            $manager = Laravel::service('log');

            if ($manager === null || !\method_exists($manager, 'getChannels')) {
                return null;
            }

            $name = \array_search($logger, (array) $manager->getChannels(), true);

            return \is_string($name) ? $name : null;
        }

        return null;
    }

    private static function message(mixed $message): string
    {
        if (\is_string($message)) {
            return $message;
        }

        if (\is_scalar($message) || $message instanceof \Stringable) {
            return (string) $message;
        }

        return (string) \json_encode($message, Catcher::JSON_FLAGS | \JSON_PARTIAL_OUTPUT_ON_ERROR);
    }

    private static function payload(mixed $payload): array
    {
        if (\is_array($payload)) {
            return $payload;
        }

        if (!\is_string($payload)) {
            return [];
        }

        $decoded = \json_decode($payload, true);

        return \is_array($decoded) ? $decoded : [];
    }

    private static function queuedName(mixed $job): string
    {
        if (\is_string($job)) {
            return $job;
        }

        if (!\is_object($job)) {
            return 'job';
        }

        return self::text(self::call($job, 'displayName')) ?? $job::class;
    }

    // Laravel 11 and later give the queue in the event. In older versions the job knows it or the
    // connection has a default queue.
    private static function queuedQueue(object $event, mixed $job, string $connection): ?string
    {
        $queue = self::text($event->queue ?? null);

        if ($queue === null && \is_object($job)) {
            $queue = self::text($job->queue ?? null);
        }

        return $queue ?? self::text(Laravel::config("queue.connections.{$connection}.queue"));
    }

    private static function jobName(object $job): string
    {
        return self::text(self::call($job, 'resolveName'))
            ?? self::text(self::call($job, 'getName'))
            ?? $job::class;
    }

    private static function where(string $connection, ?string $queue): ?string
    {
        if ($connection === '') {
            return $queue;
        }

        return $queue === null ? $connection : "{$connection} · {$queue}";
    }

    private static function call(object $object, string $method): mixed
    {
        if (!\method_exists($object, $method)) {
            return null;
        }

        try {
            return $object->{$method}();
        } catch (\Throwable) {
            return null;
        }
    }

    private static function text(mixed $value): ?string
    {
        if (\is_int($value)) {
            return (string) $value;
        }

        if (!\is_string($value) || $value === '') {
            return null;
        }

        return $value;
    }

    private static function number(mixed $value): ?int
    {
        if (\is_int($value)) {
            return $value;
        }

        return \is_string($value) && \ctype_digit($value) ? (int) $value : null;
    }
}
