<?php

declare(strict_types=1);

namespace Illuminate\Container;

class Container
{
    private static ?Container $instance = null;

    private array $instances = [];

    public static function getInstance(): static
    {
        return static::$instance ??= new static();
    }

    public static function setInstance(?Container $container): void
    {
        static::$instance = $container;
    }

    public static function hasInstance(): bool
    {
        return static::$instance !== null;
    }

    public function instance(string $name, mixed $value): void
    {
        $this->instances[$name] = $value;
    }

    public function bound(string $name): bool
    {
        return isset($this->instances[$name]);
    }

    public function make(string $name): mixed
    {
        return $this->instances[$name];
    }
}
