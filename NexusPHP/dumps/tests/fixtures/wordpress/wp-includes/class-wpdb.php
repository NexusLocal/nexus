<?php

declare(strict_types=1);

// wpdb applies the filter "query" first. It then measures and keeps the query only with
// SAVEQUERIES. A fixed time keeps the tests stable.
class wpdb
{
    public array $queries = [];

    public function query(string $query): int
    {
        $query = apply_filters('query', $query);
        $start = microtime(true);

        if (defined('SAVEQUERIES') && SAVEQUERIES) {
            $this->log_query($query, 0.0021, 'shop_page', $start, []);
        }

        return 1;
    }

    public function get_results(string $query): array
    {
        $this->query($query);

        return [];
    }

    public function log_query(string $query, float $query_time, string $query_callstack, float $query_start, array $query_data): void
    {
        $query_data = apply_filters('log_query_custom_data', $query_data, $query, $query_time, $query_callstack, $query_start);
        $this->queries[] = [$query, $query_time, $query_callstack, $query_start, $query_data];
    }
}
