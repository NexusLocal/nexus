<?php

declare(strict_types=1);

// The handler of the prepend file of the user. Nexus puts its own handler in front and calls this
// one for each error.
set_error_handler(static function (int $level, string $message): bool {
    $GLOBALS['previousHandler'][] = $message;

    return false;
});
