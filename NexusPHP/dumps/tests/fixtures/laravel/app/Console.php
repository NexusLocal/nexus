<?php

declare(strict_types=1);

namespace App;

use Illuminate\Database\Connection;
use Illuminate\Foundation\Application;
use Illuminate\Log\LogManager;
use Illuminate\Queue\Jobs\Job;
use Illuminate\Queue\Jobs\RedisJob;
use Illuminate\Queue\Worker;

// The commands of the fake artisan.
final class Console
{
    public static function run(Application $app, string $command, ?string $option): int
    {
        return match ($command) {
            'queue:work' => self::work($app, $option === '--once'),
            'orders:import' => self::import($app),
            'test' => self::test($app),
            default => 0,
        };
    }

    private static function work(Application $app, bool $once): int
    {
        $mysql = $app->make('db')['mysql'];
        $log = $app->make('log');
        $worker = new Worker($app->make('events'), $log);

        $mysql->select('select * from `jobs` limit 1');

        if ($once) {
            $worker->runNextJob(self::stockJob());

            return 0;
        }

        $worker->daemon([self::mailJob($mysql, $log), self::cardJob(), self::stockJob()]);
        $log->info('The worker stops.');

        return 0;
    }

    // A command of the site that runs one job of a queue itself.
    private static function import(Application $app): int
    {
        $mysql = $app->make('db')['mysql'];
        $log = $app->make('log');
        $worker = new Worker($app->make('events'), $log);

        $mysql->select('select * from `imports` where `id` = ?', [1]);
        $worker->runNextJob(self::mailJob($mysql, $log));
        $mysql->select('select * from `jobs` limit 1');
        $log->info('The import is done.');

        return 0;
    }

    private static function test(Application $app): int
    {
        $app->make('db')['mysql']->select('select 1');

        return 0;
    }

    private static function mailJob(Connection $mysql, LogManager $log): Job
    {
        return new RedisJob('App\Jobs\SendOrderMail', 'redis', 'default', 'uuid-mail', 1, 3, static function () use ($mysql, $log): void {
            $mysql->select('select * from `orders` where `id` = ?', [1042]);
            $log->info('The mail is sent.');
            dump(['mail' => 1042]);
        });
    }

    // The last attempt of a job that fails.
    private static function cardJob(): Job
    {
        return new RedisJob('App\Jobs\ChargeCard', 'redis', 'payments', 'uuid-card', 3, 3, static function (): void {
            throw new \RuntimeException('The card is declined.');
        });
    }

    // A job that fails and goes back on its queue for a later attempt.
    private static function stockJob(): Job
    {
        return new RedisJob('App\Jobs\SyncStock', 'redis', 'default', 'uuid-stock', 1, 3, static function (): void {
            throw new \RuntimeException('The stock service is down.');
        });
    }
}
