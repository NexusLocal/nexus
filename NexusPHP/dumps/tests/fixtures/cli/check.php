<?php

declare(strict_types=1);

echo 'CHECK:', json_encode([
    'dump' => function_exists('dump'),
    'userPrepend' => $GLOBALS['userPrependScope'] ?? 'missing',
]), "\n";
