<?php

// A Bedrock site. Its config files set the constants and wp-config.php does not name them. The
// site turns the query log off. WordPress itself is in the folder next to this one.
require __DIR__.'/config/application.php';

define('ABSPATH', dirname(__DIR__).'/wordpress/');

require_once ABSPATH.'wp-settings.php';
