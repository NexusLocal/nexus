<?php

declare(strict_types=1);

// As Composer: the first require puts the loader in front of the other loaders. Each next require
// gives the same loader. BootProviders has a file of its own, as in Laravel.
if (!class_exists('FakeComposerLoader', false)) {
    final class FakeComposerLoader
    {
        public static function load(string $class): void
        {
            if ($class === 'Illuminate\Foundation\Bootstrap\BootProviders') {
                require __DIR__.'/fake/BootProviders.php';

                return;
            }

            if (str_starts_with($class, 'Illuminate\\')) {
                require_once __DIR__.'/fake/framework.php';

                return;
            }

            if (!str_starts_with($class, 'App\\')) {
                return;
            }

            $file = dirname(__DIR__).'/app/'.str_replace('\\', '/', substr($class, 4)).'.php';

            if (is_file($file)) {
                require $file;
            }
        }
    }

    spl_autoload_register([FakeComposerLoader::class, 'load'], true, true);
}

return 'fake-loader';
