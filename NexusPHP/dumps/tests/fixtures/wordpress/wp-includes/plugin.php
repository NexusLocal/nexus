<?php

declare(strict_types=1);

// The hooks of WordPress 4.7 and later, as far as Nexus uses them.

final class WP_Hook
{
    public array $callbacks = [];

    public function add_filter(string $hook_name, callable $callback, int $priority, int $accepted_args): void
    {
        $this->callbacks[$priority][] = ['function' => $callback, 'accepted_args' => $accepted_args];
        ksort($this->callbacks, SORT_NUMERIC);
    }

    public function remove_filter(string $hook_name, callable $callback, int $priority): bool
    {
        foreach ($this->callbacks[$priority] ?? [] as $index => $registered) {
            if ($registered['function'] === $callback) {
                unset($this->callbacks[$priority][$index]);

                if ($this->callbacks[$priority] === []) {
                    unset($this->callbacks[$priority]);
                }

                return true;
            }
        }

        return false;
    }

    public function apply_filters(mixed $value, array $args): mixed
    {
        foreach ($this->callbacks as $callbacks) {
            foreach ($callbacks as $callback) {
                $args[0] = $value;
                $value = $callback['function'](...array_slice($args, 0, $callback['accepted_args']));
            }
        }

        return $value;
    }

    public function do_action(array $args): void
    {
        foreach ($this->callbacks as $callbacks) {
            foreach ($callbacks as $callback) {
                $callback['function'](...array_slice($args, 0, $callback['accepted_args']));
            }
        }
    }

    public static function build_preinitialized_hooks(array $filters): array
    {
        $normalized = [];

        foreach ($filters as $hook_name => $callback_groups) {
            if ($callback_groups instanceof WP_Hook) {
                $normalized[$hook_name] = $callback_groups;

                continue;
            }

            $hook = new WP_Hook();

            foreach ($callback_groups as $priority => $callbacks) {
                foreach ($callbacks as $cb) {
                    $hook->add_filter($hook_name, $cb['function'], $priority, $cb['accepted_args']);
                }
            }

            $normalized[$hook_name] = $hook;
        }

        return $normalized;
    }
}

function add_filter(string $hook_name, callable $callback, int $priority = 10, int $accepted_args = 1): bool
{
    global $wp_filter;

    $wp_filter[$hook_name] ??= new WP_Hook();
    $wp_filter[$hook_name]->add_filter($hook_name, $callback, $priority, $accepted_args);

    return true;
}

function add_action(string $hook_name, callable $callback, int $priority = 10, int $accepted_args = 1): bool
{
    return add_filter($hook_name, $callback, $priority, $accepted_args);
}

// As in WordPress: a hook without callbacks goes away. So apply_filters() takes its fast path.
function remove_filter(string $hook_name, callable $callback, int $priority = 10): bool
{
    global $wp_filter;

    if (!isset($wp_filter[$hook_name])) {
        return false;
    }

    $removed = $wp_filter[$hook_name]->remove_filter($hook_name, $callback, $priority);

    if ($wp_filter[$hook_name]->callbacks === []) {
        unset($wp_filter[$hook_name]);
    }

    return $removed;
}

function apply_filters(string $hook_name, mixed $value, mixed ...$args): mixed
{
    global $wp_filter;

    if (!isset($wp_filter[$hook_name])) {
        return $value;
    }

    return $wp_filter[$hook_name]->apply_filters($value, [$value, ...$args]);
}

function do_action(string $hook_name, mixed ...$args): void
{
    global $wp_filter;

    if (isset($wp_filter[$hook_name])) {
        $wp_filter[$hook_name]->do_action($args);
    }
}

function do_action_ref_array(string $hook_name, array $args): void
{
    do_action($hook_name, ...$args);
}

function has_filter(string $hook_name): bool
{
    global $wp_filter;

    return isset($wp_filter[$hook_name]);
}

if ($wp_filter ?? null) {
    $wp_filter = WP_Hook::build_preinitialized_hooks($wp_filter);
} else {
    $wp_filter = [];
}
