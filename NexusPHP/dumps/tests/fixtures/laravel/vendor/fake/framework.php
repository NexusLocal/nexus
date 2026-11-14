<?php

declare(strict_types=1);

// The parts of Laravel that Nexus uses, with the same names, properties and order of events.

namespace Illuminate\Container {
    class Container
    {
        protected static $instance;

        protected array $instances = [];

        public static function getInstance(): static
        {
            return static::$instance ??= new static();
        }

        public static function setInstance(?Container $container = null): void
        {
            static::$instance = $container;
        }

        public function instance(string $name, mixed $value): mixed
        {
            return $this->instances[$name] = $value;
        }

        public function bound(string $name): bool
        {
            return isset($this->instances[$name]);
        }

        public function make(string $name): mixed
        {
            return $this->instances[$name] ?? new $name();
        }
    }
}

namespace Illuminate\Foundation {
    use Illuminate\Container\Container;

    final class Application extends Container
    {
        public bool $booted = false;

        public function __construct(private readonly string $basePath)
        {
            static::setInstance($this);
        }

        public function basePath(string $path = ''): string
        {
            return $this->basePath;
        }

        public function bootstrapWith(array $bootstrappers): void
        {
            foreach ($bootstrappers as $bootstrapper) {
                $this->make($bootstrapper)->bootstrap($this);
            }
        }
    }
}

namespace Illuminate\Events {
    final class Dispatcher
    {
        private array $listeners = [];

        public function listen(string $event, callable $listener): void
        {
            $this->listeners[$event][] = $listener;
        }

        public function dispatch(object $event): void
        {
            foreach ($this->listeners[$event::class] ?? [] as $listener) {
                if ($listener($event) === false) {
                    return;
                }
            }
        }

        public function until(object $event): mixed
        {
            foreach ($this->listeners[$event::class] ?? [] as $listener) {
                $response = $listener($event);

                if ($response !== null) {
                    return $response;
                }
            }

            return null;
        }
    }
}

namespace Illuminate\Config {
    final class Repository
    {
        public function __construct(private readonly array $items)
        {
        }

        public function get(string $key): mixed
        {
            $value = $this->items;

            foreach (explode('.', $key) as $part) {
                if (!is_array($value) || !array_key_exists($part, $value)) {
                    return null;
                }

                $value = $value[$part];
            }

            return $value;
        }
    }
}

namespace Illuminate\Database {
    use Illuminate\Database\Events\QueryExecuted;
    use Illuminate\Events\Dispatcher;

    final class Connection
    {
        public function __construct(private readonly string $name, private readonly Dispatcher $events)
        {
        }

        public function getName(): string
        {
            return $this->name;
        }

        public function select(string $sql, array $bindings = []): array
        {
            $this->events->dispatch(new QueryExecuted($sql, $bindings, 0.42, $this));

            return [];
        }
    }
}

namespace Illuminate\Database\Events {
    use Illuminate\Database\Connection;

    final class QueryExecuted
    {
        public string $connectionName;

        public function __construct(public string $sql, public array $bindings, public ?float $time, public Connection $connection)
        {
            $this->connectionName = $connection->getName();
        }

        // As in Laravel 11 and later. The quotes differ from the own walk of Nexus, so a test sees
        // which one made the text. The legacy connection fails as Laravel does on a binary value.
        public function toRawSql(): string
        {
            if ($this->connectionName === 'legacy') {
                throw new \RuntimeException('Strings with null bytes cannot be escaped.');
            }

            $bindings = $this->bindings;

            return (string) preg_replace_callback('/\?/', static function () use (&$bindings): string {
                return '"'.array_shift($bindings).'"';
            }, $this->sql);
        }
    }
}

namespace Illuminate\Log {
    use Illuminate\Events\Dispatcher;
    use Illuminate\Log\Events\MessageLogged;

    class Logger
    {
        public function __construct(private readonly Dispatcher $events)
        {
        }

        public function error(mixed $message, array $context = []): void
        {
            $this->writeLog('error', $message, $context);
        }

        public function warning(mixed $message, array $context = []): void
        {
            $this->writeLog('warning', $message, $context);
        }

        public function info(mixed $message, array $context = []): void
        {
            $this->writeLog('info', $message, $context);
        }

        protected function writeLog(string $level, mixed $message, array $context): void
        {
            $GLOBALS['written'][] = "{$level}: {$message}";
            $this->events->dispatch(new MessageLogged($level, $message, $context));
        }
    }

    final class LogManager
    {
        private array $channels = [];

        public function __construct(private readonly Dispatcher $events)
        {
        }

        public function channel(?string $name = null): Logger
        {
            return $this->channels[$name ?? 'stack'] ??= new Logger($this->events);
        }

        public function getChannels(): array
        {
            return $this->channels;
        }

        public function __call(string $method, array $arguments): mixed
        {
            return $this->channel()->{$method}(...$arguments);
        }
    }
}

namespace Illuminate\Log\Events {
    final class MessageLogged
    {
        public function __construct(public string $level, public mixed $message, public array $context = [])
        {
        }
    }
}

namespace Illuminate\Queue\Jobs {
    class Job
    {
        private bool $failed = false;

        private bool $released = false;

        public function __construct(
            private readonly string $name,
            private readonly string $connection,
            private readonly string $queue,
            private readonly ?string $uuid,
            private readonly int $attempts,
            private readonly ?int $maxTries,
            private readonly \Closure $handler,
        ) {
        }

        public function fire(): void
        {
            ($this->handler)($this);
        }

        public function resolveName(): string
        {
            return $this->name;
        }

        public function getQueue(): string
        {
            return $this->queue;
        }

        public function getConnectionName(): string
        {
            return $this->connection;
        }

        public function uuid(): ?string
        {
            return $this->uuid;
        }

        public function attempts(): int
        {
            return $this->attempts;
        }

        public function maxTries(): ?int
        {
            return $this->maxTries;
        }

        public function hasFailed(): bool
        {
            return $this->failed;
        }

        public function isReleased(): bool
        {
            return $this->released;
        }

        public function isDeleted(): bool
        {
            return false;
        }

        public function markAsFailed(): void
        {
            $this->failed = true;
        }

        public function release(): void
        {
            $this->released = true;
        }
    }

    final class RedisJob extends Job
    {
    }

    final class SyncJob extends Job
    {
    }
}

namespace Illuminate\Queue\Events {
    final class JobQueued
    {
        public function __construct(public string $connectionName, public mixed $id, public mixed $job, public ?string $payload = null, public ?string $queue = null)
        {
        }
    }

    final class JobProcessing
    {
        public function __construct(public string $connectionName, public object $job)
        {
        }
    }

    final class JobProcessed
    {
        public function __construct(public string $connectionName, public object $job)
        {
        }
    }

    final class JobFailed
    {
        public function __construct(public string $connectionName, public object $job, public \Throwable $exception)
        {
        }
    }

    final class JobExceptionOccurred
    {
        public function __construct(public string $connectionName, public object $job, public \Throwable $exception)
        {
        }
    }

    final class JobReleasedAfterException
    {
        public function __construct(public string $connectionName, public object $job)
        {
        }
    }

    final class Looping
    {
        public function __construct(public string $connectionName, public string $queue)
        {
        }
    }
}

namespace Illuminate\Queue {
    use Illuminate\Events\Dispatcher;
    use Illuminate\Log\LogManager;
    use Illuminate\Queue\Events\JobExceptionOccurred;
    use Illuminate\Queue\Events\JobFailed;
    use Illuminate\Queue\Events\JobProcessed;
    use Illuminate\Queue\Events\JobProcessing;
    use Illuminate\Queue\Events\JobQueued;
    use Illuminate\Queue\Events\JobReleasedAfterException;
    use Illuminate\Queue\Events\Looping;
    use Illuminate\Queue\Jobs\Job;
    use Illuminate\Queue\Jobs\SyncJob;

    // The order of the events of the worker of Laravel 10 to 13. The worker reports the exception
    // of a job after the events of the job.
    final class Worker
    {
        public function __construct(private readonly Dispatcher $events, private readonly LogManager $log)
        {
        }

        public function daemon(array $jobs): void
        {
            foreach ($jobs as $job) {
                $this->events->until(new Looping('redis', 'default'));
                $this->runJob($job);
            }

            $this->events->until(new Looping('redis', 'default'));
        }

        public function runNextJob(Job $job): void
        {
            $this->runJob($job);
        }

        private function runJob(Job $job): void
        {
            try {
                $this->process($job);
            } catch (\Throwable $exception) {
                $this->log->error($exception->getMessage(), ['exception' => $exception::class]);
            }
        }

        private function process(Job $job): void
        {
            try {
                $this->events->dispatch(new JobProcessing('redis', $job));
                $job->fire();
                $this->events->dispatch(new JobProcessed('redis', $job));
            } catch (\Throwable $exception) {
                $this->handleJobException($job, $exception);
            }
        }

        private function handleJobException(Job $job, \Throwable $exception): never
        {
            try {
                if ($job->maxTries() !== null && $job->attempts() >= $job->maxTries()) {
                    $job->markAsFailed();
                    $this->events->dispatch(new JobFailed('redis', $job, $exception));
                }

                $this->events->dispatch(new JobExceptionOccurred('redis', $job, $exception));
            } finally {
                if (!$job->isReleased() && !$job->hasFailed()) {
                    $job->release();
                    $this->events->dispatch(new JobReleasedAfterException('redis', $job));
                }
            }

            throw $exception;
        }
    }

    final class Queue
    {
        public function __construct(private readonly Dispatcher $events)
        {
        }

        public function pushToRedis(object $job, string $uuid): void
        {
            $payload = json_encode(['uuid' => $uuid, 'displayName' => $job::class]);
            $this->events->dispatch(new JobQueued('redis', 'redis-id-1', $job, $payload, 'default'));
        }

        // A newer SyncQueue also sends JobQueued. Nexus shows the job only as a sync row.
        public function pushToSync(SyncJob $job): void
        {
            $this->events->dispatch(new JobQueued('sync', 0, $job, '{"uuid":"sync-uuid"}', 'default'));
            $this->events->dispatch(new JobProcessing('sync', $job));

            try {
                $job->fire();
            } catch (\Throwable $exception) {
                $job->markAsFailed();
                $this->events->dispatch(new JobFailed('sync', $job, $exception));

                throw $exception;
            }

            $this->events->dispatch(new JobProcessed('sync', $job));
        }
    }
}
