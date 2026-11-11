<?php

declare(strict_types=1);

namespace Illuminate\Console\Events;

final class CommandFinished
{
    public function __construct(public int $exitCode)
    {
    }
}
