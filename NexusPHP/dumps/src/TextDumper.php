<?php

declare(strict_types=1);

namespace Nexus\Dumps;

use Nexus\Dumps\VarDumper\Cloner\Cursor;

/*
 * CliDumper without colors that keeps whole lines up to a limit. At the limit it stops the walk
 * through the data. So a very large value costs no more time.
 */
final class TextDumper extends NexusCliDumper
{
    private string $text = '';

    private bool $truncated = false;

    public function __construct(private readonly int $maxBytes)
    {
        parent::__construct($this->collect(...));
        $this->setColors(false);
    }

    public function text(): string
    {
        return \rtrim($this->text, "\n");
    }

    public function isTruncated(): bool
    {
        return $this->truncated;
    }

    public function dumpScalar(Cursor $cursor, string $type, string|int|float|bool|null $value): void
    {
        if ($this->stops($cursor)) {
            return;
        }

        parent::dumpScalar($cursor, $type, $value);
    }

    public function dumpString(Cursor $cursor, string $str, bool $bin, int $cut): void
    {
        if ($this->stops($cursor)) {
            return;
        }

        parent::dumpString($cursor, $str, $bin, $cut);
    }

    public function enterHash(Cursor $cursor, int $type, string|int|null $class, bool $hasChild): void
    {
        if ($this->stops($cursor)) {
            return;
        }

        parent::enterHash($cursor, $type, $class, $hasChild);
    }

    private function collect(string $line, int $depth, string $indentPad): void
    {
        // Depth -1 marks the end of the dump.
        if ($depth < 0) {
            return;
        }

        if ($this->truncated) {
            return;
        }

        $line = \str_repeat($indentPad, $depth)."{$line}\n";

        if (\strlen($this->text) + \strlen($line) > $this->maxBytes) {
            $this->truncated = true;

            return;
        }

        $this->text .= $line;
    }

    private function stops(Cursor $cursor): bool
    {
        if (!$this->truncated) {
            return false;
        }

        $cursor->stop = true;

        return true;
    }
}
