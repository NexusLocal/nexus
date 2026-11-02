// The PHP code of one pass of the configuration probe. It runs only the two bootstrappers that
// read .env and config/*.php (D43), so no service provider runs. Output of the application can
// come before the result, so the result starts with a separator.
enum ProbeScript {
    static let separator = "@@nexus-probe@@"

    static let source = #"""
    ini_set('display_errors', 'stderr');

    function nexus_flatten(array $items, string $prefix, array &$flat): void {
        foreach ($items as $key => $value) {
            $path = $prefix === '' ? (string) $key : "{$prefix}.{$key}";

            if (is_array($value)) {
                nexus_flatten($value, $path, $flat);
            } elseif (is_scalar($value) || $value === null) {
                $flat[$path] = $value;
            }
        }
    }

    try {
        require "{$argv[1]}/vendor/autoload.php";
        $app = require "{$argv[1]}/bootstrap/app.php";

        (new Illuminate\Foundation\Bootstrap\LoadEnvironmentVariables)->bootstrap($app);
        (new Illuminate\Foundation\Bootstrap\LoadConfiguration)->bootstrap($app);

        $flat = [];
        nexus_flatten($app['config']->all(), '', $flat);

        $redis = array_filter(
            $app['config']->get('database.redis', []),
            fn ($value, $name) => is_array($value) && ! in_array($name, ['options', 'clusters'], true),
            ARRAY_FILTER_USE_BOTH
        );

        $result = ['configuration' => [
            'version' => $app->version(),
            'settings' => (object) $flat,
            'databaseConnections' => array_map('strval', array_keys($app['config']->get('database.connections', []))),
            'redisConnections' => array_map('strval', array_keys($redis)),
        ]];
    } catch (Throwable $error) {
        $result = ['error' => get_class($error).': '.$error->getMessage().' in '.$error->getFile().':'.$error->getLine()];
    }

    echo "\n\#(separator)".json_encode($result, JSON_INVALID_UTF8_SUBSTITUTE | JSON_PARTIAL_OUTPUT_ON_ERROR);
    """#

    // Asks each connection of the application which server it reaches (D66). The names of a workspace
    // and of the main site are the same, so only the server shows a wrong port. This boots the whole
    // application, because a service provider can change a connection. A connection that fails gives
    // no port. A connection with read and write settings has a server for each, and only the write
    // server takes the data of the application.
    static let connectionSource = #"""
    ini_set('display_errors', 'stderr');

    try {
        require "{$argv[1]}/vendor/autoload.php";
        $app = require "{$argv[1]}/bootstrap/app.php";

        $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

        $ports = [];

        foreach (array_slice($argv, 2) as $name) {
            try {
                $connection = $app['db']->connection($name);
                $question = $connection->getDriverName() === 'pgsql' ? "select current_setting('port') as port" : 'select @@port as port';
                $ports[$name] = array_values(array_unique([
                    (int) $connection->selectOne($question, [], false)->port,
                    (int) $connection->selectOne($question)->port,
                ]));
            } catch (Throwable $error) {
            }
        }

        $result = ['ports' => (object) $ports];
    } catch (Throwable $error) {
        $result = ['error' => get_class($error).': '.$error->getMessage().' in '.$error->getFile().':'.$error->getLine()];
    }

    echo "\n\#(separator)".json_encode($result, JSON_INVALID_UTF8_SUBSTITUTE | JSON_PARTIAL_OUTPUT_ON_ERROR);
    """#
}
