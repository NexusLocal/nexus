// nexusd and the app name a service after its package and its version line, for example php-8.4.
// nginx and Apache have one service for all their version lines. Node and Composer have no
// service.
public enum ServiceID {
    public static let nginx = "nginx"
    public static let apache = "apache"

    public static func php(line: String) -> String {
        "php-\(line)"
    }

    public static func redis(line: String) -> String {
        "redis-\(line)"
    }

    public static func of(package: String, line: String) -> String? {
        switch package {
        case "nginx": nginx
        case "httpd": apache
        case "php": php(line: line)
        case "redis": redis(line: line)
        default: DatabaseKind(rawValue: package).map { "\($0.rawValue)-\(line)" }
        }
    }
}
