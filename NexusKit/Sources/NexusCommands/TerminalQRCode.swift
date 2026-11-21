import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

// The QR code of a link for nexus share (group 4, 4b). Two rows of modules go into one line of text
// with the characters of half blocks. A block is a dark module. The code has a quiet zone of 2
// modules. nexus share prints the lines black on white. So the code reads also in a dark terminal.
enum TerminalQRCode {
    static let quietZone = 2

    static func lines(for text: String) -> [String] {
        let modules = modules(for: text)

        guard !modules.isEmpty else {
            return []
        }

        let size = modules.count + 2 * quietZone
        let isDark = { (column: Int, row: Int) -> Bool in
            let y = row - quietZone
            let x = column - quietZone
            return modules.indices.contains(y) && modules[y].indices.contains(x) && modules[y][x]
        }

        return stride(from: 0, to: size, by: 2).map { row in
            String((0..<size).map { column -> Character in
                switch (isDark(column, row), isDark(column, row + 1)) {
                case (true, true): "\u{2588}"
                case (true, false): "\u{2580}"
                case (false, true): "\u{2584}"
                case (false, false): " "
                }
            })
        }
    }

    // The dark modules row by row from the top. CoreImage gives one pixel for each module and a
    // margin of light modules. The margin goes. A bitmap of CoreImage starts with the top row.
    static func modules(for text: String) -> [[Bool]] {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"

        guard let image = filter.outputImage else {
            return []
        }

        let extent = image.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)

        guard width > 0, height > 0 else {
            return []
        }

        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        context.render(image, toBitmap: &pixels, rowBytes: width * 4, bounds: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

        let all = (0..<height).map { row in
            (0..<width).map { column in pixels[(row * width + column) * 4] < 128 }
        }

        let rows = all.indices.filter { all[$0].contains(true) }
        let columns = (0..<width).filter { column in all.contains { $0[column] } }

        guard let top = rows.first, let bottom = rows.last, let left = columns.first, let right = columns.last else {
            return []
        }

        return all[top...bottom].map { Array($0[left...right]) }
    }
}
