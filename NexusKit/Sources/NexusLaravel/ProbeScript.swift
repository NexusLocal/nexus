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
}
