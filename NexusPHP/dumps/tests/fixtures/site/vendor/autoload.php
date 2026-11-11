<?php

declare(strict_types=1);

require_once __DIR__.'/fake/Composer/Autoload/ClassLoader.php';

spl_autoload_register(static function (string $class): void {
    $file = __DIR__.'/fake/'.str_replace('\\', '/', $class).'.php';

    if (is_file($file)) {
        require $file;
    }
});

require_once __DIR__.'/fake/dump.php';

return 'fake-loader';
