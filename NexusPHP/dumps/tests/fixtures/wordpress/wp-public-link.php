<?php

declare(strict_types=1);

require __DIR__.'/wp-load.php';

$url = 'https://www.shop.test:30443/checkout/order-received/7/?key=a';
$filters = [
    'woocommerce_get_return_url',
    'woocommerce_get_checkout_order_received_url',
    'woocommerce_get_cancel_order_url',
    'woocommerce_get_cancel_order_url_raw',
    'woocommerce_get_checkout_payment_url',
    'woocommerce_api_request_url',
];

echo 'STATE:', json_encode([
    'filters' => array_combine($filters, array_map(static fn (string $filter): mixed => apply_filters($filter, $url), $filters)),
    'dump' => function_exists('dump'),
], JSON_UNESCAPED_SLASHES), "\n";
