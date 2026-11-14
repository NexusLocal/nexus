<?php

declare(strict_types=1);

require __DIR__.'/wp-config.php';

shop_page('queries');

echo 'STATE:', json_encode([
    'saveQueries' => SAVEQUERIES,
    'queries' => count($wpdb->queries),
]), "\n";
