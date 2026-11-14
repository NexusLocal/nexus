<?php

declare(strict_types=1);

namespace App;

use Illuminate\Foundation\Application;
use Illuminate\Queue\Jobs\SyncJob;
use Illuminate\Queue\Queue;

// The code of the site. Each query, log line and job starts here, outside vendor/.
final class Actions
{
    public static function run(Application $app, string $action): void
    {
        match ($action) {
            'queries' => self::queries($app),
            'many' => self::many($app),
            'logs' => self::logs($app),
            'loop' => self::loop($app),
            'jobs' => self::jobs($app),
            'fatal' => self::fatal(),
            default => null,
        };
    }

    // The page shows no message. So the test sees only what Nexus sends.
    private static function fatal(): void
    {
        ini_set('display_errors', '0');
        nexus_function_that_does_not_exist();
    }

    private static function queries(Application $app): void
    {
        $db = $app->make('db');

        $db['mysql']->select('select * from `carts` where `user_id` = ? and `name` = ?', [7, "O'Hara"]);
        $db['legacy']->select("select * from `orders` where `note` = '?' and `id` = ? and `paid` = ?", [1042, true]);

        require dirname(__DIR__).'/storage/views/cart.php';
    }

    private static function many(Application $app): void
    {
        $mysql = $app->make('db')['mysql'];

        for ($number = 1; $number <= 520; ++$number) {
            $mysql->select('select * from `items` where `id` = ?', [$number]);
        }
    }

    private static function logs(Application $app): void
    {
        $log = $app->make('log');

        $log->error('Order 1042 has no invoice.', ['order' => 1042]);
        $log->channel('single')->warning('Low stock.');
    }

    private static function loop(Application $app): void
    {
        $log = $app->make('log');

        $log->error('outer', ['probe' => new LogProbe($log)]);
    }

    private static function jobs(Application $app): void
    {
        $queue = new Queue($app->make('events'));
        $mysql = $app->make('db')['mysql'];

        $queue->pushToRedis(new Jobs\SendOrderMail(), 'uuid-queued');
        $queue->pushToSync(new SyncJob('App\Jobs\Recalculate', 'sync', 'default', 'uuid-sync', 1, null, static function () use ($mysql): void {
            $mysql->select('select * from `totals`');
        }));

        try {
            $queue->pushToSync(new SyncJob('App\Jobs\Refund', 'sync', 'default', 'uuid-refund', 1, null, static function (): void {
                throw new \RuntimeException('The refund failed.');
            }));
        } catch (\RuntimeException) {
            // The page goes on, as a controller that catches the exception.
        }
    }
}
