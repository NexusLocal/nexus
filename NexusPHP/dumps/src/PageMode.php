<?php

declare(strict_types=1);

namespace Nexus\Dumps;

/*
 * The setting "Show dumps in the page". Automatic shows a dump only in a page that the browser
 * asked for. So an API, Livewire, Inertia, htmx or Turbo response stays valid (owner answer 4).
 */
final class PageMode
{
    public const AUTOMATIC = 'automatic';
    public const ALWAYS = 'always';
    public const NEVER = 'never';

    private const NOT_A_PAGE_HEADERS = ['HTTP_X_LIVEWIRE', 'HTTP_X_INERTIA', 'HTTP_HX_REQUEST', 'HTTP_TURBO_FRAME'];

    private const PAGE_DESTINATIONS = ['document', 'iframe', 'frame'];

    // A command always prints (owner answer 1). dd() always shows, because it ends the request.
    public static function showsInPage(string $mode, array $server, bool $isDd, bool $cli): bool
    {
        if ($cli) {
            return true;
        }

        if ($isDd) {
            return true;
        }

        return match ($mode) {
            self::ALWAYS => true,
            self::NEVER => false,
            default => self::isPage($server),
        };
    }

    // A browser says with Sec-Fetch-Dest what it does with the response. The other headers are a
    // guess for a client without it.
    public static function isPage(array $server): bool
    {
        if (self::isPageDestination($server)) {
            return true;
        }

        if (isset($server['HTTP_SEC_FETCH_DEST'])) {
            return self::replacesThePage($server);
        }

        $accept = \strtolower((string) ($server['HTTP_ACCEPT'] ?? ''));

        if (!\str_contains($accept, 'text/html')) {
            return false;
        }

        if (\str_contains($accept, 'text/vnd.turbo-stream.html')) {
            return false;
        }

        if (\str_contains($accept, 'json')) {
            return false;
        }

        $contentType = \strtolower((string) ($server['CONTENT_TYPE'] ?? $server['HTTP_CONTENT_TYPE'] ?? ''));

        if (\str_contains($contentType, 'json')) {
            return false;
        }

        if (\strtolower((string) ($server['HTTP_X_REQUESTED_WITH'] ?? '')) === 'xmlhttprequest') {
            return false;
        }

        if (self::replacesThePage($server)) {
            return true;
        }

        foreach (self::NOT_A_PAGE_HEADERS as $header) {
            if (isset($server[$header])) {
                return false;
            }
        }

        return true;
    }

    private static function isPageDestination(array $server): bool
    {
        $destination = \strtolower((string) ($server['HTTP_SEC_FETCH_DEST'] ?? ''));

        return \in_array($destination, self::PAGE_DESTINATIONS, true);
    }

    // Turbo Drive, a boosted htmx link and wire:navigate of Livewire load the next page with
    // fetch(). The response then replaces the whole page. So a dump in it shows as in a normal page.
    private static function replacesThePage(array $server): bool
    {
        if (\strtolower((string) ($server['HTTP_HX_BOOSTED'] ?? '')) === 'true') {
            return true;
        }

        if (isset($server['HTTP_X_LIVEWIRE_NAVIGATE'])) {
            return true;
        }

        if (!isset($server['HTTP_X_TURBO_REQUEST_ID'])) {
            return false;
        }

        if (isset($server['HTTP_TURBO_FRAME'])) {
            return false;
        }

        return !\str_contains(\strtolower((string) ($server['HTTP_ACCEPT'] ?? '')), 'text/vnd.turbo-stream.html');
    }
}
