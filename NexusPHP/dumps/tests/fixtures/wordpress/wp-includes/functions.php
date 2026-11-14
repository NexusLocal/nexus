<?php

declare(strict_types=1);

function _doing_it_wrong(string $function_name, string $message): void
{
    trigger_error("Function {$function_name} was called incorrectly. {$message}", E_USER_NOTICE);
}

function wp_doing_cron(): bool
{
    return defined('DOING_CRON') && DOING_CRON;
}
