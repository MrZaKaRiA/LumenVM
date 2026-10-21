import Foundation

/// Host injection uses physical US key positions, not Unicode text input.
public enum GuestKeyboard {
    public static func supports(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { (32...126).contains($0.value) }
    }

    public static func key(for char: Character) -> (keyCode: UInt16, shift: Bool) {
        switch char {
        case "a": return (0, false); case "A": return (0, true)
        case "s": return (1, false); case "S": return (1, true)
        case "d": return (2, false); case "D": return (2, true)
        case "f": return (3, false); case "F": return (3, true)
        case "h": return (4, false); case "H": return (4, true)
        case "g": return (5, false); case "G": return (5, true)
        case "z": return (6, false); case "Z": return (6, true)
        case "x": return (7, false); case "X": return (7, true)
        case "c": return (8, false); case "C": return (8, true)
        case "v": return (9, false); case "V": return (9, true)
        case "b": return (11, false); case "B": return (11, true)
        case "q": return (12, false); case "Q": return (12, true)
        case "w": return (13, false); case "W": return (13, true)
        case "e": return (14, false); case "E": return (14, true)
        case "r": return (15, false); case "R": return (15, true)
        case "y": return (16, false); case "Y": return (16, true)
        case "t": return (17, false); case "T": return (17, true)
        case "1": return (18, false); case "!": return (18, true)
        case "2": return (19, false); case "@": return (19, true)
        case "3": return (20, false); case "#": return (20, true)
        case "4": return (21, false); case "$": return (21, true)
        case "6": return (22, false); case "^": return (22, true)
        case "5": return (23, false); case "%": return (23, true)
        case "=": return (24, false); case "+": return (24, true)
        case "9": return (25, false); case "(": return (25, true)
        case "7": return (26, false); case "&": return (26, true)
        case "-": return (27, false); case "_": return (27, true)
        case "8": return (28, false); case "*": return (28, true)
        case "0": return (29, false); case ")": return (29, true)
        case "]": return (30, false); case "}": return (30, true)
        case "o": return (31, false); case "O": return (31, true)
        case "u": return (32, false); case "U": return (32, true)
        case "[": return (33, false); case "{": return (33, true)
        case "i": return (34, false); case "I": return (34, true)
        case "p": return (35, false); case "P": return (35, true)
        case "l": return (37, false); case "L": return (37, true)
        case "j": return (38, false); case "J": return (38, true)
        case "'": return (39, false); case "\"": return (39, true)
        case "k": return (40, false); case "K": return (40, true)
        case ";": return (41, false); case ":": return (41, true)
        case "\\": return (42, false); case "|": return (42, true)
        case ",": return (43, false); case "<": return (43, true)
        case "/": return (44, false); case "?": return (44, true)
        case "n": return (45, false); case "N": return (45, true)
        case "m": return (46, false); case "M": return (46, true)
        case ".": return (47, false); case ">": return (47, true)
        case "`": return (50, false); case "~": return (50, true)
        case " ": return (49, false)
        case "\t": return (48, false)
        case "\n", "\r": return (36, false)
        default: preconditionFailure("Unsupported guest keyboard character")
        }
    }
}
