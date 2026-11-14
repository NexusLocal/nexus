<?php

declare(strict_types=1);

namespace App;

// The tree of a log context asks each object for its debug info. This object logs again at that
// moment, with itself in the context. Without a guard that would never end.
final class LogProbe
{
    public function __construct(private readonly object $log)
    {
    }

    public function __debugInfo(): array
    {
        $this->log->warning('inside', ['probe' => $this]);

        return ['probe' => true];
    }
}
