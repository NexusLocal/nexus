<?php

declare(strict_types=1);

namespace Nexus\Dumps;

use Nexus\Dumps\VarDumper\Dumper\AbstractDumper;
use Nexus\Dumps\VarDumper\Dumper\CliDumper;

/*
 * The constructor of CliDumper asks the autoloaders of the site for FileLinkFormatter of Symfony.
 * The autoloader of a WordPress plugin can break on a name that it does not know. So this class
 * skips that constructor, as HtmlDumper does. It keeps the link format that CliDumper uses
 * without Symfony.
 */
class NexusCliDumper extends CliDumper
{
    public function __construct($output = null)
    {
        AbstractDumper::__construct($output);

        $this->setDisplayOptions([
            'fileLinkFormat' => \ini_get('xdebug.file_link_format') ?: \get_cfg_var('xdebug.file_link_format') ?: 'file://%f#L%l',
        ]);
    }
}
