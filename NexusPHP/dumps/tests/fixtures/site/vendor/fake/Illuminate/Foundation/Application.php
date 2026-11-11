<?php

declare(strict_types=1);

namespace Illuminate\Foundation;

use Illuminate\Container\Container;

final class Application extends Container
{
    public function __construct(private string $basePath)
    {
        static::setInstance($this);
    }

    public function basePath(string $path = ''): string
    {
        return $this->basePath;
    }
}
