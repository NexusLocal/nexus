<?php

declare(strict_types=1);

$started = hrtime(true);

dump(array_fill(0, 2000, str_repeat('x', 50)));

echo 'ELAPSED:', (hrtime(true) - $started) / 1e9, "\n";
echo "SCRIPT END\n";
