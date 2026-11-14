<?php

declare(strict_types=1);

namespace Illuminate\Foundation\Bootstrap;

final class BootProviders
{
    public function bootstrap(object $app): void
    {
        $app->booted = true;
    }
}
