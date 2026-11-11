<?php

declare(strict_types=1);

namespace Nexus\Dumps;

use Nexus\Dumps\VarDumper\Caster\StubCaster;
use Nexus\Dumps\VarDumper\Cloner\Data;
use Nexus\Dumps\VarDumper\Cloner\VarCloner;

/*
 * Clones a value once and makes the text of CliDumper and the tree of the wire format from the
 * same data. So the text and the tree show the same values.
 */
final class Renderer
{
    public const MAX_STRING = 10_000;
    public const MAX_ITEMS = 2_500;
    public const TEXT_BYTES = 64 * 1024;
    public const TREE_BYTES = 512 * 1024;

    // Laravel adds these casters to its own cloner. Without them a model with a connection or
    // the container fills the whole dump.
    private const LARAVEL_CASTERS = [
        'Illuminate\Contracts\Container\Container',
        'Illuminate\Contracts\Events\Dispatcher',
        'Illuminate\Contracts\View\Factory',
        'Illuminate\Database\ConnectionInterface',
        'Illuminate\Database\Grammar',
    ];

    private readonly VarCloner $cloner;

    public function __construct()
    {
        $cloner = new VarCloner();
        $cloner->setMaxString(self::MAX_STRING);
        $cloner->setMaxItems(self::MAX_ITEMS);
        $cloner->addCasters(\array_fill_keys(self::LARAVEL_CASTERS, [StubCaster::class, 'cutInternals']));

        $this->cloner = $cloner;
    }

    public function cloneVar(mixed $value): Data
    {
        return $this->cloner->cloneVar($value);
    }

    /** @return array{data: Data, text: string, tree: ?string, truncated: bool} */
    public function render(mixed $value): array
    {
        $data = $this->cloneVar($value);

        $textDumper = new TextDumper(self::TEXT_BYTES);
        $textDumper->dump($data);

        $treeDumper = new TreeDumper(self::TREE_BYTES);
        $treeDumper->dump($data);

        return [
            'data' => $data,
            'text' => $textDumper->text(),
            'tree' => $treeDumper->json(),
            'truncated' => $textDumper->isTruncated(),
        ];
    }
}
