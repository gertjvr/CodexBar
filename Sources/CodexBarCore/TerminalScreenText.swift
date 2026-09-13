import Foundation

/// Reconstructs cursor-positioned output before label-based parsing. ConPTY emits cursor movements
/// in place of spaces and newlines; deleting them joins unrelated quota rows.
enum TerminalScreenText {
    static func render(_ text: String, rows: Int = 50, columns: Int = 160) -> String {
        guard text.range(of: #"\u001B\[[0-9]+;[0-9]+[Hf]"#, options: .regularExpression) != nil else {
            return text
        }
        var screen = Screen(rows: rows, columns: columns)
        let input = Array(text)
        var index = 0
        while index < input.count {
            let character = input[index]
            index += 1
            if character == "\u{1B}", index < input.count {
                screen.escape(input, index: &index)
            } else {
                screen.write(character)
            }
        }
        return screen.cells.map { String($0).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }

    private struct Screen {
        let height: Int
        let width: Int
        let blank: [Character]
        var cells: [[Character]]
        var row = 0
        var column = 0
        var savedRow = 0
        var savedColumn = 0

        init(rows: Int, columns: Int) {
            self.height = max(1, min(rows, 256))
            self.width = max(1, min(columns, 512))
            self.blank = [Character](repeating: " ", count: self.width)
            self.cells = [[Character]](repeating: self.blank, count: self.height)
        }

        mutating func lineFeed() {
            self.row += 1
            if self.row >= self.height {
                self.cells.removeFirst()
                self.cells.append(self.blank)
                self.row = self.height - 1
            }
        }

        mutating func write(_ character: Character) {
            switch character {
            case "\r": self.column = 0
            case "\n": self.lineFeed()
            case "\r\n": self.column = 0; self.lineFeed()
            case "\t": self.column = min(self.width - 1, (self.column / 8 + 1) * 8)
            case "\u{8}": self.column = max(0, self.column - 1)
            default:
                guard character.unicodeScalars.first?.value ?? 0 >= 32 else { return }
                if self.column >= self.width { self.column = 0; self.lineFeed() }
                self.cells[self.row][self.column] = character
                self.column += 1
            }
        }

        mutating func escape(_ input: [Character], index: inout Int) {
            let kind = input[index]
            index += 1
            if kind == "[" {
                var parameters = ""
                while index < input.count, !("@"..."~").contains(input[index]) {
                    parameters.append(input[index]); index += 1
                }
                guard index < input.count else { return }
                let command = input[index]
                index += 1
                self.column = min(self.column, self.width - 1)
                let values = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
                if !self.move(command, values: values) { self.edit(command, values: values) }
            } else if kind == "]" {
                Self.skipOperatingSystemCommand(input, index: &index)
            } else if kind == "7" {
                self.saveCursor()
            } else if kind == "8" {
                self.restoreCursor()
            }
        }

        private static func skipOperatingSystemCommand(_ input: [Character], index: inout Int) {
            while index < input.count {
                if input[index] == "\u{7}" { index += 1; return }
                if input[index] == "\u{1B}", index + 1 < input.count, input[index + 1] == "\\" {
                    index += 2
                    return
                }
                index += 1
            }
        }

        private mutating func move(_ command: Character, values: [Int]) -> Bool {
            let count = max(1, min(values.first ?? 1, 512))
            switch command {
            case "H", "f":
                self.row = max(1, min(self.height, values.first ?? 1)) - 1
                self.column = max(1, min(self.width, values.count > 1 ? values[1] : 1)) - 1
            case "A": self.row = max(0, self.row - count)
            case "B": self.row = min(self.height - 1, self.row + count)
            case "C", "a": self.column = min(self.width - 1, self.column + count)
            case "D": self.column = max(0, self.column - count)
            case "E": self.row = min(self.height - 1, self.row + count); self.column = 0
            case "F": self.row = max(0, self.row - count); self.column = 0
            case "G", "`": self.column = min(self.width - 1, count - 1)
            case "d": self.row = min(self.height - 1, count - 1)
            case "s": self.saveCursor()
            case "u": self.restoreCursor()
            default: return false
            }
            return true
        }

        private mutating func edit(_ command: Character, values: [Int]) {
            let mode = values.first ?? 0
            switch command {
            case "J": self.eraseDisplay(mode: mode)
            case "K":
                let start = mode == 0 ? self.column : 0
                let end = mode == 1 ? self.column + 1 : self.width
                for x in start..<end {
                    self.cells[self.row][x] = " "
                }
            case "X":
                let end = min(self.width, self.column + max(1, min(mode, 512)))
                for x in self.column..<end {
                    self.cells[self.row][x] = " "
                }
            default: break
            }
        }

        private mutating func eraseDisplay(mode: Int) {
            if mode == 2 || mode == 3 {
                self.cells = [[Character]](repeating: self.blank, count: self.height)
            } else if mode == 1 {
                for y in 0...self.row {
                    for x in 0..<(y == self.row ? self.column + 1 : self.width) {
                        self.cells[y][x] = " "
                    }
                }
            } else {
                for y in self.row..<self.height {
                    for x in (y == self.row ? self.column : 0)..<self.width {
                        self.cells[y][x] = " "
                    }
                }
            }
        }

        private mutating func saveCursor() {
            self.savedRow = self.row
            self.savedColumn = min(self.column, self.width - 1)
        }

        private mutating func restoreCursor() {
            self.row = self.savedRow
            self.column = self.savedColumn
        }
    }
}
