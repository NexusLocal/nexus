<?php

declare(strict_types=1);

namespace Nexus\Dumps;

/*
 * Sends one JSON line for each event to the Unix socket of nexusd. A dump must never make a page
 * slow. So a line gets at most 50 ms. After a failure no PHP process sends for 10 seconds.
 */
final class Transport
{
    public const PAUSE_SECONDS = 10;
    public const PAUSE_FILE = 'paused';

    private const CONNECT_SECONDS = 0.05;
    private const WRITE_SECONDS = 0.05;

    /** @var resource|null */
    private $stream = null;

    // The end of a pause that this process already knows. Until then it reads no file.
    private float $quietUntil = 0.0;

    public function __construct(
        private readonly string $socket,
        private readonly string $folder,
    ) {
    }

    // Nexus calls this before it clones a value. So a paused or missing nexusd costs a dump almost
    // nothing.
    public function connect(): bool
    {
        if ($this->stream !== null) {
            return true;
        }

        if ($this->socket === '') {
            return false;
        }

        $now = \microtime(true);

        if ($now < $this->quietUntil) {
            return false;
        }

        $pauseEnd = $this->pauseEnd();

        if ($now < $pauseEnd) {
            $this->quietUntil = $pauseEnd;

            return false;
        }

        $stream = @\stream_socket_client("unix://{$this->socket}", $errorCode, $errorText, self::CONNECT_SECONDS);

        if ($stream === false) {
            $this->fail();

            return false;
        }

        // PHP ignores the stream timeout for a blocking write. So the socket does not block. write()
        // waits for room in the socket until the deadline of the line.
        \stream_set_blocking($stream, false);
        $this->stream = $stream;

        return true;
    }

    public function send(string $line): void
    {
        if (!$this->connect()) {
            return;
        }

        if ($this->write("{$line}\n")) {
            return;
        }

        $this->fail();
    }

    // The files of the folder are shared by all PHP processes of Nexus.
    public function touch(string $name): void
    {
        if ($this->folder === '') {
            return;
        }

        if (!\is_dir($this->folder)) {
            @\mkdir($this->folder, 0700, true);
        }

        @\touch("{$this->folder}/{$name}");
    }

    public function touchedWithin(string $name, int $seconds): bool
    {
        $touchedAt = $this->touchedAt($name);

        if ($touchedAt === null) {
            return false;
        }

        return \time() - $touchedAt < $seconds;
    }

    // The pause of all PHP processes ends 10 seconds after the time of the pause file.
    private function pauseEnd(): float
    {
        $pausedAt = $this->touchedAt(self::PAUSE_FILE);

        return $pausedAt === null ? 0.0 : (float) ($pausedAt + self::PAUSE_SECONDS);
    }

    private function touchedAt(string $name): ?int
    {
        if ($this->folder === '') {
            return null;
        }

        $file = "{$this->folder}/{$name}";

        \clearstatcache(true, $file);
        $touchedAt = @\filemtime($file);

        return $touchedAt === false ? null : $touchedAt;
    }

    private function write(string $data): bool
    {
        $deadline = \microtime(true) + self::WRITE_SECONDS;

        while (true) {
            $written = @\fwrite($this->stream, $data);

            if ($written === false) {
                return false;
            }

            if ($written === \strlen($data)) {
                return true;
            }

            // Only a line that does not fit in the socket at once needs a copy of its rest.
            if ($written > 0) {
                $data = \substr($data, $written);
            }

            $left = $deadline - \microtime(true);

            if ($left <= 0) {
                return false;
            }

            $read = null;
            $write = [$this->stream];
            $except = null;

            if (!@\stream_select($read, $write, $except, 0, (int) \ceil($left * 1_000_000))) {
                return false;
            }
        }
    }

    // A line that nexusd got only in part is lost. nexusd drops the cut line when the connection
    // closes.
    private function fail(): void
    {
        if ($this->stream !== null) {
            @\fclose($this->stream);
            $this->stream = null;
        }

        $this->quietUntil = \microtime(true) + self::PAUSE_SECONDS;
        $this->touch(self::PAUSE_FILE);
    }
}
