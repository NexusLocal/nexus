<?php

declare(strict_types=1);

// As the db.php drop-in of Query Monitor: a subclass of wpdb in the content folder.
final class QM_DB extends wpdb
{
    public function query(string $query): int
    {
        return parent::query($query);
    }
}
