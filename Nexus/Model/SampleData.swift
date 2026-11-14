import Foundation
import NexusCore
import NexusIPC
import NexusMail
import NexusSupervisor

extension AppModel {
    static func sample() -> AppModel {
        let model = AppModel()
        model.siteEntries = sampleSites
        model.services = sampleServices
        model.packages = samplePackages
        model.activities = [
            ActivityItem(title: "Importing foo_platform into MySQL 8.0", shortTitle: "Importing foo_platform", progress: 0.62),
            ActivityItem(title: "Downloading PostgreSQL 18", shortTitle: "Downloading PostgreSQL 18", progress: 0.48),
        ]
        model.packagesChecked = "08:55"
        model.settings = sampleSettings
        model.rootCertificate = sampleRootCertificate
        model.settingsDrafts["php-8.4"] = [
            "memory_limit = 512M",
            "upload_max_filesize = 64M",
            "post_max_size == 64M",
            "max_execution_time = 120",
        ]
        model.settingsErrors["php-8.4"] = SettingsError(line: 3, message: "syntax error, unexpected '='")
        model.mails = sampleMails
        model.mailCount = 248
        model.mailTags = ["blog.test", "crm.test", "fix.shop.test", "shop.test"]
        model.mailStatus = MailStatus(installed: true, running: true, receiving: true, smtpPort: 1025, inboxPort: 8025, waiting: 0, waitingBytes: 0, removed: 0, refused: 0, outboxFolder: "~/Library/Application Support/Nexus/mail/outbox", settings: MailSettings())
        model.openMailID = sampleMails.first?.id
        model.openMail = sampleMail(sampleMails[0].id)
        model.show(sampleDumpList())
        return model
    }

    // The list of nexusd for the Dumps screen of the design. A state of "Dumps States" changes it:
    // off, empty, blocked or problem. The state jobs adds the job entries of the frame "Dumps Jobs".
    // The design shows the queries and the jobs switched on. The app gets the list as it gets the
    // first event of nexusd.
    static func sampleDumpList(_ state: String? = nil) -> DumpList {
        let catches = state != "off"
        let settings = DumpSettings(catchDumps: catches, catchQueries: catches, catchLogs: catches, catchJobs: catches, pageMode: .automatic, commands: true)
        let blocked = state == "blocked" ? sampleDumpBlocks : []
        let problem = state == "problem" ? "Nexus catches no dumps, because it cannot copy the PHP library of the dump viewer from the app. The activity log has the reason." : nil
        let requests = state == "jobs" ? sampleJobRequests + sampleDumpRequests : sampleDumpRequests

        return DumpList(requests: state == "empty" ? [] : requests, settings: settings, blocked: blocked, receiving: true, problem: problem)
    }

    private static let sampleDumpBlocks = [
        DumpBlock(host: "crm.test", reason: .varDumperFormat, file: home("~/Development/crm/.env"), place: DumpPlace(site: "crm.test")),
        DumpBlock(host: "blog.test", reason: .userIni, file: home("~/Development/blog/.user.ini"), place: DumpPlace(site: "blog.test")),
        DumpBlock(host: "blog.test", reason: .savequeries, file: home("~/Development/blog/wp-config.php"), place: DumpPlace(site: "blog.test")),
    ]

    private static func today(_ hour: Int, _ minute: Int, _ second: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: second, of: .now) ?? .now
    }

    private static func home(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private static let sampleMailJob = "9f1c0f6e-8d2a-4b51-a1c3-5e7f0b9d2c44"

    // The requests of the Dumps screen in the design, in the order of the design. The counts and
    // the marks come from their sample entries, as the store of nexusd counts them.
    private static let sampleDumpRequests = [
        DumpedRequest(id: "sample-checkout", kind: .http, method: "GET", target: "/checkout", url: "https://shop.test/checkout", host: "shop.test", root: home("~/Development/shop/public"), site: "shop.test", started: today(14, 32, 8), status: 200, duration: 0.184, placeHost: "shop.test", projectFolder: home("~/Development/shop")),
        DumpedRequest(id: "sample-mail-job", kind: .job, target: "App\\Jobs\\SendOrderMail", root: home("~/Development/shop"), site: "shop.test", started: today(14, 32, 10), duration: 0.22, placeHost: "shop.test", projectFolder: home("~/Development/shop"), job: JobRun(system: .laravel, name: "App\\Jobs\\SendOrderMail", queue: "default", connection: "redis", uuid: sampleMailJob, attempt: 1, maxTries: 3, outcome: .done, command: "php artisan queue:work", queuedBy: "sample-checkout")),
        DumpedRequest(id: "sample-livewire", kind: .http, method: "POST", target: "/livewire/update", url: "https://shop.test/livewire/update", host: "shop.test", root: home("~/Development/shop/public"), site: "shop.test", started: today(14, 31, 40), status: 200, duration: 0.092, placeHost: "shop.test", projectFolder: home("~/Development/shop")),
        DumpedRequest(id: "sample-orders-api", kind: .http, method: "GET", target: "/api/orders", url: "https://fix.shop.test/api/orders", host: "fix.shop.test", root: home("~/Development/shop-fix/public"), site: "shop.test", workspace: "fix", started: today(14, 29, 12), status: 200, duration: 0.061, placeHost: "fix.shop.test", projectFolder: home("~/Development/shop-fix")),
        DumpedRequest(id: "sample-order", kind: .http, method: "GET", target: "/orders/1042", url: "https://shop.test/orders/1042", host: "shop.test", root: home("~/Development/shop/public"), site: "shop.test", started: today(14, 18, 3), status: 500, duration: 0.047, placeHost: "shop.test", projectFolder: home("~/Development/shop")),
        DumpedRequest(id: "sample-import", kind: .command, target: "artisan import:products", root: home("~/Development/shop"), site: "shop.test", started: today(13, 58, 21), exitCode: 0, duration: 3.2, placeHost: "shop.test", projectFolder: home("~/Development/shop")),
        DumpedRequest(id: "sample-hello", kind: .http, method: "GET", target: "/hello-world/", url: "https://blog.test/hello-world/", host: "blog.test", root: home("~/Development/blog"), site: "blog.test", started: today(13, 40, 55), status: 200, duration: 0.23, placeHost: "blog.test", projectFolder: home("~/Development/blog")),
    ].map { request in counted(request) }

    // The jobs of the frame "Dumps Jobs" that the state jobs adds.
    private static let sampleJobRequests = [
        DumpedRequest(id: "sample-stock-job", kind: .job, target: "App\\Jobs\\SyncStock", root: home("~/Development/shop"), site: "shop.test", started: today(14, 35, 2), duration: 1.4, placeHost: "shop.test", projectFolder: home("~/Development/shop"), job: JobRun(system: .laravel, name: "App\\Jobs\\SyncStock", queue: "default", connection: "redis", uuid: "b4e2", attempt: 3, maxTries: 3, outcome: .failed, command: "php artisan queue:work")),
        DumpedRequest(id: "sample-cron", kind: .job, target: "wp_scheduled_delete", root: home("~/Development/blog"), site: "blog.test", started: today(13, 45, 1), duration: 0.041, placeHost: "blog.test", projectFolder: home("~/Development/blog"), job: JobRun(system: .cron, name: "wp_scheduled_delete", outcome: .done, command: "wp-cron.php")),
        DumpedRequest(id: "sample-action", kind: .job, target: "woocommerce_cleanup_draft_orders", root: home("~/Development/blog"), site: "blog.test", started: today(13, 45, 0), duration: 0.085, placeHost: "blog.test", projectFolder: home("~/Development/blog"), job: JobRun(system: .action, name: "woocommerce_cleanup_draft_orders", queue: "woocommerce", uuid: "4711", attempt: 1, outcome: .done, command: "wp-cron.php")),
    ].map { request in counted(request) }

    private static func counted(_ request: DumpedRequest) -> DumpedRequest {
        let entries = sampleEntries(of: request)
        var header = request
        var queries = QueryTally()

        for entry in entries {
            header.count(entry, by: 1)

            if entry.kind == .query {
                queries.add(entry, pattern: QueryMarks.pattern(of: entry))
            }
        }

        header.hasDD = entries.contains { entry in entry.kind == .dd }
        header.queryMilliseconds = queries.milliseconds
        header.marks = queries.marks
        header.lastSeq = entries.count
        header.firstSeq = 1
        header.lastNumber = entries.count
        header.firstNumber = 1
        return header
    }

    // The entries as nexusd gives them, with the tree as JSON text: the dumps first, then the
    // queries, the log lines and the job rows.
    static func sampleDumps(of requestID: String) -> [CaughtDump] {
        guard let request = (sampleDumpRequests + sampleJobRequests).first(where: { $0.id == requestID }) else {
            return []
        }

        return sampleEntries(of: request)
    }

    private static func sampleEntries(of request: DumpedRequest) -> [CaughtDump] {
        guard let folder = request.projectFolder else {
            return []
        }

        let dumps = (sampleDumpContents[request.id] ?? []).map { content in
            SampleEntry(kind: content.kind, file: content.file, line: content.line, text: content.text, tree: content.tree)
        }

        return (dumps + (sampleEntryContents[request.id] ?? [])).enumerated().map { index, content in
            let tree = content.tree.flatMap { tree in try? JSONEncoder().encode(tree) }.map { json in String(decoding: json, as: UTF8.self) }
            return CaughtDump(requestID: request.id, seq: index + 1, time: request.started.addingTimeInterval(0.02 * Double(index + 1)), kind: content.kind, file: "\(folder)/\(content.file)", line: content.line, label: content.label, text: content.text, treeJSON: tree, milliseconds: content.milliseconds, pattern: content.pattern, detail: content.detail, ref: content.ref, number: index + 1)
        }
    }

    // A query, a log line or a job row of the sample data. The file is in the project folder.
    private struct SampleEntry {
        var kind: CaughtDump.Kind
        var file: String
        var line: Int
        var label: String?
        var text: String
        var tree: DumpNode?
        var milliseconds: Double?
        var pattern: String?
        var detail: String?
        var ref: String?

        static func query(_ file: String, _ line: Int, _ sql: String, _ milliseconds: Double, pattern: String? = nil) -> SampleEntry {
            SampleEntry(kind: .query, file: file, line: line, label: "mysql", text: sql, milliseconds: milliseconds, pattern: pattern)
        }

        static func log(_ file: String, _ line: Int, _ level: String, _ message: String, detail: String, context: DumpNode? = nil) -> SampleEntry {
            SampleEntry(kind: .log, file: file, line: line, label: level, text: message, tree: context, detail: detail)
        }

        static func job(_ file: String, _ line: Int, _ state: String, _ name: String, detail: String, milliseconds: Double? = nil, ref: String? = nil) -> SampleEntry {
            SampleEntry(kind: .job, file: file, line: line, label: state, text: name, milliseconds: milliseconds, detail: detail, ref: ref)
        }
    }

    // Laravel sends each query with its pattern. WordPress does not. The pattern of the sample
    // replaces each value, also the values that Laravel does not bind, such as a limit.
    private static func laravel(_ file: String, _ line: Int, _ sql: String, _ milliseconds: Double) -> SampleEntry {
        .query(file, line, sql, milliseconds, pattern: QueryMarks.pattern(of: sql))
    }

    private static let checkout = "app/Http/Controllers/CheckoutController.php"
    private static let orders = "app/Http/Controllers/OrderController.php"

    private static let sampleEntryContents: [String: [SampleEntry]] = [
        "sample-checkout": [
            laravel(checkout, 38, "select * from `carts` where `user_id` = 7 limit 1", 0.84),
        ] + (1...12).map { index -> SampleEntry in
            .query("app/Models/CartItem.php", 24, "select * from `products` where `products`.`id` = \(100 + index) limit 1", 0.8, pattern: "select * from `products` where `products`.`id` = ? limit 1")
        } + [
            laravel("app/Services/PriceCalculator.php", 31, "select * from `settings` where `key` = 'currency' limit 1", 0.55),
            laravel("app/Http/Middleware/Authenticate.php", 28, "select * from `users` where `id` = 7 limit 1", 0.62),
            laravel("app/Services/PriceCalculator.php", 31, "select * from `settings` where `key` = 'currency' limit 1", 0.55),
            laravel(checkout, 51, "select count(*) as aggregate from `orders` where `user_id` = 7 and `status` = 'paid'", 142),
            laravel(checkout, 54, "select * from `addresses` where `user_id` = 7", 1.2),
            laravel(checkout, 55, "select * from `shipping_methods` where `active` = 1", 0.9),
            laravel("app/Services/CouponService.php", 19, "select * from `coupons` where `code` = 'WELCOME' limit 1", 0.7),
            laravel("app/Services/PaymentService.php", 33, "select * from `payment_methods` where `active` = 1", 0.8),
            laravel(checkout, 66, "insert into `cart_events` (`cart_id`, `type`, `created_at`) values (1287, 'checkout', '2026-11-13 14:32:08')", 2.3),
            laravel(checkout, 70, "update `carts` set `checked_out_at` = '2026-11-13 14:32:08' where `id` = 1287", 1.6),
            laravel("app/Http/Middleware/StartSession.php", 44, "update `sessions` set `last_activity` = 1763040728 where `id` = 'Xk3Pq'", 1.1),
            .log("app/Services/PriceApi.php", 58, "warning", "The price API answered slowly.", detail: "stack", context: DumpNode(kind: .array, count: 2, children: [
                item("url", .string, "https://prices.example.com/v2"),
                item("seconds", .float, "1.24"),
            ])),
            .job(checkout, 63, "queued", "App\\Jobs\\SendOrderMail", detail: "redis · default", ref: sampleMailJob),
            .job(checkout, 61, "sync", "App\\Jobs\\UpdateStock", detail: "sync", milliseconds: 12),
        ],
        "sample-mail-job": [
            laravel("app/Jobs/SendOrderMail.php", 31, "select * from `orders` where `id` = 1042 limit 1", 0.9),
            laravel("app/Jobs/SendOrderMail.php", 32, "select * from `users` where `id` = 7 limit 1", 0.6),
            laravel("app/Jobs/SendOrderMail.php", 40, "insert into `mail_log` (`order_id`, `sent_at`) values (1042, '2026-11-13 14:32:10')", 2.1),
            laravel("app/Jobs/SendOrderMail.php", 41, "update `orders` set `mailed_at` = '2026-11-13 14:32:10' where `id` = 1042", 1.8),
        ],
        "sample-livewire": [
            laravel("app/Livewire/CartCounter.php", 24, "select * from `carts` where `user_id` = 7 limit 1", 0.7),
            laravel("app/Livewire/CartCounter.php", 25, "select count(*) as aggregate from `cart_items` where `cart_id` = 1287", 0.5),
            laravel("app/Http/Middleware/Authenticate.php", 28, "select * from `users` where `id` = 7 limit 1", 0.6),
            laravel("app/Livewire/CartCounter.php", 40, "select * from `products` where `id` in (101, 102, 103)", 1.3),
            laravel("app/Livewire/CartCounter.php", 44, "select * from `settings` where `key` = 'currency' limit 1", 0.5),
            laravel("app/Http/Middleware/StartSession.php", 44, "update `sessions` set `last_activity` = 1763040700 where `id` = 'Xk3Pq'", 1.0),
        ],
        "sample-orders-api": [
            laravel("app/Http/Controllers/Api/OrderController.php", 22, "select count(*) as aggregate from `orders` where `user_id` = 7", 0.8),
            laravel("app/Http/Controllers/Api/OrderController.php", 27, "select * from `orders` where `user_id` = 7 order by `created_at` desc limit 15", 1.4),
            laravel("app/Http/Middleware/Authenticate.php", 28, "select * from `users` where `id` = 7 limit 1", 0.6),
        ],
        "sample-order": (1...8).map { index -> SampleEntry in
            laravel(orders, 40 + index, "select * from `order_lines` where `order_id` = 1042 and `position` = \(index)", 0.6)
        } + [
            .log(orders, 77, "error", "Order 1042 has no invoice.", detail: "stack", context: DumpNode(kind: .array, count: 2, children: [
                item("order_id", .int, "1042"),
                DumpNode(kind: .object, key: "exception", className: "App\\Exceptions\\InvoiceMissing", ref: 412, count: 3, children: [
                    property("message", .string, "Order 1042 has no invoice.", .protected),
                    property("file", .string, home("~/Development/shop/app/Services/InvoiceService.php"), .protected),
                    DumpNode(kind: .array, key: "trace", access: .private, count: 24, cut: 24),
                ]),
            ])),
            .log("app/Services/PriceApi.php", 58, "warning", "The price API answered slowly.", detail: "stack", context: DumpNode(kind: .array, count: 2, children: [
                item("url", .string, "https://prices.example.com/v2"),
                item("seconds", .float, "1.24"),
            ])),
        ],
        "sample-hello": [
            .query("wp-includes/class-wp-query.php", 3345, "SELECT wp_posts.* FROM wp_posts WHERE 1=1 AND wp_posts.post_name = 'hello-world' AND wp_posts.post_type = 'post' ORDER BY wp_posts.post_date DESC", 1.9),
            .query("wp-content/themes/blog/functions.php", 18, "SELECT option_value FROM wp_options WHERE option_name = 'blog_banner' LIMIT 1", 0.4),
            .log("wp-content/themes/shop/functions.php", 212, "warning", "Undefined array key \"price\"", detail: "PHP warning"),
            .log("wp-content/plugins/shop-sync/sync.php", 48, "deprecated", "Function get_page_by_title is deprecated since version 6.2.0! Use WP_Query instead.", detail: "PHP deprecated"),
        ] + (1...10).map { index in
            SampleEntry.query("wp-content/themes/blog/single.php", 22, "SELECT * FROM wp_postmeta WHERE post_id = \(index) AND meta_key = '_thumbnail_id'", 0.3)
        },
        "sample-stock-job": [
            .log("app/Jobs/SyncStock.php", 52, "error", "The stock API did not answer in 30 seconds.", detail: "stack"),
        ],
        "sample-cron": [
            .query("wp-includes/functions.php", 7642, "SELECT post_id FROM wp_postmeta WHERE meta_key = '_wp_trash_meta_time' AND meta_value < 1760448310", 0.5),
            .query("wp-includes/functions.php", 7660, "SELECT comment_id FROM wp_commentmeta WHERE meta_key = '_wp_trash_meta_time' AND meta_value < 1760448310", 0.4),
            .query("wp-includes/option.php", 1340, "UPDATE wp_options SET option_value = '1763041500' WHERE option_name = 'cron'", 0.6),
        ],
        "sample-action": [
            .query("wp-content/plugins/woocommerce/includes/class-wc-order-data-store-cpt.php", 1102, "SELECT ID FROM wp_posts WHERE post_status = 'wc-checkout-draft' AND post_modified_gmt < '2026-11-12 13:45:00' LIMIT 20", 1.1),
            .query("wp-content/plugins/woocommerce/includes/class-wc-order-data-store-cpt.php", 1120, "DELETE FROM wp_posts WHERE ID IN (88, 91)", 2.4),
        ],
    ]

    private static func property(_ key: String, _ kind: DumpNode.Kind, _ value: String, _ access: DumpNode.Access = .public) -> DumpNode {
        DumpNode(kind: kind, key: key, access: access, value: value)
    }

    private static func item(_ key: String, _ kind: DumpNode.Kind, _ value: String) -> DumpNode {
        DumpNode(kind: kind, key: key, value: value)
    }

    private static func cartItem(_ index: Int, name: String, price: String) -> DumpNode {
        DumpNode(kind: .object, key: String(index), index: true, className: "App\\Models\\CartItem", ref: 1291 + index, count: 3, children: [
            property("id", .int, String(index + 1)),
            property("name", .string, name),
            property("price", .string, price),
        ])
    }

    private static let sampleCart = DumpNode(kind: .object, className: "App\\Models\\Cart", ref: 1287, count: 3, children: [
        property("id", .int, "42"),
        property("total", .string, "129.95"),
        DumpNode(kind: .object, key: "items", access: .public, className: "Illuminate\\Support\\Collection", ref: 1290, count: 2, children: [
            DumpNode(kind: .array, key: "items", access: .protected, count: 3, children: [
                cartItem(0, name: "Coffee beans", price: "14.95"),
                cartItem(1, name: "Espresso machine", price: "99.00"),
                cartItem(2, name: "Milk jug", price: "16.00"),
            ]),
            property("escapeWhenCastingToString", .bool, "false", .protected),
        ]),
    ])

    private static let sampleOrder = DumpNode(kind: .object, className: "App\\Models\\Order", ref: 2210, count: 5, children: [
        property("id", .int, "1042"),
        property("status", .string, "paid"),
        DumpNode(kind: .object, key: "customer", access: .public, className: "App\\Models\\User", ref: 2215, count: 2, children: [
            property("name", .string, "Anna de Vries"),
            property("email", .string, "anna@example.com"),
        ]),
        DumpNode(kind: .string, key: "note", access: .public, value: "Leave the parcel at the back door. Ring the bell two times and wait, because the door", cut: 412, length: 498),
        property("shippedAt", .null, "null"),
    ])

    private static let sampleDumpContents: [String: [(file: String, line: Int, kind: CaughtDump.Kind, text: String, tree: DumpNode)]] = [
        "sample-checkout": [
            ("app/Http/Controllers/CheckoutController.php", 42, .dump, """
                App\\Models\\Cart {#1287
                  +id: 42
                  +total: "129.95"
                  +items: Illuminate\\Support\\Collection {#1290
                    #items: array:3 [
                      0 => App\\Models\\CartItem {#1291
                        +id: 1
                        +name: "Coffee beans"
                        +price: "14.95"
                      }
                      1 => App\\Models\\CartItem {#1292
                        +id: 2
                        +name: "Espresso machine"
                        +price: "99.00"
                      }
                      2 => App\\Models\\CartItem {#1293
                        +id: 3
                        +name: "Milk jug"
                        +price: "16.00"
                      }
                    ]
                    #escapeWhenCastingToString: false
                  }
                }
                """, sampleCart),
            ("app/Http/Controllers/CheckoutController.php", 57, .dump, "\"EUR\"", DumpNode(kind: .string, value: "EUR")),
            ("app/Services/PriceCalculator.php", 88, .dump, "array:2 [\n  \"shipping\" => \"pickup\"\n  \"coupon\" => null\n]", DumpNode(kind: .array, count: 2, children: [
                item("shipping", .string, "pickup"),
                item("coupon", .null, "null"),
            ])),
        ],
        "sample-livewire": [
            ("app/Livewire/CartCounter.php", 31, .dump, "array:2 [\n  \"count\" => 3\n  \"open\" => true\n]", DumpNode(kind: .array, count: 2, children: [
                item("count", .int, "3"),
                item("open", .bool, "true"),
            ])),
        ],
        "sample-orders-api": [
            ("app/Http/Controllers/Api/OrderController.php", 24, .dump, "18", DumpNode(kind: .int, value: "18")),
            ("app/Http/Controllers/Api/OrderController.php", 29, .dump, "array:1 [\n  0 => App\\Models\\Order {#2210\n    +id: 1042\n    +status: \"paid\"\n  }\n]", DumpNode(kind: .array, count: 1, children: [
                DumpNode(kind: .object, key: "0", index: true, className: "App\\Models\\Order", ref: 2210, count: 2, children: [
                    property("id", .int, "1042"),
                    property("status", .string, "paid"),
                ]),
            ])),
        ],
        "sample-order": [
            ("app/Http/Controllers/OrderController.php", 51, .dd, """
                App\\Models\\Order {#2210
                  +id: 1042
                  +status: "paid"
                  +customer: App\\Models\\User {#2215
                    +name: "Anna de Vries"
                    +email: "anna@example.com"
                  }
                  +note: "Leave the parcel at the back door. Ring the bell two times and wait, because the door"…412
                  +shippedAt: null
                }
                """, sampleOrder),
        ],
        "sample-import": [
            ("app/Console/Commands/ImportProducts.php", 40, .dump, "\"storage/app/products.csv\"", DumpNode(kind: .string, value: "storage/app/products.csv")),
            ("app/Console/Commands/ImportProducts.php", 52, .dump, "248", DumpNode(kind: .int, value: "248")),
            ("app/Console/Commands/ImportProducts.php", 66, .dump, "array:3 [\n  \"sku\" => \"COF-250\"\n  \"name\" => \"Coffee beans\"\n  \"price\" => 14.95\n]", DumpNode(kind: .array, count: 3, children: [
                item("sku", .string, "COF-250"),
                item("name", .string, "Coffee beans"),
                item("price", .float, "14.95"),
            ])),
            ("app/Console/Commands/ImportProducts.php", 74, .dump, "array:2 [\n  \"created\" => 236\n  \"updated\" => 12\n]", DumpNode(kind: .array, count: 2, children: [
                item("created", .int, "236"),
                item("updated", .int, "12"),
            ])),
        ],
        "sample-hello": [
            ("wp-content/themes/blog/functions.php", 12, .dump, "WP_Post {#812\n  +ID: 1\n  +post_title: \"Hello world!\"\n  +post_status: \"publish\"\n}", DumpNode(kind: .object, className: "WP_Post", ref: 812, count: 3, children: [
                property("ID", .int, "1"),
                property("post_title", .string, "Hello world!"),
                property("post_status", .string, "publish"),
            ])),
        ],
    ]

    private static let sampleMails: [MailpitAPI.Summary] = [
        ("Shop <noreply@shop.test>", "Thank you for your order", "We received order #1042. We send it today.", "shop.test", "09:41"),
        ("Shop <noreply@shop.test>", "Your order #1041 is on its way", "The parcel arrives tomorrow.", "fix.shop.test", "09:38"),
        ("CRM <crm@crm.test>", "New lead: Foo B.V.", "A new lead came in through the form.", "crm.test", "09:20"),
        ("WordPress <wordpress@blog.test>", "New comment on Hello world", "A comment waits for your approval.", "blog.test", "08:55"),
        ("Shop <noreply@shop.test>", "Welcome to Shop", "Your account is ready.", "shop.test", "08:31"),
        ("root <www@localhost>", "Cron <www@localhost> php artisan", "No commands are ready to run.", nil, "07:00"),
    ].enumerated().map { index, mail in
        MailpitAPI.Summary(id: "sample-\(index)", from: mail.0, to: ["customer@example.com"], subject: mail.1, tags: mail.3.map { [$0] } ?? [], created: "2026-10-27T\(mail.4):00.000+01:00", snippet: mail.2)
    }

    static func sampleMail(_ id: String) -> MailpitAPI.Message? {
        guard let summary = sampleMails.first(where: { $0.id == id }) else {
            return nil
        }

        let html = """
            <div style="font-family:-apple-system,Helvetica;background:#F4F3F7;padding:24px">
            <div style="background:#fff;border-radius:8px;padding:24px;max-width:380px;margin:auto">
            <p style="font-weight:700;font-size:16px">Shop</p>
            <h2 style="font-size:18px">\(summary.subject)</h2>
            <p style="color:#3C3C43;font-size:13px;line-height:1.5">\(summary.snippet)</p>
            <a style="display:inline-block;background:#1F6FEB;color:#fff;padding:9px 16px;border-radius:6px;text-decoration:none">View your order</a>
            </div></div>
            """

        return MailpitAPI.Message(
            id: summary.id,
            from: summary.from,
            to: summary.to,
            cc: [],
            subject: summary.subject,
            date: summary.created,
            tags: summary.tags,
            text: summary.snippet,
            html: html,
            attachments: [],
            headers: ["Subject": [summary.subject], "From": [summary.from], "To": summary.to]
        )
    }

    private static func site(_ host: String, folder: String, documentRoot: String? = nil, server: String = "nginx", php: String = "8.4", aliases: [String] = [], group: String? = nil) -> SiteItem {
        let parent = (folder as NSString).deletingLastPathComponent
        let parked = parent == "~/Sites"
        return SiteItem(
            host: host,
            aliases: aliases,
            group: group,
            folder: folder,
            documentRoot: documentRoot ?? "\(folder)/public",
            server: server,
            php: php,
            url: "https://\(host):8443",
            parkedFolder: parked ? parent : nil,
            hasOwnSettings: !parked,
            projectNode: NodeChoice(line: "22", reason: "from .nvmrc"),
            projectType: .laravel
        )
    }

    private static var sampleNodeApp: SiteItem {
        var site = site("store.test", folder: "~/Development/store")
        site.kind = .node
        site.framework = .next
        site.projectCommand = "npm run dev"
        site.projectNode = NodeChoice(line: "24", reason: "from .nvmrc")
        site.app = AppProcessInfo(port: 19000, command: "npm run dev", state: .running(pid: 4242, since: .now.addingTimeInterval(-3600)), log: "~/Library/Application Support/Nexus/logs/app-store.test.log")
        return site
    }

    private static var sampleWordPress: SiteItem {
        var site = site("blog.test", folder: "~/Development/blog", documentRoot: "~/Development/blog", server: "apache", aliases: ["blog.local"])
        site.projectType = .wordpress
        site.backgroundCommands = []
        site.workspaces = [
            WorkspaceInfo(name: "fix", worktree: "~/Development/blog-fix", folder: "~/Development/blog-fix", branch: "fix", hosts: ["blog-fix.test"], url: "https://blog-fix.test", state: .ready),
        ]
        return site
    }

    private static var sampleProxy: SiteItem {
        var site = site("api.test", folder: "~/Development/api")
        site.kind = .proxy
        site.address = "http://127.0.0.1:3000"
        return site
    }

    private static var sampleSites: [SiteEntry] {
        [
            .group(SiteGroup(name: "Example", sites: [
                site("example.test", folder: "~/Development/Example/website", group: "Example"),
                site("my.example.test", folder: "~/Development/Example/portal", php: "8.5", group: "Example"),
            ])),
            .group(SiteGroup(name: "Agency", sites: [
                site("agency.test", folder: "~/Development/Agency/website", group: "Agency"),
                site("docs.agency.test", folder: "~/Development/Agency/docs", group: "Agency"),
                site("status.agency.test", folder: "~/Development/Agency/status", group: "Agency"),
            ])),
            .site(site("shop.test", folder: "~/Development/shop", aliases: ["www.shop.test"])),
            .site(site("crm.test", folder: "~/Development/crm", php: "8.5")),
            .site(sampleWordPress),
            .site(sampleNodeApp),
            .site(sampleProxy),
            .parked(ParkedFolder(path: "~/Sites", sites: [
                site("foo.test", folder: "~/Sites/foo"),
                site("demo.test", folder: "~/Sites/demo"),
                site("legacy.test", folder: "~/Sites/legacy"),
                site("notes.test", folder: "~/Sites/notes"),
            ])),
        ]
    }

    private static var sampleServices: [ServiceVersion] {
        [
            ServiceVersion(
                id: "nginx",
                kind: .webservers,
                name: "nginx 1.30",
                version: "1.30.0",
                health: .running,
                since: "09:02",
                ports: [ServicePort(name: "HTTP", number: 8080), ServicePort(name: "HTTPS", number: 8443)],
                toggles: [
                    ToggleItem(name: "ssl", enabled: true, required: true, help: "HTTPS for every site."),
                    ToggleItem(name: "http2", enabled: true, required: true, help: "HTTP/2. A browser loads many files over one connection."),
                    ToggleItem(name: "proxy", enabled: true, required: true, help: "Sends the requests of Apache sites on to Apache."),
                    ToggleItem(name: "gzip_static", enabled: true, help: "Sends a ready .gz file that sits next to a file. So nginx does not compress that file again for each request."),
                    ToggleItem(name: "image_filter", enabled: false, help: "Resizes and crops JPEG, GIF, PNG and WebP images on request."),
                    ToggleItem(name: "njs", enabled: false, help: "Runs JavaScript in nginx to change requests and responses."),
                    ToggleItem(name: "stream", enabled: false, help: "Sends TCP and UDP traffic on to another server."),
                    ToggleItem(name: "xslt", enabled: false, help: "Changes XML responses with XSLT style sheets."),
                ],
                log: [
                    "2026/10/27 09:02:09 [notice] 4777#0: using the \"kqueue\" event method",
                    "2026/10/27 09:02:09 [notice] 4777#0: nginx/1.30.0",
                    "2026/10/27 09:02:09 [notice] 4777#0: OS: Darwin 27.0.0",
                    "2026/10/27 09:02:09 [notice] 4777#0: start worker processes",
                    "2026/10/27 09:02:09 [notice] 4777#0: start worker process 4779",
                ]
            ),
            ServiceVersion(
                id: "apache",
                kind: .webservers,
                name: "Apache 2.4",
                version: "2.4.69",
                health: .stopped,
                ports: [ServicePort(name: "Internal", number: 8081)],
                internalPort: true,
                toggles: [
                    ToggleItem(name: "rewrite", enabled: true, help: "Rewrites URLs with the rules in .htaccess."),
                    ToggleItem(name: "headers", enabled: true, help: "Sets and removes HTTP headers."),
                    ToggleItem(name: "expires", enabled: true, help: "Tells the browser how long it can keep a file."),
                    ToggleItem(name: "deflate", enabled: true, help: "Compresses responses before Apache sends them."),
                    ToggleItem(name: "remoteip", enabled: true, required: true, help: "Takes the IP address of the client from nginx."),
                    ToggleItem(name: "setenvif", enabled: true, required: true, help: "Sets HTTPS=on for requests that came in over HTTPS."),
                    ToggleItem(name: "proxy_fcgi", enabled: true, required: true, help: "Sends PHP requests to PHP-FPM."),
                    ToggleItem(name: "cache", enabled: false, help: "Keeps responses in a cache."),
                    ToggleItem(name: "dav", enabled: false, help: "WebDAV, to change files over HTTP."),
                    ToggleItem(name: "status", enabled: false, help: "A page with the state of Apache at /server-status."),
                ],
                note: "Apache runs only when a site uses it. No site uses Apache now.",
                log: [
                    "[Tue Oct 27 08:41:02 2026] [mpm_prefork:notice] AH00163: Apache/2.4.69 (Unix) configured",
                    "[Tue Oct 27 08:41:02 2026] [core:notice] AH00094: Command line: 'httpd -D FOREGROUND'",
                    "[Tue Oct 27 09:01:44 2026] [mpm_prefork:notice] AH00169: caught SIGTERM, shutting down",
                ]
            ),
            ServiceVersion(
                id: "php-8.4",
                kind: .php,
                name: "PHP 8.4",
                version: "8.4.14",
                health: .running,
                since: "09:02",
                toggles: phpExtensions,
                customSettings: [
                    "memory_limit = 512M",
                    "upload_max_filesize = 64M",
                ],
                usedBy: ["shop.test", "blog.test", "example.test", "agency.test", "docs.agency.test", "status.agency.test", "foo.test", "demo.test"],
                log: [
                    "[27-Oct-2026 09:02:10] NOTICE: fpm is running, pid 4790",
                    "[27-Oct-2026 09:02:10] NOTICE: ready to handle connections",
                    "[27-Oct-2026 09:14:52] WARNING: [pool www] child 4811 said into stderr: \"PHP Deprecated: ...\"",
                    "[27-Oct-2026 09:20:01] NOTICE: Reloading in progress ...",
                    "[27-Oct-2026 09:20:01] NOTICE: ready to handle connections",
                ]
            ),
            ServiceVersion(
                id: "php-8.5",
                kind: .php,
                name: "PHP 8.5",
                version: "8.5.1",
                health: .running,
                since: "09:02",
                update: "8.5.2",
                toggles: phpExtensions,
                usedBy: ["my.example.test", "crm.test", "legacy.test", "notes.test"],
                log: [
                    "[27-Oct-2026 09:02:10] NOTICE: fpm is running, pid 4791",
                    "[27-Oct-2026 09:02:10] NOTICE: ready to handle connections",
                ]
            ),
            ServiceVersion(
                id: "mysql-8.0",
                kind: .mysql,
                name: "MySQL 8.0",
                version: "8.0.44",
                health: .running,
                since: "09:02",
                ports: [ServicePort(name: "Port", number: 13306)],
                update: "8.0.45",
                securityNote: "MySQL 8.0 gets no security fixes since 2026-04-30. Move the databases to MySQL 8.4 when you can.",
                dataFolder: "~/Library/Application Support/Nexus/data/mysql-8.0",
                account: DatabaseAccount(user: "root", password: ""),
                databases: [
                    DatabaseItem(name: "foo_platform", usedBy: nil, size: "2.8 GB"),
                    DatabaseItem(name: "shop", usedBy: "shop.test", size: "412 MB"),
                    DatabaseItem(name: "crm", usedBy: "crm.test", size: "86 MB"),
                ],
                log: [
                    "2026-10-27T09:02:11Z 0 [System] [MY-010116] mysqld (mysqld 8.0.44) starting as process 4821",
                    "2026-10-27T09:02:12Z 1 [System] [MY-013576] InnoDB initialization has started.",
                    "2026-10-27T09:02:13Z 1 [System] [MY-013577] InnoDB initialization has ended.",
                    "2026-10-27T09:02:13Z 0 [System] [MY-011323] X Plugin ready for connections. Bind-address: '127.0.0.1' port: 33060",
                    "2026-10-27T09:02:13Z 0 [System] [MY-010931] ready for connections. Version: '8.0.44'  port: 13306",
                ]
            ),
            ServiceVersion(
                id: "mysql-8.4",
                kind: .mysql,
                name: "MySQL 8.4",
                version: "8.4.7",
                health: .attention,
                ports: [ServicePort(name: "Port", number: 3306)],
                problem: ServiceProblem(
                    summary: "Port in use",
                    detail: "Port 3306 is in use by MAMP PRO (mysqld, process 812). Stop that app, or give the service another port.",
                    portHolder: PortHolder(
                        port: 3306,
                        app: "MAMP PRO",
                        process: "mysqld",
                        processNumber: 812,
                        path: "/Applications/MAMP/Library/bin/mysql80/bin/mysqld",
                        suggestedPort: 13307,
                        managerApp: "de.appsolute.mamppro",
                        canStop: false
                    )
                ),
                dataFolder: "~/Library/Application Support/Nexus/data/mysql-8.4",
                account: DatabaseAccount(user: "root", password: ""),
                log: [
                    "2026-10-27T09:02:11Z 0 [ERROR] [MY-010262] Can't start server: Bind on TCP/IP port: Address already in use",
                    "2026-10-27T09:02:11Z 0 [ERROR] [MY-010257] Do you already have another mysqld server running on port: 3306 ?",
                    "2026-10-27T09:02:11Z 0 [ERROR] [MY-010119] Aborting",
                ]
            ),
            ServiceVersion(
                id: "mysql-9.7",
                kind: .mysql,
                name: "MySQL 9.7",
                version: "9.7.0",
                health: .stopped,
                ports: [ServicePort(name: "Port", number: 13309)],
                dataFolder: "~/Library/Application Support/Nexus/data/mysql-9.7",
                account: DatabaseAccount(user: "root", password: "")
            ),
            ServiceVersion(
                id: "mariadb-11.4",
                kind: .mariadb,
                name: "MariaDB 11.4",
                version: "11.4.9",
                health: .stopped,
                ports: [ServicePort(name: "Port", number: 13308)],
                dataFolder: "~/Library/Application Support/Nexus/data/mariadb-11.4",
                account: DatabaseAccount(user: "root", password: "")
            ),
            ServiceVersion(
                id: "postgresql-17",
                kind: .postgresql,
                name: "PostgreSQL 17",
                version: "17.7",
                health: .running,
                since: "09:02",
                ports: [ServicePort(name: "Port", number: 15432)],
                dataFolder: "~/Library/Application Support/Nexus/data/postgresql-17",
                account: DatabaseAccount(user: "root", password: ""),
                databases: [
                    DatabaseItem(name: "postgres", usedBy: nil, size: "7.5 MB"),
                    DatabaseItem(name: "notes", usedBy: "notes.test", size: "24 MB"),
                ],
                log: [
                    "2026-10-27 09:02:11.204 CET [4830] LOG:  starting PostgreSQL 17.7 on aarch64-apple-darwin",
                    "2026-10-27 09:02:11.205 CET [4830] LOG:  listening on IPv4 address \"127.0.0.1\", port 15432",
                    "2026-10-27 09:02:11.212 CET [4830] LOG:  database system is ready to accept connections",
                ]
            ),
            ServiceVersion(
                id: "redis-8.2",
                kind: .redis,
                name: "Redis 8.2",
                version: "8.2.3",
                health: .running,
                since: "09:02",
                ports: [ServicePort(name: "Port", number: 16379)],
                dataFolder: "~/Library/Application Support/Nexus/data/redis-8.2",
                log: [
                    "4840:M 27 Oct 2026 09:02:11.301 * Server initialized",
                    "4840:M 27 Oct 2026 09:02:11.301 * Ready to accept connections tcp",
                ]
            ),
            ServiceVersion(
                id: ServiceID.mail,
                kind: .mail,
                name: "Mailpit",
                version: "1.33.0",
                health: .running,
                since: "09:02",
                ports: [ServicePort(name: "SMTP", number: 1025, key: ServiceID.smtpPortKey), ServicePort(name: "Inbox", number: 8025, key: ServiceID.inboxPortKey)],
                dataFolder: "~/Library/Application Support/Nexus/data/mailpit-1"
            ),
            ServiceVersion(
                id: "dns",
                kind: .dns,
                name: "DNS",
                version: "",
                health: .running,
                since: "09:02",
                ports: [ServicePort(name: "Port", number: 10053)],
                note: "The DNS server answers 127.0.0.1 for every name that ends in .test. /etc/resolver/test sends these names to this port."
            ),
        ]
    }

    private static var phpExtensions: [ToggleItem] {
        [
            ToggleItem(name: "opcache", enabled: true, help: "Keeps compiled PHP code in memory. So each request runs faster."),
            ToggleItem(name: "redis", enabled: true, help: "Connects to Redis. Laravel uses it for the cache, sessions and queues."),
            ToggleItem(name: "igbinary", enabled: true, help: "A faster and smaller format to store PHP values, for example in Redis."),
            ToggleItem(name: "apcu", enabled: false, help: "A cache in the memory of PHP-FPM."),
            ToggleItem(name: "imagick", enabled: true, help: "Changes images with ImageMagick."),
            ToggleItem(name: "yaml", enabled: false, help: "Reads and writes YAML."),
            ToggleItem(name: "xdebug", enabled: false, help: "Step debugger and profiler. It makes every request slower. So turn it on only while you debug."),
            ToggleItem(name: "pcov", enabled: false, help: "Measures code coverage for tests. It is faster than Xdebug for coverage."),
        ]
    }

    // The name gives the package and the line, for example Apache 2.4 gives httpd and 2.4.
    private static func package(_ section: String, _ name: String, _ version: String, _ state: PackageState = .available, lts: Bool = false, securityEnd: String? = nil, securityEnded: Bool = false, required: Bool = false) -> PackageItem {
        let words = name.split(separator: " ", maxSplits: 1).map(String.init)
        let package = words[0] == "Apache" ? "httpd" : words[0].lowercased()
        let line = words.count > 1 ? words[1] : "2"
        return PackageItem(section: section, package: package, line: line, name: name, version: version, state: state, lts: lts, securityEnd: securityEnd, securityEnded: securityEnded, required: required)
    }

    private static var samplePackages: [PackageItem] {
        [
            package("Webservers", "nginx 1.30", "1.30.0", .installed, required: true),
            package("Webservers", "Apache 2.4", "2.4.69", .installed),
            package("PHP", "PHP 8.2", "8.2.29", securityEnd: "2026-12-31"),
            package("PHP", "PHP 8.3", "8.3.27"),
            package("PHP", "PHP 8.4", "8.4.14", .installed),
            package("PHP", "PHP 8.5", "8.5.1", .update("8.5.2")),
            package("MySQL", "MySQL 8.0", "8.0.44", .installed, securityEnd: "2026-04-30", securityEnded: true),
            package("MySQL", "MySQL 8.4", "8.4.7", .installed, lts: true),
            package("MySQL", "MySQL 9.7", "9.7.0", .installed, lts: true),
            package("MariaDB", "MariaDB 10.11", "10.11.15", lts: true),
            package("MariaDB", "MariaDB 11.4", "11.4.9", .installed, lts: true),
            package("MariaDB", "MariaDB 11.8", "11.8.4", lts: true),
            package("MariaDB", "MariaDB 12.3", "12.3.1", lts: true),
            package("PostgreSQL", "PostgreSQL 14", "14.20", securityEnd: "2026-11-12"),
            package("PostgreSQL", "PostgreSQL 15", "15.15"),
            package("PostgreSQL", "PostgreSQL 16", "16.11"),
            package("PostgreSQL", "PostgreSQL 17", "17.7", .installed),
            package("PostgreSQL", "PostgreSQL 18", "18.1", .downloading(0.48)),
            package("Redis", "Redis 7.2", "7.2.11"),
            package("Redis", "Redis 8.2", "8.2.3", .installed),
            package("Redis", "Redis 8.10", "8.10.0"),
            package("Mail", "Mailpit", "1.33.0", .installed),
            package("Tools", "Node 22", "22.21.1", lts: true),
            package("Tools", "Node 24", "24.11.0", .update("24.11.1"), lts: true),
            package("Tools", "Node 26", "26.1.0"),
            package("Tools", "Composer", "2.9.2", .installed),
            package("Tools", "WP-CLI", "2.12.0"),
        ]
    }

    private static var sampleSettings: AppSettings {
        var settings = AppSettings()
        settings.terminals = [AppChoice(name: "Macterm"), AppChoice(name: "Terminal"), AppChoice(name: "Ghostty"), AppChoice(name: "iTerm")]
        settings.terminal = "Macterm"
        settings.editors = [AppChoice(name: "PhpStorm"), AppChoice(name: "Visual Studio Code"), AppChoice(name: "Zed")]
        settings.editor = "PhpStorm"
        settings.databaseApps = [
            AppChoice(name: "TablePlus", opens: "MySQL, MariaDB, PostgreSQL"),
            AppChoice(name: "Sequel Ace", opens: "MySQL, MariaDB"),
            AppChoice(name: "DBeaver", opens: "MySQL, MariaDB, PostgreSQL"),
        ]
        settings.mysqlApp = "TablePlus"
        settings.postgresqlApp = "TablePlus"
        return settings
    }

    private static var sampleRootCertificate: RootCertificateInfo {
        let validUntil = DateComponents(calendar: .current, year: 2036, month: 10, day: 26).date
        return RootCertificateInfo(trusted: true, validUntil: validUntil, file: "~/Library/Application Support/Nexus/certs/nexus-root-ca.pem")
    }
}
