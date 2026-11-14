<?php

declare(strict_types=1);

require __DIR__.'/wp-load.php';

shop_page($_GET['action'] ?? 'none');

$nexusClasses = array_values(array_filter(
    get_declared_classes(),
    static fn (string $class): bool => str_starts_with($class, 'Nexus\\'),
));

echo 'STATE:', json_encode([
    'nexusClasses' => $nexusClasses,
    'saveQueries' => defined('SAVEQUERIES') ? SAVEQUERIES : null,
    'hooked' => has_filter('log_query_custom_data'),
    'queryFilter' => has_filter('query'),
    'queries' => count($wpdb->queries),
    'scheduled' => $GLOBALS['scheduled'] ?? [],
]), "\n";
