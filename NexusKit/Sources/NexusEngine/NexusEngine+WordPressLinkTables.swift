import Foundation
import NexusCore

// The tables of a WordPress workspace with a link to an old URL (owner, 2026-11-09). WP-CLI reads
// each row of a table in each of its passes, also in a table without a link. One query for each
// table finds the tables with a link first. WP-CLI then reads only these tables.
extension NexusEngine {
    // nil when WordPress does not answer. WP-CLI then reads each table with the prefix, as before.
    func tablesWithLinks(to urls: [String], network: String?, with wpCLI: @escaping WPCLI) async -> [String]? {
        let hosts = Array(Set(urls.compactMap(WordPressURL.host(of:)))).sorted()

        guard !hosts.isEmpty, let json = try? JSONEncoder().encode(hosts) else {
            return nil
        }

        let source = Self.tablesWithLinksSource.replacingOccurrences(of: "@@hosts@@", with: json.base64EncodedString())
        let arguments = ["eval", source, "--skip-plugins", "--skip-themes"] + (network.map { ["--url=\($0)"] } ?? [])

        guard let output = try? await wpCLI(arguments),
              let close = output.range(of: Self.tablesWithLinksSeparator, options: .backwards),
              let open = output.range(of: Self.tablesWithLinksSeparator, options: .backwards, range: output.startIndex..<close.lowerBound) else {
            return nil
        }

        return try? JSONDecoder().decode([String].self, from: Data(output[open.upperBound..<close.lowerBound].utf8))
    }

    static let tablesWithLinksSeparator = "@@nexus-tables-with-links@@"

    static let tablesWithLinksSource = #"""
    global $wpdb;

    $hosts = json_decode(base64_decode('@@hosts@@'), true);
    $found = [];

    foreach ($wpdb->get_col($wpdb->prepare('SHOW TABLES LIKE %s', $wpdb->esc_like($wpdb->base_prefix) . '%')) as $table) {
        $conditions = [];

        foreach ($wpdb->get_results('SHOW COLUMNS FROM `' . str_replace('`', '``', $table) . '`') as $column) {
            if (!preg_match('/char|text|blob|json|enum|set/i', $column->Type)) {
                continue;
            }

            foreach ($hosts as $host) {
                $conditions[] = '`' . str_replace('`', '``', $column->Field) . "` LIKE '" . esc_sql('%' . $wpdb->esc_like($host) . '%') . "'";
            }
        }

        if ($conditions && $wpdb->get_var('SELECT 1 FROM `' . str_replace('`', '``', $table) . '` WHERE ' . implode(' OR ', $conditions) . ' LIMIT 1')) {
            $found[] = $table;
        }
    }

    echo '@@nexus-tables-with-links@@' . json_encode($found) . '@@nexus-tables-with-links@@';
    """#
}
