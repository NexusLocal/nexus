<?php

declare(strict_types=1);

echo 'STATE:', json_encode([
    'wpFilter' => isset($GLOBALS['wp_filter']),
    'dump' => function_exists('dump'),
]), "\n";
