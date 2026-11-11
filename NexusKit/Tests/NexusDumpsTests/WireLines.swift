import Foundation
@testable import NexusDumps

enum WireLines {
    static let commandDumps = [
        #"{"v":1,"type":"dump","request":{"kind":"command","command":"php /Users/tim/Sites/tools/plain.php","cwd":"/Users/tim/Sites/tools","id":"7fc34bcf0060","root":"/Users/tim/Sites/tools","started":1794414394.794107,"pid":99714},"dump":{"seq":1,"time":1794414394.794884,"kind":"dump","file":"/Users/tim/Sites/tools/plain.php","line":5,"label":null,"text":"array:1 [\n  \"name\" => \"Nexus\"\n]","tree":"{\"kind\":\"array\",\"count\":1,\"children\":[{\"key\":\"name\",\"kind\":\"string\",\"value\":\"Nexus\"}]}","truncated":false}}"#,
        #"{"v":1,"type":"dump","request":{"kind":"command","command":"php /Users/tim/Sites/tools/plain.php","cwd":"/Users/tim/Sites/tools","id":"7fc34bcf0060","root":"/Users/tim/Sites/tools","started":1794414394.794107,"pid":99714},"dump":{"seq":2,"time":1794414394.796739,"kind":"dump","file":"/Users/tim/Sites/tools/plain.php","line":7,"label":"1","text":"\"first\"","tree":"{\"kind\":\"string\",\"value\":\"first\"}","truncated":false}}"#,
        #"{"v":1,"type":"dump","request":{"kind":"command","command":"php /Users/tim/Sites/tools/plain.php","cwd":"/Users/tim/Sites/tools","id":"7fc34bcf0060","root":"/Users/tim/Sites/tools","started":1794414394.794107,"pid":99714},"dump":{"seq":3,"time":1794414394.79677,"kind":"dump","file":"/Users/tim/Sites/tools/plain.php","line":7,"label":"2","text":"\"second\"","tree":"{\"kind\":\"string\",\"value\":\"second\"}","truncated":false}}"#,
    ]

    static let commandEnd = #"{"v":1,"type":"end","request":{"kind":"command","command":"php /Users/tim/Sites/tools/plain.php","cwd":"/Users/tim/Sites/tools","id":"7fc34bcf0060","root":"/Users/tim/Sites/tools","started":1794414394.794107,"pid":99714},"status":null,"exit":null,"duration":0.002691}"#

    static let commandDD = #"{"v":1,"type":"dump","request":{"kind":"command","command":"php /Users/tim/Sites/tools/stop.php","cwd":"/Users/tim/Sites/tools","id":"cc870a6df341","root":"/Users/tim/Sites/tools","started":1794414395.251498,"pid":99715},"dump":{"seq":1,"time":1794414395.252351,"kind":"dd","file":"/Users/tim/Sites/tools/stop.php","line":5,"label":null,"text":"\"stop here\"","tree":"{\"kind\":\"string\",\"value\":\"stop here\"}","truncated":false}}"#

    static let commandDDEnd = #"{"v":1,"type":"end","request":{"kind":"command","command":"php /Users/tim/Sites/tools/stop.php","cwd":"/Users/tim/Sites/tools","id":"cc870a6df341","root":"/Users/tim/Sites/tools","started":1794414395.251498,"pid":99715},"status":null,"exit":1,"duration":0.003211}"#

    static let pageDumps = [
        #"{"v":1,"type":"dump","request":{"kind":"http","method":"GET","url":"http://127.0.0.1:18431/index.php?action=twice","host":"127.0.0.1","id":"18cffb9d2606","root":"/Users/tim/Sites/shop/public","started":1794414396.2198,"pid":99716},"dump":{"seq":1,"time":1794414396.222081,"kind":"dump","file":"/Users/tim/Sites/shop/public/index.php","line":25,"label":"1","text":"array:1 [\n  \"order\" => 7\n]","tree":"{\"kind\":\"array\",\"count\":1,\"children\":[{\"key\":\"order\",\"kind\":\"int\",\"value\":\"7\"}]}","truncated":false}}"#,
        #"{"v":1,"type":"dump","request":{"kind":"http","method":"GET","url":"http://127.0.0.1:18431/index.php?action=twice","host":"127.0.0.1","id":"18cffb9d2606","root":"/Users/tim/Sites/shop/public","started":1794414396.2198,"pid":99716},"dump":{"seq":2,"time":1794414396.226077,"kind":"dump","file":"/Users/tim/Sites/shop/public/index.php","line":25,"label":"2","text":"array:1 [\n  \"order\" => 8\n]","tree":"{\"kind\":\"array\",\"count\":1,\"children\":[{\"key\":\"order\",\"kind\":\"int\",\"value\":\"8\"}]}","truncated":false}}"#,
        #"{"v":1,"type":"dump","request":{"kind":"http","method":"GET","url":"http://127.0.0.1:18431/index.php?action=twice","host":"127.0.0.1","id":"18cffb9d2606","root":"/Users/tim/Sites/shop/public","started":1794414396.2198,"pid":99716},"dump":{"seq":3,"time":1794414396.22611,"kind":"dump","file":"/Users/tim/Sites/shop/public/index.php","line":26,"label":null,"text":"array:1 [\n  \"order\" => 9\n]","tree":"{\"kind\":\"array\",\"count\":1,\"children\":[{\"key\":\"order\",\"kind\":\"int\",\"value\":\"9\"}]}","truncated":false}}"#,
    ]

    static let pageEnd = #"{"v":1,"type":"end","request":{"kind":"http","method":"GET","url":"http://127.0.0.1:18431/index.php?action=twice","host":"127.0.0.1","id":"18cffb9d2606","root":"/Users/tim/Sites/shop/public","started":1794414396.2198,"pid":99716},"status":200,"exit":null,"duration":0.006379}"#

    static let pageDD = #"{"v":1,"type":"dump","request":{"kind":"http","method":"GET","url":"http://127.0.0.1:18431/index.php?action=dd","host":"127.0.0.1","id":"cf20f53412b7","root":"/Users/tim/Sites/shop/public","started":1794414396.544055,"pid":99716},"dump":{"seq":1,"time":1794414396.544295,"kind":"dd","file":"/Users/tim/Sites/shop/public/index.php","line":17,"label":null,"text":"array:1 [\n  \"order\" => 7\n]","tree":"{\"kind\":\"array\",\"count\":1,\"children\":[{\"key\":\"order\",\"kind\":\"int\",\"value\":\"7\"}]}","truncated":false}}"#

    static let pageDDEnd = #"{"v":1,"type":"end","request":{"kind":"http","method":"GET","url":"http://127.0.0.1:18431/index.php?action=dd","host":"127.0.0.1","id":"cf20f53412b7","root":"/Users/tim/Sites/shop/public","started":1794414396.544055,"pid":99716},"status":500,"exit":null,"duration":0.000451}"#

    static let blocked = #"{"v":1,"type":"blocked","request":{"kind":"http","method":"GET","url":"http://127.0.0.1:18431/index.php?format=server","host":"127.0.0.1","id":"82eace4a90f6","root":"/Users/tim/Sites/shop/public","started":1794414396.866212,"pid":99716},"reason":"var_dumper_format","detail":"server"}"#

    static var all: [String] {
        commandDumps + [commandEnd, commandDD, commandDDEnd] + pageDumps + [pageEnd, pageDD, pageDDEnd, blocked]
    }

    static func events(_ lines: [String]) throws -> [DumpEvent] {
        try lines.map { line in try DumpLine.decode(Data(line.utf8)) }
    }
}
