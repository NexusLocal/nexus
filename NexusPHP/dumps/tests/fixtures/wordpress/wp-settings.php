<?php

declare(strict_types=1);

define('WPINC', 'wp-includes');
define('WP_CONTENT_DIR', ABSPATH.'wp-content');

require ABSPATH.WPINC.'/plugin.php';
require ABSPATH.WPINC.'/functions.php';
require ABSPATH.WPINC.'/cron.php';
require ABSPATH.WPINC.'/class-wpdb.php';

$wpdb = new wpdb();

require ABSPATH.'wp-content/plugins/action-scheduler/action-scheduler.php';
require ABSPATH.'wp-content/plugins/shop/shop.php';

do_action('plugins_loaded');
do_action('wp_loaded');
