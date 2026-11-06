import NexusCore
import Testing

struct ServiceIDTests {
    @Test(arguments: [
        ("nginx", "1.30", "nginx"),
        ("httpd", "2.4", "apache"),
        ("php", "8.4", "php-8.4"),
        ("redis", "8.2", "redis-8.2"),
        ("mysql", "8.4", "mysql-8.4"),
        ("mariadb", "11.4", "mariadb-11.4"),
        ("postgresql", "17", "postgresql-17"),
        ("mailpit", "1", "mail"),
    ])
    func aPackageWithAServiceGetsItsID(package: String, line: String, id: String) {
        #expect(ServiceID.of(package: package, line: line) == id)
    }

    @Test(arguments: ["node", "composer"])
    func aPackageWithoutAServiceGetsNoID(package: String) {
        #expect(ServiceID.of(package: package, line: "1") == nil)
    }
}
