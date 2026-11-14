<?php

declare(strict_types=1);

namespace Nexus\Dumps;

/*
 * The PHP errors of a site as log lines. WordPress and plain PHP have no logger. So the error
 * handler of the prepend file and the fatal error at the shutdown come here.
 */
final class PhpErrors
{
    // The level of the log line and the detail for each kind of error that a handler can see.
    private const KINDS = [
        \E_WARNING => ['warning', 'PHP warning'],
        \E_USER_WARNING => ['warning', 'PHP warning'],
        \E_CORE_WARNING => ['warning', 'PHP warning'],
        \E_COMPILE_WARNING => ['warning', 'PHP warning'],
        \E_NOTICE => ['notice', 'PHP notice'],
        \E_USER_NOTICE => ['notice', 'PHP notice'],
        \E_DEPRECATED => ['deprecated', 'PHP deprecated'],
        \E_USER_DEPRECATED => ['deprecated', 'PHP deprecated'],
        \E_USER_ERROR => ['error', 'PHP error'],
        \E_RECOVERABLE_ERROR => ['error', 'PHP error'],
    ];

    public static function error(int $level, string $message, string $file, int $line): void
    {
        $kind = self::KINDS[$level] ?? null;

        if ($kind === null) {
            return;
        }

        Catcher::instance()->entry('log', static fn (): array => [
            ...Source::ofError($file, $line),
            'label' => $kind[0],
            'text' => $message,
            'detail' => $kind[1],
        ]);
    }

    // At the shutdown the trace no longer leads to the code of the site. So the file of the error
    // stays, also in a vendor folder.
    /** @param array{type: int, message: string, file: string, line: int} $error */
    public static function fatal(array $error): void
    {
        $catcher = Catcher::instance();
        $catcher->noteFatal();

        $catcher->entry('log', static fn (): array => [
            ...Source::at($error['file'], $error['line']),
            'label' => 'error',
            'text' => $error['message'],
            'detail' => 'PHP fatal error',
        ]);
    }
}
