<?php

declare(strict_types=1);

// A file in the root of WordPress, as wp-links-opml.php. A plugin includes it.
$GLOBALS['wpdb']->get_results('SELECT * FROM wp_links');
trigger_error('The export has no links.', E_USER_WARNING);
