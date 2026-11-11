<?php

declare(strict_types=1);

use Illuminate\Container\Container;

require __DIR__.'/../site/vendor/autoload.php';

class_exists(Container::class);

dump('no container');

echo 'INSTANCE:', Container::hasInstance() ? 'made' : 'none', "\n";
