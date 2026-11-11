<?php

declare(strict_types=1);

namespace Nexus\Dumps;

use Nexus\Dumps\VarDumper\Caster\Caster;
use Nexus\Dumps\VarDumper\Cloner\Cursor;
use Nexus\Dumps\VarDumper\Dumper\AbstractDumper;

/*
 * Makes the tree of the wire format (Part 3 of docs/dump-viewer-build.md) from the cloned data of
 * VarDumper. It follows the rules of CliDumper. So the tree and the text show the same values.
 */
final class TreeDumper extends AbstractDumper
{
    // The estimated size of the JSON of a node without its key, value and class.
    private const NODE_BYTES = 40;

    private const HASH_KINDS = [Cursor::HASH_OBJECT => 'object', Cursor::HASH_RESOURCE => 'resource'];

    /** @var list<array<string, mixed>> */
    private array $open = [];

    private ?array $root = null;

    /** @var array<string, true> */
    private array $shown = [];

    private int $bytes = 0;

    private bool $tooLarge = false;

    // The tree writes no lines. So the output of AbstractDumper is a callable that does nothing.
    public function __construct(private readonly int $maxBytes)
    {
        parent::__construct(static function (): void {
        });
    }

    public function json(): ?string
    {
        if ($this->tooLarge) {
            return null;
        }

        if ($this->root === null) {
            return null;
        }

        $json = \json_encode($this->root, Catcher::JSON_FLAGS);

        if ($json === false) {
            return null;
        }

        return \strlen($json) > $this->maxBytes ? null : $json;
    }

    public function dumpScalar(Cursor $cursor, string $type, string|int|float|bool|null $value): void
    {
        // Data::dump() starts with the label of its context. Nexus sends the label on its own.
        if ($cursor->hashType === -1) {
            return;
        }

        [$kind, $text] = match ($type) {
            'NULL' => ['null', 'null'],
            'boolean' => ['bool', $value ? 'true' : 'false'],
            'integer' => ['int', (string) $value],
            'double' => ['float', self::float((float) $value)],
            'default', 'label' => ['label', $this->utf8Encode((string) $value)],
            default => ['label', $this->utf8Encode($type)],
        };

        $this->add($cursor, ['kind' => $kind, 'value' => $text]);
    }

    public function dumpString(Cursor $cursor, string $str, bool $bin, int $cut): void
    {
        $text = $bin ? $this->utf8Encode($str) : $str;
        $node = ['kind' => 'string', 'value' => $text];

        if ($cut !== 0) {
            $node['cut'] = $cut;
        }

        if ($cut > 0) {
            $node['length'] = \mb_strlen($text, 'UTF-8') + $cut;
        }

        $this->add($cursor, $node);
    }

    public function enterHash(Cursor $cursor, int $type, string|int|null $class, bool $hasChild): void
    {
        $node = $this->keyOf($cursor) + match (true) {
            self::isArray($type) => ['kind' => 'array', 'count' => (int) $class],
            default => [
                'kind' => self::HASH_KINDS[$type],
                'class' => $this->utf8Encode((string) $class),
            ] + $this->identity($cursor, $type, $hasChild),
        };

        $this->count($cursor, $node);
        $this->open[] = $node;
    }

    public function leaveHash(Cursor $cursor, int $type, string|int|null $class, bool $hasChild, int $cut): void
    {
        $node = \array_pop($this->open);

        if ($node === null) {
            return;
        }

        if ($cut !== 0) {
            $node['cut'] = $cut;
        }

        $count = self::itemCount($node, $type, $cut);

        if ($count !== null) {
            $node['count'] = $count;
        }

        $this->attach($node);
    }

    private static function isArray(int $type): bool
    {
        return !isset(self::HASH_KINDS[$type]);
    }

    // An array has its count from enterHash(). A cut of -1 means that the cloner left out an
    // unknown number of items.
    private static function itemCount(array $node, int $type, int $cut): ?int
    {
        if (self::isArray($type)) {
            return null;
        }

        if (isset($node['refersTo'])) {
            return null;
        }

        if ($cut < 0) {
            return null;
        }

        return \count($node['children'] ?? []) + $cut;
    }

    /** @return array<string, int> */
    private function identity(Cursor $cursor, int $type, bool $hasChild): array
    {
        $handle = $cursor->softRefHandle ?: $cursor->softRefTo;

        if ($handle <= 0) {
            return [];
        }

        $seen = "{$type}:{$handle}";

        if ($this->isShownBefore($cursor, $hasChild, $seen)) {
            return ['ref' => $handle, 'refersTo' => $handle];
        }

        $this->shown[$seen] = true;

        return ['ref' => $handle];
    }

    // Data::dump() gives the items of an object only the first time. Later places refer to it.
    private function isShownBefore(Cursor $cursor, bool $hasChild, string $seen): bool
    {
        if ($cursor->softRefCount === 0) {
            return false;
        }

        if ($hasChild) {
            return false;
        }

        return isset($this->shown[$seen]);
    }

    private function add(Cursor $cursor, array $node): void
    {
        $node = $this->keyOf($cursor) + $node;

        $this->count($cursor, $node);
        $this->attach($node);
    }

    private function attach(array $node): void
    {
        if ($this->open === []) {
            $this->root = $node;

            return;
        }

        $this->open[\array_key_last($this->open)]['children'][] = $node;
    }

    // An estimate of the size of the JSON. The walk stops when the tree cannot fit. So a large
    // value costs no more time.
    private function count(Cursor $cursor, array $node): void
    {
        $this->bytes += self::NODE_BYTES
            + \strlen((string) ($node['key'] ?? ''))
            + \strlen((string) ($node['value'] ?? ''))
            + \strlen((string) ($node['class'] ?? ''));

        if ($this->bytes <= $this->maxBytes) {
            return;
        }

        $this->tooLarge = true;
        $cursor->stop = true;
    }

    /** @return array<string, mixed> */
    private function keyOf(Cursor $cursor): array
    {
        $key = $cursor->hashKey;

        if ($key === null) {
            return [];
        }

        // Only a string key can be binary.
        if ($cursor->hashKeyIsBinary) {
            $key = $this->utf8Encode((string) $key);
        }

        return match ($cursor->hashType) {
            Cursor::HASH_OBJECT => self::propertyKey((string) $key),
            Cursor::HASH_RESOURCE => ['key' => (string) $key, 'access' => 'virtual'],
            default => \is_int($key) ? ['key' => (string) $key, 'index' => true] : ['key' => $key],
        };
    }

    // VarDumper marks the access of a property with a prefix between two NUL bytes, as a cast of
    // an object to an array does.
    /** @return array{key: string, access: string} */
    private static function propertyKey(string $key): array
    {
        if ($key === '') {
            return ['key' => $key, 'access' => 'public'];
        }

        if ($key[0] !== "\0") {
            return ['key' => $key, 'access' => 'public'];
        }

        $end = \strpos($key, "\0", 1);

        if ($end === false) {
            return ['key' => \substr($key, 1), 'access' => 'private'];
        }

        $prefix = \substr($key, 0, $end + 1);

        // A caster can put settings between the ~ and the second NUL byte of a virtual key.
        $access = match (true) {
            $prefix === Caster::PREFIX_DYNAMIC => 'dynamic',
            $prefix === Caster::PREFIX_PROTECTED => 'protected',
            \str_starts_with($prefix, \substr(Caster::PREFIX_VIRTUAL, 0, 2)) => 'virtual',
            default => 'private',
        };

        return ['key' => \substr($key, $end + 1), 'access' => $access];
    }

    private static function float(float $value): string
    {
        if (\is_nan($value)) {
            return 'NAN';
        }

        if (\is_infinite($value)) {
            return $value > 0 ? 'INF' : '-INF';
        }

        $text = (string) $value;

        return \str_contains($text, '.') ? $text : "{$text}.0";
    }
}
