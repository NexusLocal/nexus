<?php

declare(strict_types=1);

// A plugin of the site. Its code is outside wp-includes/ and wp-admin/.

function shop_page(string $action): void
{
    global $wpdb;

    if ($action === 'queries') {
        $wpdb->get_results("SELECT * FROM wp_posts WHERE post_status = 'publish'");
        $wpdb->get_results('SELECT * FROM wp_users');
    }

    if ($action === 'schedule') {
        wp_schedule_event(1700000000, 'hourly', 'shop_cleanup');
        as_enqueue_async_action('shop_send_mail', [], 'shop');
    }

    if ($action === 'wrong') {
        _doing_it_wrong('shop_page', 'Use shop_render instead.');
        @trigger_error('A silenced warning.', E_USER_WARNING);
    }

    if ($action === 'export') {
        require ABSPATH.'wp-shop-export.php';
    }

    if ($action === 'monitor') {
        require WP_CONTENT_DIR.'/plugins/query-monitor/db.php';
        $monitored = new QM_DB();
        $monitored->get_results('SELECT * FROM wp_options');
    }
}

add_action('shop_cleanup', static function (): void {
    $GLOBALS['wpdb']->query('DELETE FROM wp_shop_carts WHERE expired = 1');
});

add_action('shop_send_mail', static function (): void {
    $GLOBALS['wpdb']->query('SELECT * FROM wp_shop_mail');
});

add_action('shop_fail', static function (): void {
    throw new RuntimeException('The mail server is down.');
});
