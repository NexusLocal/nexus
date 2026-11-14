<?php

declare(strict_types=1);

define('DOING_CRON', true);

require __DIR__.'/wp-load.php';

// The events that are due, as WordPress keeps them in its cron option.
$events = [
    ['hook' => 'shop_cleanup', 'schedule' => 'hourly', 'args' => []],
    ['hook' => 'action_scheduler_run_queue', 'schedule' => false, 'args' => ['WP Cron']],
];

foreach ($events as $event) {
    if ($event['schedule'] !== false) {
        wp_reschedule_event(1700000000, $event['schedule'], $event['hook'], $event['args']);
    }

    wp_unschedule_event(1700000000, $event['hook'], $event['args']);
    do_action_ref_array($event['hook'], $event['args']);
}

echo "CRON END\n";
