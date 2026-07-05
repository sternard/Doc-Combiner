import DocCombinerCore
import Foundation

struct CLIOptions {
    var sourceURLs: [URL] = []
    var destinationURL: URL?
    var insertPageBreaks = true
}

enum CLIError: Error, LocalizedError {
    case usage
    case missingOutputPath

    var errorDescription: String? {
        switch self {
        case .usage:
            return usageText
        case .missingOutputPath:
            return "--output needs a file path."
        }
    }
}

let usageText = """
Usage: doc-combiner <input.docx> <input.docx> [...] [--output Combined.docx] [--no-page-breaks]
"""

func parseArguments(_ arguments: [String]) throws -> CLIOptions {
    var options = CLIOptions()
    var index = 0

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "-h", "--help":
            throw CLIError.usage
        case "-o", "--output":
            let nextIndex = index + 1
            guard nextIndex < arguments.count else {
                throw CLIError.missingOutputPath
            }
            options.destinationURL = URL(fileURLWithPath: arguments[nextIndex]).standardizedFileURL
            index += 2
        case "--no-page-breaks":
            options.insertPageBreaks = false
            index += 1
        default:
            options.sourceURLs.append(URL(fileURLWithPath: argument).standardizedFileURL)
            index += 1
        }
    }

    guard options.sourceURLs.count >= 2 else {
        throw CLIError.usage
    }

    return options
}

do {
    let cliOptions = try parseArguments(Array(CommandLine.arguments.dropFirst()))
    let summary = try DocxCombiner().combine(
        cliOptions.sourceURLs,
        destinationURL: cliOptions.destinationURL,
        options: CombinationOptions(insertPageBreaks: cliOptions.insertPageBreaks)
    )

    print("Combined \(summary.sourceURLs.count) documents into \(summary.destinationURL.path)")
} catch CLIError.usage {
    print(usageText)
    exit(0)
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
