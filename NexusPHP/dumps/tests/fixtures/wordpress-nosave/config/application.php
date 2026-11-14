<?php

declare(strict_types=1);

// As Config of roots/wp-config in Bedrock: apply() stops the site with an exception when a
// constant already exists with another value.
final class Config
{
    private static array $values = [];

    public static function define(string $name, mixed $value): void
    {
        self::$values[$name] = $value;
    }

    public static function apply(): void
    {
        foreach (self::$values as $name => $value) {
            if (defined($name) && constant($name) !== $value) {
                throw new RuntimeException("Aborted trying to redefine constant '{$name}'.");
            }
        }

        foreach (self::$values as $name => $value) {
            if (!defined($name)) {
                define($name, $value);
            }
        }
    }
}

Config::define('DB_NAME', 'shop');
Config::define('SAVEQUERIES', false);
Config::apply();
