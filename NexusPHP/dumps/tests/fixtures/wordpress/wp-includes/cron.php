<?php

declare(strict_types=1);

// The filters of the cron functions of WordPress 5.7 and later.

function wp_schedule_event(int $timestamp, string $recurrence, string $hook, array $args = []): bool
{
    $event = (object) ['hook' => $hook, 'timestamp' => $timestamp, 'schedule' => $recurrence, 'args' => $args, 'interval' => 3600];
    $event = apply_filters('schedule_event', $event);

    if (!$event) {
        return false;
    }

    $GLOBALS['scheduled'][] = $event->hook;

    return true;
}

// As in WordPress: the next run of a repeating event goes through wp_schedule_event().
function wp_reschedule_event(int $timestamp, string $recurrence, string $hook, array $args = []): bool
{
    $event = (object) ['hook' => $hook, 'timestamp' => $timestamp, 'schedule' => $recurrence, 'args' => $args, 'interval' => 3600];
    $pre = apply_filters('pre_reschedule_event', null, $event, false);

    if ($pre !== null) {
        return (bool) $pre;
    }

    return wp_schedule_event($timestamp + 3600, $recurrence, $hook, $args);
}

function wp_unschedule_event(int $timestamp, string $hook, array $args = []): bool
{
    return apply_filters('pre_unschedule_event', null, $timestamp, $hook, $args, false) === null;
}
