<?php

declare(strict_types=1);

/*
 * The hooks for queries, log lines and jobs. prepend.php loads this file only when one of these
 * switches is on. A file that names $_SERVER makes PHP build that array for each request that
 * loads the file, also when no code here runs. The hooks only add callbacks. No class of Nexus
 * loads and no socket opens before the first event.
 */

namespace Nexus\Dumps;

function hook(): void
{
    $queries = catches('queries');
    $logs = catches('logs');
    $jobs = catches('jobs');

    if (isTestRun($_SERVER)) {
        return;
    }

    if ($logs) {
        catchErrors();
    }

    $laravel = laravelRoot();

    if ($laravel !== null) {
        hookLaravel($laravel);

        return;
    }

    if ($queries || $jobs) {
        hookWordPress($queries, $jobs);
    }
}

// Each event of a site comes in here. A failure never reaches the site. An event that Nexus itself
// causes is ignored. So a log line that Nexus causes while it handles a log line cannot loop.
function forward(string $class, string $method, mixed ...$arguments): void
{
    static $busy = false;

    if ($busy) {
        return;
    }

    $busy = true;

    try {
        library();
        ["Nexus\\Dumps\\{$class}", $method](...$arguments);
    } catch (\Throwable) {
        // Nexus must never break the page or the command.
    } finally {
        $busy = false;
    }
}

// PHP errors become log lines of the request. An error that @ silences or that error_reporting()
// leaves out is not caught. PHP then handles each error as before. Laravel replaces this handler
// with its own and sends its log lines as events.
function catchErrors(): void
{
    $previous = null;
    $previous = \set_error_handler(static function (int $level, string $message, string $file = '', int $line = 0) use (&$previous): bool {
        if ((\error_reporting() & $level) !== 0) {
            forward('PhpErrors', 'error', $level, $message, $file, $line);
        }

        if ($previous === null) {
            return false;
        }

        return $previous($level, $message, $file, $line) !== false;
    });

    // An error handler never sees a fatal error. PHP keeps it for the shutdown functions.
    \register_shutdown_function(static function (): void {
        $error = \error_get_last();

        if ($error === null) {
            return;
        }

        if (!\in_array($error['type'], [\E_ERROR, \E_PARSE, \E_CORE_ERROR, \E_COMPILE_ERROR], true)) {
            return;
        }

        // Laravel reports a fatal error itself. The listener of Nexus then sends that log line.
        if (laravelLogsActive()) {
            return;
        }

        // A request that ran out of memory needs a little more to send its error.
        if (\str_starts_with($error['message'], 'Allowed memory size')) {
            @\ini_set('memory_limit', (string) (\memory_get_usage() + 32 * 1024 * 1024));
        }

        forward('PhpErrors', 'fatal', $error);
    });
}

// A Laravel site has artisan and vendor/autoload.php in the same folder: the folder of the artisan
// script, the document root or the folder above the document root.
function laravelRoot(): ?string
{
    if (isCli()) {
        $script = (string) ($_SERVER['SCRIPT_FILENAME'] ?? '');

        if (\basename($script) !== 'artisan') {
            return null;
        }

        $folder = \dirname($script);

        return \is_file("{$folder}/vendor/autoload.php") ? $folder : null;
    }

    $documentRoot = \rtrim((string) ($_SERVER['DOCUMENT_ROOT'] ?? ''), '/');

    if ($documentRoot === '') {
        return null;
    }

    foreach ([$documentRoot, \dirname($documentRoot)] as $folder) {
        if (\is_file("{$folder}/artisan")) {
            return \is_file("{$folder}/vendor/autoload.php") ? $folder : null;
        }
    }

    return null;
}

// Composer puts its own loader in front of every earlier loader. So Nexus loads Composer of the
// site first and puts its hook in front of it. A second require in index.php or artisan gives the
// same loader.
function hookLaravel(string $root): void
{
    try {
        require "{$root}/vendor/autoload.php";
    } catch (\Throwable) {
        return;
    }

    $hook = static function (string $class) use (&$hook): void {
        if ($class !== 'Illuminate\Foundation\Bootstrap\BootProviders') {
            return;
        }

        \spl_autoload_unregister($hook);
        listenToLaravel();

        // PHP skips the next loader when a loader removes itself during its call. So the hook
        // gives the class to the other loaders itself. Composer of the site then loads it.
        foreach (\spl_autoload_functions() as $loader) {
            if (\class_exists($class, false)) {
                return;
            }

            $loader($class);
        }
    };

    \spl_autoload_register($hook, true, true);
}

// Laravel loads BootProviders after it registered its providers. So the events dispatcher exists.
// Container::getInstance() makes a new container when there is none. So Nexus reads the instance
// that the application made. This function repeats the read of Laravel::app() because no class of
// Nexus may load before the first event.
function listenToLaravel(): void
{
    $container = 'Illuminate\Container\Container';
    $listeners = [
        'Illuminate\Database\Events\QueryExecuted' => ['queries', 'query'],
        'Illuminate\Log\Events\MessageLogged' => ['logs', 'log'],
        'Illuminate\Queue\Events\JobQueued' => ['jobs', 'queued'],
        'Illuminate\Queue\Events\JobProcessing' => ['jobs', 'processing'],
        'Illuminate\Queue\Events\JobProcessed' => ['jobs', 'processed'],
        'Illuminate\Queue\Events\JobFailed' => ['jobs', 'failed'],
        'Illuminate\Queue\Events\JobReleasedAfterException' => ['jobs', 'released'],
    ];

    try {
        if (!\class_exists($container, false)) {
            return;
        }

        $app = \Closure::bind(static fn (): mixed => $container::$instance, null, $container)();

        if (!\is_object($app) || !\method_exists($app, 'bound') || !$app->bound('events')) {
            return;
        }

        $events = $app->make('events');

        foreach ($listeners as $event => [$switch, $method]) {
            if (catches($switch)) {
                $events->listen($event, static function (object $payload) use ($method): void {
                    forward('LaravelEvents', $method, $payload);
                });
            }
        }

        if (catches('logs')) {
            laravelLogsActive(true);
        }

        // A worker loops every few seconds. Only a job that is still open needs the loop.
        if (catches('jobs') && isCli()) {
            $events->listen('Illuminate\Queue\Events\Looping', static function (): void {
                if (\class_exists(Catcher::class, false)) {
                    forward('LaravelEvents', 'looping');
                }
            });
        }
    } catch (\Throwable) {
        // A site without the expected container or dispatcher gets no hooks.
    }
}

// True after Nexus added its listener for the log lines of Laravel. A fatal error before that
// moment gets the log line of Nexus.
function laravelLogsActive(?bool $active = null): bool
{
    static $isActive = false;

    if ($active !== null) {
        $isActive = $active;
    }

    return $isActive;
}

// WordPress turns a global $wp_filter array into its hooks when it loads (WordPress 4.7 and later).
// WP-CLI adds its early hooks in the same way. So no file of the site changes.
function hookWordPress(bool $queries, bool $jobs): void
{
    $cli = isCli();
    $folder = wordPressFolder($cli);

    if ($folder === null) {
        return;
    }

    $config = wordPressConfig($folder);

    if ($config === null && !$cli) {
        return;
    }

    try {
        if ($queries) {
            hookWordPressQueries($config);
        }

        if ($jobs) {
            hookWordPressJobs();
        }
    } catch (\Throwable) {
        // A site that changed $wp_filter in its own prepend file gets no hooks.
    }
}

// The folder where WordPress looks for wp-config.php. A command is WordPress only for WP-CLI and
// for wp-cron.php that a system crontab starts.
function wordPressFolder(bool $cli): ?string
{
    if (!$cli) {
        return (string) ($_SERVER['DOCUMENT_ROOT'] ?? '');
    }

    $script = (string) ($_SERVER['SCRIPT_FILENAME'] ?? '');

    if (\basename($script) === 'wp-cron.php') {
        return \dirname($script);
    }

    return isWpCli() ? (string) \getcwd() : null;
}

function isWpCli(): bool
{
    $script = \basename((string) ($_SERVER['SCRIPT_FILENAME'] ?? ''));

    return $script === 'wp' || \str_ends_with($script, 'wp-cli.phar');
}

// WordPress finds wp-config.php in its own folder or in the folder above it.
function wordPressConfig(string $folder): ?string
{
    $folder = \rtrim($folder, '/');

    if ($folder === '') {
        return null;
    }

    foreach ([$folder, \dirname($folder)] as $candidate) {
        if (\is_file("{$candidate}/wp-config.php")) {
            return "{$candidate}/wp-config.php";
        }
    }

    return null;
}

function hookWordPressQueries(?string $config): void
{
    $definedByNexus = false;

    // wpdb adds each query to $wpdb->queries after this filter. With the SAVEQUERIES of Nexus that
    // list would grow for the life of the process. So the list keeps only the last query. A
    // SAVEQUERIES of the site keeps its full list.
    addWordPressHook('log_query_custom_data', \PHP_INT_MAX, 5, static function (mixed $data, mixed $query = null, mixed $seconds = null, mixed $callstack = null, mixed $start = null) use (&$definedByNexus): mixed {
        forward('WordPress', 'query', $query, $seconds, $start);

        if ($definedByNexus) {
            forgetSavedQueries();
        }

        return $data;
    });

    // WordPress measures a query only with SAVEQUERIES. wpdb applies the filter "query" before it
    // reads SAVEQUERIES. wp-config.php and the config files of Bedrock define their constants before
    // the first query. So the first query is the moment to define SAVEQUERIES. A define before
    // that moment can break a site that defines it later. Then the filter removes itself. So each
    // later query takes the fast path of WordPress without a filter.
    $filter = static function (mixed $query) use ($config, &$filter, &$definedByNexus): mixed {
        if (\function_exists('remove_filter')) {
            \remove_filter('query', $filter, \PHP_INT_MIN);
        }

        if (!\defined('SAVEQUERIES')) {
            \define('SAVEQUERIES', true);
            $definedByNexus = true;

            return $query;
        }

        if (!\constant('SAVEQUERIES')) {
            forward('WordPress', 'withoutSaveQueries', $config);
        }

        return $query;
    };

    addWordPressHook('query', \PHP_INT_MIN, 1, $filter);
}

// Only the global wpdb. Another wpdb object of a plugin keeps its list.
function forgetSavedQueries(): void
{
    $wpdb = $GLOBALS['wpdb'] ?? null;

    if (\is_object($wpdb) && \is_array($wpdb->queries ?? null)) {
        $wpdb->queries = [];
    }
}

function hookWordPressJobs(): void
{
    addWordPressHook('schedule_event', \PHP_INT_MAX, 1, static function (mixed $event): mixed {
        forward('WordPress', 'scheduled', $event);

        return $event;
    });

    // WP-Cron and WP-CLI take an event off the schedule just before they run its hook. A repeating
    // event gets its next run first.
    addWordPressHook('pre_reschedule_event', \PHP_INT_MAX, 2, static function (mixed $pre, mixed $event = null): mixed {
        if (isCronRun() && \is_object($event)) {
            forward('WordPress', 'cronRescheduled', $event->hook ?? null);
        }

        return $pre;
    });

    addWordPressHook('pre_unschedule_event', \PHP_INT_MAX, 3, static function (mixed $pre, mixed $timestamp = null, mixed $hook = null): mixed {
        if (isCronRun()) {
            forward('WordPress', 'watchCron', $hook);
        }

        return $pre;
    });

    addWordPressHook('action_scheduler_begin_execute', \PHP_INT_MIN, 1, static function (mixed $id = null): void {
        forward('WordPress', 'actionStart', $id);
    });

    addWordPressHook('action_scheduler_after_execute', \PHP_INT_MAX, 1, static function (mixed $id = null): void {
        forward('WordPress', 'actionEnd', $id, 'done');
    });

    addWordPressHook('action_scheduler_failed_execution', \PHP_INT_MAX, 1, static function (mixed $id = null): void {
        forward('WordPress', 'actionEnd', $id, 'failed');
    });

    addWordPressHook('action_scheduler_stored_action', \PHP_INT_MAX, 1, static function (mixed $id = null): void {
        forward('WordPress', 'actionQueued', $id);
    });
}

function isCronRun(): bool
{
    if (\function_exists('wp_doing_cron') && \wp_doing_cron()) {
        return true;
    }

    return \defined('WP_CLI') && \constant('WP_CLI');
}

// The format that WP_Hook::build_preinitialized_hooks() reads.
function addWordPressHook(string $hook, int $priority, int $arguments, \Closure $callback): void
{
    $GLOBALS['wp_filter'][$hook][$priority][] = ['function' => $callback, 'accepted_args' => $arguments];
}
