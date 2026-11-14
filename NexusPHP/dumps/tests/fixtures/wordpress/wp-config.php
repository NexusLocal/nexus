<?php

// This site defines SAVEQUERIES only when the URL asks for it. Else Nexus defines it at the first
// query.
define('DB_NAME', 'shop');

if (isset($_GET['savequeries'])) {
    define('SAVEQUERIES', true);
}

require_once ABSPATH.'wp-settings.php';
