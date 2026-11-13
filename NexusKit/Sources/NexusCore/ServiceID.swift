// nexusd and the app name a service after its package and its version line, for example php-8.4.
// nginx, Apache and the mail service have one service for all their version lines. Node and
// Composer have no service.
public enum ServiceID {
    public static let nginx = "nginx"
    public static let apache = "apache"
    public static let mail = "mail"
    // The names of the three ports of the mail service in the port registry of nexusd.
    public static let smtpPortKey = "smtp"
    public static let inboxPortKey = "inbox"
    public static let mailpitSMTPPortKey = "mailpit-smtp"
    // The port of the web page of the dumps in the port registry of nexusd.
    public static let dumpPagePortKey = "dump-page"
    public static let dumpPageStandardPort = 8026

    public static func php(line: String) -> String {
        "php-\(line)"
    }

    public static func redis(line: String) -> String {
        "redis-\(line)"
    }

    public static func redisLine(of id: String) -> String? {
        id.hasPrefix("redis-") ? String(id.dropFirst("redis-".count)) : nil
    }

    public static func of(package: String, line: String) -> String? {
        switch package {
        case "nginx": nginx
        case "httpd": apache
        case "php": php(line: line)
        case "redis": redis(line: line)
        case "mailpit": mail
        default: DatabaseKind(rawValue: package).map { "\($0.rawValue)-\(line)" }
        }
    }
}
