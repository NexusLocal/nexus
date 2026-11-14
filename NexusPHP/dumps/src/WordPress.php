<?php

declare(strict_types=1);

namespace Nexus\Dumps;

/*
 * The callbacks for the hooks of WordPress, WP-Cron and Action Scheduler. The prepend file adds
 * them to $wp_filter before WordPress loads.
 */
final class WordPress
{
    // WordPress has one database object. Its name stands in the place of a connection name.
    private const CONNECTION = 'wpdb';

    /** @var array<string, true> */
    private static array $cronHooks = [];

    // WP-Cron gives a repeating event its next run through wp_schedule_event(). That is no event
    // that the request scheduled. So its row is left out.
    private static ?string $rescheduled = null;

    public static function query(mixed $sql, mixed $seconds, mixed $start): void
    {
        Catcher::instance()->entry('query', static fn (): array => [
            'time' => \is_float($start) ? $start : null,
            'label' => self::CONNECTION,
            'text' => \is_string($sql) ? $sql : '',
            'ms' => \is_numeric($seconds) ? \round((float) $seconds * 1000, 3) : null,
        ]);
    }

    // WP-CLI can run without a wp-config.php that Nexus found. The note then has no file.
    public static function withoutSaveQueries(?string $config): void
    {
        Catcher::instance()->block('savequeries', $config === null ? null : (\realpath($config) ?: $config));
    }

    public static function scheduled(mixed $event): void
    {
        if (!\is_object($event)) {
            return;
        }

        $hook = $event->hook ?? null;

        if (!\is_string($hook) || $hook === '') {
            return;
        }

        if ($hook === self::$rescheduled) {
            self::$rescheduled = null;

            return;
        }

        $schedule = $event->schedule ?? null;

        Catcher::instance()->entry('job', static fn (): array => [
            'label' => 'scheduled',
            'text' => $hook,
            'detail' => \is_string($schedule) && $schedule !== '' ? $schedule : null,
        ]);
    }

    public static function cronRescheduled(mixed $hook): void
    {
        self::watchCron($hook);
        self::$rescheduled = \is_string($hook) ? $hook : null;
    }

    // WP-Cron runs the hook of an event with do_action() right after it took the event off the
    // schedule. The first and the last callback of the hook start and end its job.
    public static function watchCron(mixed $hook): void
    {
        self::$rescheduled = null;

        if (!\is_string($hook) || $hook === '') {
            return;
        }

        if (isset(self::$cronHooks[$hook])) {
            return;
        }

        if (!\function_exists('add_action')) {
            return;
        }

        self::$cronHooks[$hook] = true;

        \add_action($hook, static function () use ($hook): void {
            forward('WordPress', 'cronStart', $hook);
        }, \PHP_INT_MIN, 0);

        \add_action($hook, static function () use ($hook): void {
            forward('WordPress', 'cronEnd', $hook);
        }, \PHP_INT_MAX, 0);
    }

    public static function cronStart(string $hook): void
    {
        Catcher::instance()->startJob(['system' => 'cron', 'name' => $hook], "cron {$hook}");
    }

    public static function cronEnd(string $hook): void
    {
        Catcher::instance()->endJob("cron {$hook}", 'done');
    }

    public static function actionStart(mixed $id): void
    {
        if (!\is_int($id) && !\is_string($id)) {
            return;
        }

        [$hook, $group] = self::action($id);

        Catcher::instance()->startJob([
            'system' => 'action',
            'name' => $hook,
            'queue' => $group,
            'uuid' => (string) $id,
        ], "action {$id}");
    }

    public static function actionEnd(mixed $id, string $outcome): void
    {
        if (!\is_int($id) && !\is_string($id)) {
            return;
        }

        Catcher::instance()->endJob("action {$id}", $outcome);
    }

    public static function actionQueued(mixed $id): void
    {
        if (!\is_int($id) && !\is_string($id)) {
            return;
        }

        Catcher::instance()->entry('job', static function () use ($id): array {
            [$hook, $group] = self::action($id);

            return [
                'label' => 'queued',
                'text' => $hook,
                'detail' => $group,
                'ref' => (string) $id,
            ];
        });
    }

    // Action Scheduler gives only the id. Its store reads the action with a query. That query
    // runs inside Nexus. So Nexus does not catch it.
    /** @return array{0: string, 1: ?string} */
    private static function action(int|string $id): array
    {
        $fallback = ["action {$id}", null];

        if (!\class_exists('ActionScheduler', false)) {
            return $fallback;
        }

        try {
            $action = \ActionScheduler::store()->fetch_action($id);
            $hook = $action->get_hook();
            $group = $action->get_group();
        } catch (\Throwable) {
            return $fallback;
        }

        if (!\is_string($hook) || $hook === '') {
            return $fallback;
        }

        return [$hook, \is_string($group) && $group !== '' ? $group : null];
    }
}
