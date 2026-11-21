<?php

declare(strict_types=1);

namespace Nexus\Dumps;

/*
 * The filters of WooCommerce for a request of a public link (group 4, 4c). nginx or Apache gives
 * the request NEXUS_SHARE_HOST. The payment provider then gets the public URL for its return and
 * its webhook. The rest of WordPress keeps its local host (decision 2).
 */
final class PublicLink
{
    public const FILTERS = [
        'woocommerce_get_return_url',
        'woocommerce_get_checkout_order_received_url',
        'woocommerce_get_cancel_order_url',
        'woocommerce_get_cancel_order_url_raw',
        'woocommerce_get_checkout_payment_url',
        'woocommerce_api_request_url',
    ];

    // WordPress turns a global $wp_filter array into its hooks when it loads, as for the hooks of
    // hooks.php. A site that changed $wp_filter in its own prepend file gets no filters.
    public static function add(string $publicHost): void
    {
        if (wordPressConfig((string) ($_SERVER['DOCUMENT_ROOT'] ?? '')) === null) {
            return;
        }

        $callback = static function (mixed $url) use ($publicHost): mixed {
            $home = \function_exists('get_option') ? \get_option('home') : null;

            return \is_string($home) ? self::publicUrl($url, $home, $publicHost) : $url;
        };

        try {
            foreach (self::FILTERS as $filter) {
                $GLOBALS['wp_filter'][$filter][\PHP_INT_MAX][] = ['function' => $callback, 'accepted_args' => 1];
            }
        } catch (\Throwable) {
            return;
        }
    }

    // Only a URL on the home of WordPress changes, with or without a port. Each other value stays.
    public static function publicUrl(mixed $url, string $home, string $publicHost): mixed
    {
        if (!\is_string($url)) {
            return $url;
        }

        $scheme = \parse_url($home, \PHP_URL_SCHEME);
        $host = \parse_url($home, \PHP_URL_HOST);

        if (!\is_string($scheme) || !\is_string($host)) {
            return $url;
        }

        $pattern = '#^'.\preg_quote("{$scheme}://{$host}", '#').'(?::\d+)?(?=[/?\#]|$)#i';

        if (\preg_match($pattern, $url, $match) !== 1) {
            return $url;
        }

        return "https://{$publicHost}".\substr($url, \strlen($match[0]));
    }
}
