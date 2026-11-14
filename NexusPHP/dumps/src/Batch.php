<?php

declare(strict_types=1);

namespace Nexus\Dumps;

/*
 * The state of one request on the wire: its request object, its seq counter and the queries, log
 * lines and job rows that wait to go out. A job of a worker is a request of its own.
 */
final class Batch
{
    public const MAX_QUERIES = 500;

    // A long process sends its waiting entries when this many wait or when this time passed since
    // its last send. So its memory stays small and the app shows its entries soon.
    public const SEND_COUNT = 50;
    public const SEND_SECONDS = 1.0;

    // The outcome of a job that an event knew before the end of the job.
    public ?string $outcome = null;

    private int $seq = 0;

    /** @var list<array<string, mixed>> */
    private array $entries = [];

    private int $queries = 0;

    private int $droppedQueries = 0;

    private float $sentAt;

    private bool $sent = false;

    // The handle is what the system of a job knows the job by, for example the job object of
    // Laravel. settle finds the outcome of a job that ended without its own end event.
    /** @param ?\Closure(): ?string $settle */
    public function __construct(
        public readonly array $request,
        public readonly mixed $handle = null,
        public readonly ?\Closure $settle = null,
    ) {
        $this->sentAt = (float) $request['started'];
    }

    public function nextSeq(): int
    {
        return ++$this->seq;
    }

    // A request keeps its first 500 queries and counts the rest.
    public function takesQuery(): bool
    {
        if ($this->queries >= self::MAX_QUERIES) {
            ++$this->droppedQueries;

            return false;
        }

        ++$this->queries;

        return true;
    }

    // The wire format leaves out an optional key without a value.
    public function add(array $entry): void
    {
        $this->entries[] = ['seq' => $this->nextSeq()]
            + \array_filter($entry, static fn (mixed $value): bool => $value !== null)
            + ['truncated' => false];
    }

    public function isDue(float $now): bool
    {
        if (\count($this->entries) >= self::SEND_COUNT) {
            return true;
        }

        return $now - $this->sentAt >= self::SEND_SECONDS;
    }

    /** @return list<array<string, mixed>> */
    public function take(float $now): array
    {
        $entries = $this->entries;
        $this->entries = [];
        $this->sentAt = $now;

        return $entries;
    }

    public function markSent(): void
    {
        $this->sent = true;
    }

    public function wasSent(): bool
    {
        return $this->sent;
    }

    /** @return array{droppedQueries?: int} */
    public function dropped(): array
    {
        return $this->droppedQueries > 0 ? ['droppedQueries' => $this->droppedQueries] : [];
    }
}
