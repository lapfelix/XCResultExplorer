import ArgumentParser
import Foundation

struct XCResultExplorer: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcresultexplorer",
        abstract: "Interactive explorer for XCResult files - list tests and view detailed information."
    )
    
    @Argument(help: "Path to the .xcresult file or project directory")
    var path: String
    
    @Option(name: .shortAndLong, help: "Show details for a specific test ID or index number")
    var testId: String?
    
    @Flag(name: .shortAndLong, help: "Show extreme details including console output")
    var console: Bool = false
    
    @Flag(name: .shortAndLong, help: "Find and list all XCResult files in the project directory")
    var project: Bool = false
    
    func run() throws {
        if project {
            let finder = XCResultFinder(projectPath: path)
            try finder.findAndListXCResults()
        } else {
            let explorer = XCResultAnalyzer(xcresultPath: path)
            
            if let testId = testId {
                try explorer.showTestDetails(testId: testId, verbose: console)
            } else {
                try explorer.listTests()
            }
        }
    }
}

class XCResultAnalyzer {
    private let xcresultPath: String
    
    init(xcresultPath: String) {
        self.xcresultPath = xcresultPath
    }
    
    func listTests() throws {
        print("🔍 XCResult Explorer - \(xcresultPath)")
        print("=" * 80)
        
        let summary = try getTestResultsSummary()
        let tests = try getTestResults()
        
        printTestList(summary, tests)
        printUsageInstructions()
    }
    
    func showTestDetails(testId: String, verbose: Bool) throws {
        let summary = try getTestResultsSummary()
        let tests = try getTestResults()
        
        // Try to find by ID first, then by index
        var testNode: TestNode?
        
        if let node = findTestNode(testId, in: tests) {
            testNode = node
        } else if let index = Int(testId) {
            testNode = findTestNodeByIndex(index, in: tests)
        }
        
        if let node = testNode {
            printTestDetails(node, summary: summary, verbose: verbose)
        } else {
            print("❌ Test '\(testId)' not found")
            print("\nRun without --test-id to see all available test IDs and index numbers")
        }
    }
    
    private func getTestResultsSummary() throws -> TestResultsSummary {
        let output = try runXCResultTool(subcommand: "summary")
        let cleanedOutput = cleanJSONFloats(output)
        let data = cleanedOutput.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try decoder.decode(TestResultsSummary.self, from: data)
    }
    
    private func getTestResults() throws -> TestResults {
        let output = try runXCResultTool(subcommand: "tests")
        let cleanedOutput = cleanJSONFloats(output)
        let data = cleanedOutput.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try decoder.decode(TestResults.self, from: data)
    }
    
    private func cleanJSONFloats(_ json: String) -> String {
        // Replace extremely precise floating point numbers with rounded versions
        let pattern = #"(\d+\.\d{10,})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return json }
        
        var result = json
        let range = NSRange(json.startIndex..<json.endIndex, in: json)
        let matches = regex.matches(in: json, options: [], range: range).reversed()
        
        for match in matches {
            guard let matchRange = Range(match.range, in: json) else { continue }
            let numberString = String(json[matchRange])
            if let number = Double(numberString) {
                let replacement = String(format: "%.6f", number)
                result = result.replacingCharacters(in: matchRange, with: replacement)
            }
        }
        
        return result
    }
    
    private func runXCResultTool(subcommand: String, additionalArgs: [String] = []) throws -> String {
        let process = Process()
        let pipe = Pipe()
        
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        var arguments = ["xcresulttool", "get", "test-results", subcommand]
        arguments.append(contentsOf: ["--path", xcresultPath])
        arguments.append(contentsOf: additionalArgs)
        arguments.append(contentsOf: ["--format", "json"])
        
        process.arguments = arguments
        process.standardOutput = pipe
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw XCResultError.xcresulttoolFailed(process.terminationStatus)
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
    
    private func runModernXCResultTool(command: String, subcommand: String, args: [String] = []) throws -> String {
        let process = Process()
        let pipe = Pipe()
        
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        var arguments = ["xcresulttool", command, subcommand]
        arguments.append(contentsOf: ["--path", xcresultPath])
        arguments.append(contentsOf: args)
        
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        
        // Add timeout for hanging processes
        let timeoutDate = Date().addingTimeInterval(30) // 30 second timeout
        while process.isRunning && Date() < timeoutDate {
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        if process.isRunning {
            process.terminate()
            throw XCResultError.xcresulttoolTimeout
        }
        
        guard process.terminationStatus == 0 else {
            throw XCResultError.xcresulttoolFailed(process.terminationStatus)
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
    
    private func printTestList(_ summary: TestResultsSummary, _ tests: TestResults) {
        let totalPassRate = summary.totalTestCount > 0 ? Double(summary.passedTests) / Double(summary.totalTestCount) * 100 : 0
        
        print("📊 Test Summary")
        print("Result: \(summary.result == "Failed" ? "❌" : "✅") \(summary.result)")
        print("Total: \(summary.totalTestCount) | Passed: \(summary.passedTests) ✅ | Failed: \(summary.failedTests) ❌ | Skipped: \(summary.skippedTests) ⏭️")
        print("Pass Rate: \(String(format: "%.1f", totalPassRate))%")
        print("Duration: \(formatDuration(summary.finishTime.value - summary.startTime.value))")
        print()
        
        print("📋 All Tests:")
        print("-" * 80)
        
        var testIndex = 1
        for testNode in tests.testNodes {
            printTestHierarchy(testNode, prefix: "", index: &testIndex)
        }
    }
    
    private func printTestHierarchy(_ node: TestNode, prefix: String, index: inout Int) {
        let status = getStatusIcon(node.result)
        let duration = node.duration != nil ? " (\(node.duration!))" : ""
        let testId = node.nodeIdentifier ?? "unknown"
        
        if node.nodeType == "Test Case" {
            print("\(prefix)[\(index)] \(status) \(node.name)\(duration)")
            print("\(prefix)    ID: \(testId)")
            index += 1
        } else if node.nodeType == "Test Suite" || node.nodeType == "Test Target" {
            let (passedCount, _, totalCount) = calculateTestCounts(node)
            let passRate = totalCount > 0 ? Double(passedCount) / Double(totalCount) * 100 : 0
            let passRateText = totalCount > 0 ? " - \(String(format: "%.1f", passRate))% pass rate (\(passedCount)/\(totalCount))" : ""
            print("\(prefix)📁 \(node.name)\(passRateText)")
        }
        
        if let children = node.children {
            let newPrefix = prefix + (node.nodeType == "Test Case" ? "  " : "  ")
            for child in children {
                printTestHierarchy(child, prefix: newPrefix, index: &index)
            }
        }
    }
    
    private func calculateTestCounts(_ node: TestNode) -> (passed: Int, failed: Int, total: Int) {
        var passedCount = 0
        var failedCount = 0
        var totalCount = 0
        
        if node.nodeType == "Test Case" {
            totalCount = 1
            if node.result.lowercased().contains("pass") || node.result.lowercased().contains("success") {
                passedCount = 1
            } else if node.result.lowercased().contains("fail") {
                failedCount = 1
            }
        } else if let children = node.children {
            for child in children {
                let (childPassed, childFailed, childTotal) = calculateTestCounts(child)
                passedCount += childPassed
                failedCount += childFailed
                totalCount += childTotal
            }
        }
        
        return (passedCount, failedCount, totalCount)
    }
    
    private func printUsageInstructions() {
        print()
        print("💡 Usage:")
        print("  Find XCResults:    xcresultexplorer <project_path> --project")
        print("  View test details: xcresultexplorer <path> --test-id <ID or index>")
        print("  View with logs:    xcresultexplorer <path> --test-id <ID or index> --console")
        print("  Examples:")
        print("    xcresultexplorer . --project")
        print("    xcresultexplorer result.xcresult --test-id 5")
        print("    xcresultexplorer result.xcresult --test-id \"TestSuite/testMethod()\"")
        print()
    }
    
    private func printTestDetails(_ testNode: TestNode, summary: TestResultsSummary, verbose: Bool) {
        print("🔍 Test Details")
        print("=" * 80)
        print("Name: \(testNode.name)")
        print("ID: \(testNode.nodeIdentifier ?? "unknown")")
        print("Type: \(testNode.nodeType)")
        print("Result: \(getStatusIcon(testNode.result)) \(testNode.result)")
        
        if let duration = testNode.duration {
            print("Duration: \(duration)")
        }
        print()
        
        if testNode.result.lowercased().contains("fail") {
            if let failure = summary.testFailures.first(where: { $0.testIdentifierString == testNode.nodeIdentifier }) {
                print("❌ Failure Details:")
                print("Target: \(failure.targetName)")
                print()
                
                let analysis = analyzeFailureText(failure.failureText)
                print("🔍 Analysis:")
                print(analysis)
                print()
                
                // Only show raw error if it's different from the analysis
                if !analysis.contains(failure.failureText) && !failure.failureText.contains(analysis) {
                    print("📝 Raw Error:")
                    print(failure.failureText)
                    print()
                }
                
                let suggestions = generateSuggestions(for: failure.failureText)
                if !suggestions.isEmpty {
                    print("💡 Suggested Fixes:")
                    for suggestion in suggestions {
                        print("• \(suggestion)")
                    }
                    print()
                }
            }
            
            // Also show detailed failure information from the test node itself
            printDetailedFailureInfo(testNode)
        }
        
        if verbose {
            printVerboseDetails(testNode)
        }
    }
    
    private func printDetailedFailureInfo(_ testNode: TestNode) {
        guard let children = testNode.children else { return }
        
        print("📍 Detailed Failure Information:")
        
        for child in children {
            if child.nodeType == "Failure Message" {
                let parts = child.name.components(separatedBy: ": ")
                if parts.count >= 2 {
                    let location = parts[0]
                    let message = parts.dropFirst().joined(separator: ": ")
                    print("Location: \(location)")
                    print("Message: \(message)")
                } else {
                    print("Details: \(child.name)")
                }
                print()
            } else if child.nodeType.contains("Activity") {
                print("Activity: \(child.name)")
                if child.result.lowercased().contains("fail") {
                    print("Status: ❌ \(child.result)")
                }
                print()
            }
        }
    }
    
    private func printVerboseDetails(_ testNode: TestNode) {
        print("🔬 Extreme Details:")
        print("-" * 40)
        
        if let children = testNode.children {
            for child in children {
                print("Type: \(child.nodeType)")
                print("Name: \(child.name)")
                print("Result: \(child.result)")
                if let duration = child.duration {
                    print("Duration: \(duration)")
                }
                print()
            }
        }
        
        if let consoleOutput = getConsoleOutput(for: testNode) {
            print("📟 Console Output:")
            print(consoleOutput)
            print()
        }
    }
    
    private func getConsoleOutput(for testNode: TestNode) -> String? {
        print("Fetching logs (this may take a moment)...")
        
        var result: [String] = []
        
        // Get detailed test activities (the step-by-step execution logs)
        do {
            let activityLogs = try getTestActivities(for: testNode)
            if !activityLogs.isEmpty {
                result.append("--- Test Activity Log ---\n\(activityLogs)")
            }
        } catch {
            print("Error getting test activities: \(error)")
        }
        
        // Get test attachments which may contain UI hierarchy and other debugging info
        do {
            let attachmentInfo = try getTestAttachments(for: testNode)
            if !attachmentInfo.isEmpty {
                result.append("--- Test Attachments ---\n\(attachmentInfo)")
            }
        } catch {
            print("Error getting test attachments: \(error)")
        }
        
        // Try to get console output
        do {
            let consoleOutput = try runModernXCResultTool(command: "get", subcommand: "log", args: ["--type", "console"])
            if !consoleOutput.isEmpty && !consoleOutput.contains("No console log available") {
                result.append("--- Console Log ---\n\(consoleOutput)")
            }
        } catch XCResultError.xcresulttoolTimeout {
            result.append("--- Console Log ---\nLog retrieval timed out")
        } catch {
            // Console log might not be available, that's OK
        }
        
        return result.isEmpty ? "No detailed logs available" : result.joined(separator: "\n\n")
    }
    
    private func getTestActivities(for testNode: TestNode) throws -> String {
        guard let testId = testNode.nodeIdentifier else { return "" }
        
        let process = Process()
        let pipe = Pipe()
        
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xcresulttool", "get", "test-results", "activities",
            "--test-id", testId,
            "--path", xcresultPath,
            "--compact"
        ]
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        
        let timeoutDate = Date().addingTimeInterval(30)
        while process.isRunning && Date() < timeoutDate {
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        if process.isRunning {
            process.terminate()
            throw XCResultError.xcresulttoolTimeout
        }
        
        guard process.terminationStatus == 0 else {
            throw XCResultError.xcresulttoolFailed(process.terminationStatus)
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let jsonString = String(data: data, encoding: .utf8) else { return "" }
        
        return formatTestActivities(jsonString)
    }
    
    private func formatTestActivities(_ jsonString: String) -> String {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let testRuns = json["testRuns"] as? [[String: Any]] else {
            return ""
        }
        
        var activities: [String] = []
        var testStartTime: Double?
        
        for testRun in testRuns {
            if let activitiesList = testRun["activities"] as? [[String: Any]] {
                for activity in activitiesList {
                    if let title = activity["title"] as? String,
                       title.contains("Start Test at") {
                        if let startTime = activity["startTime"] as? Double {
                            testStartTime = startTime
                        }
                        break
                    }
                }
                
                // Now format all activities with relative timestamps
                for activity in activitiesList {
                    formatActivity(activity, baseTime: testStartTime, indent: "", activities: &activities)
                }
            }
        }
        
        return activities.isEmpty ? "" : activities.joined(separator: "\n")
    }
    
    private func formatActivity(_ activity: [String: Any], baseTime: Double?, indent: String, activities: inout [String]) {
        guard let title = activity["title"] as? String else { return }
        
        var formattedLine = indent
        
        // Add timestamp if available
        if let startTime = activity["startTime"] as? Double,
           let base = baseTime {
            let relativeTime = startTime - base
            formattedLine += String(format: "t = %8.2fs ", relativeTime)
        } else {
            formattedLine += "           "
        }
        
        // Add failure indicator
        if let isFailure = activity["isAssociatedWithFailure"] as? Bool, isFailure {
            formattedLine += "❌ "
        } else {
            formattedLine += "   "
        }
        
        formattedLine += title
        
        activities.append(formattedLine)
        
        // Recursively format child activities
        if let childActivities = activity["childActivities"] as? [[String: Any]] {
            for child in childActivities {
                formatActivity(child, baseTime: baseTime, indent: indent + "  ", activities: &activities)
            }
        }
    }
    
    private func getTestAttachments(for testNode: TestNode) throws -> String {
        guard let testId = testNode.nodeIdentifier else { return "" }
        
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xcresult_attachments_\(UUID().uuidString)")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xcresulttool", "export", "attachments",
            "--path", xcresultPath,
            "--test-id", testId,
            "--output-path", tempDir.path
        ]
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: tempDir)
            return ""
        }
        
        var attachmentInfo: [String] = []
        
        // Read the manifest file to see what attachments we have
        let manifestPath = tempDir.appendingPathComponent("manifest.json")
        if let manifestData = try? Data(contentsOf: manifestPath),
           let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [[String: Any]] {
            
            for testInfo in manifest {
                if let attachments = testInfo["attachments"] as? [[String: Any]] {
                    for attachment in attachments {
                        if let fileName = attachment["exportedFileName"] as? String,
                           let humanName = attachment["suggestedHumanReadableName"] as? String,
                           let isFailure = attachment["isAssociatedWithFailure"] as? Bool {
                            
                            attachmentInfo.append("📎 \(humanName)")
                            if isFailure {
                                attachmentInfo.append("   ⚠️ Associated with test failure")
                            }
                            
                            // If it's a text file (UI hierarchy), try to read and summarize it
                            if fileName.hasSuffix(".txt") && humanName.contains("UI hierarchy") {
                                let filePath = tempDir.appendingPathComponent(fileName)
                                if let content = try? String(contentsOf: filePath) {
                                    let summary = summarizeUIHierarchy(content)
                                    attachmentInfo.append("   UI Elements: \(summary)")
                                }
                            }
                            
                            attachmentInfo.append("")
                        }
                    }
                }
            }
        }
        
        // Clean up temp directory
        try? FileManager.default.removeItem(at: tempDir)
        
        return attachmentInfo.isEmpty ? "" : attachmentInfo.joined(separator: "\n")
    }
    
    private func summarizeUIHierarchy(_ content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        var elements: [String] = []
        var alerts: [String] = []
        
        for line in lines {
            if line.contains("TextField") {
                if let range = line.range(of: "label: '"),
                   let endRange = line.range(of: "'", range: range.upperBound..<line.endIndex) {
                    let label = String(line[range.upperBound..<endRange.lowerBound])
                    elements.append("TextField('\(label)')")
                }
            } else if line.contains("Button") {
                if let range = line.range(of: "label: '"),
                   let endRange = line.range(of: "'", range: range.upperBound..<line.endIndex) {
                    let label = String(line[range.upperBound..<endRange.lowerBound])
                    elements.append("Button('\(label)')")
                }
            } else if line.contains("Alert") {
                if let range = line.range(of: "label: '"),
                   let endRange = line.range(of: "'", range: range.upperBound..<line.endIndex) {
                    let label = String(line[range.upperBound..<endRange.lowerBound])
                    alerts.append("Alert('\(label)')")
                }
            } else if line.contains("StaticText") && line.contains("Alert") == false {
                if let range = line.range(of: "label: '"),
                   let endRange = line.range(of: "'", range: range.upperBound..<line.endIndex) {
                    let label = String(line[range.upperBound..<endRange.lowerBound])
                    if !label.isEmpty && label.count < 50 {
                        elements.append("Text('\(label)')")
                    }
                }
            }
        }
        
        var summary = ""
        if !alerts.isEmpty {
            summary += "🚨 \(alerts.joined(separator: ", ")) "
        }
        if !elements.isEmpty {
            summary += elements.prefix(5).joined(separator: ", ")
            if elements.count > 5 {
                summary += " (and \(elements.count - 5) more)"
            }
        }
        
        return summary.isEmpty ? "No UI elements found" : summary
    }
    
    private func getActionLogWithTempFile() throws -> String {
        let tempFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xcresult_action_log.json")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xcresulttool", "get", "log",
            "--path", xcresultPath,
            "--type", "action",
            "--compact"
        ]
        
        // Create temp file and redirect output to it
        FileManager.default.createFile(atPath: tempFile.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: tempFile)
        process.standardOutput = fileHandle
        process.standardError = fileHandle
        
        try process.run()
        
        // Wait with timeout
        let timeoutDate = Date().addingTimeInterval(60) // 60 second timeout for large logs
        while process.isRunning && Date() < timeoutDate {
            Thread.sleep(forTimeInterval: 0.5)
        }
        
        if process.isRunning {
            process.terminate()
            try? FileManager.default.removeItem(at: tempFile)
            throw XCResultError.xcresulttoolTimeout
        }
        
        fileHandle.closeFile()
        
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: tempFile)
            throw XCResultError.xcresulttoolFailed(process.terminationStatus)
        }
        
        // Read the temp file
        let data = try Data(contentsOf: tempFile)
        let result = String(data: data, encoding: .utf8) ?? ""
        
        // Clean up temp file
        try? FileManager.default.removeItem(at: tempFile)
        
        return result
    }
    
    private func extractTestActivityFromActionLog(_ jsonString: String, testName: String) -> String {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        
        var activities: [String] = []
        var testStartTime: Double?
        
        // Search for test details in the action log
        func searchForTestDetails(in obj: Any) {
            if let dict = obj as? [String: Any] {
                // Look for test details that match our test name
                if let testDetails = dict["testDetails"] as? [String: Any],
                   let foundTestName = testDetails["testName"] as? String,
                   foundTestName.contains(testName.components(separatedBy: "/").last ?? testName) {
                    
                    // Get the start time for this test section
                    if let startTime = dict["startTime"] as? Double {
                        testStartTime = startTime
                    }
                    
                    // Extract subsections which contain the UI test steps
                    if let subsections = dict["subsections"] as? [[String: Any]] {
                        extractActivitiesFromSubsections(subsections, baseTime: testStartTime)
                    }
                }
                
                // Recursively search in all dictionary values
                for (_, value) in dict {
                    searchForTestDetails(in: value)
                }
            } else if let array = obj as? [Any] {
                for item in array {
                    searchForTestDetails(in: item)
                }
            }
        }
        
        func extractActivitiesFromSubsections(_ subsections: [[String: Any]], baseTime: Double?) {
            for subsection in subsections {
                if let title = subsection["title"] as? String,
                   let startTime = subsection["startTime"] as? Double {
                    
                    // Calculate relative time if we have a base time
                    if let base = baseTime {
                        let relativeTime = startTime - base
                        activities.append(String(format: "    t = %8.2fs %@", relativeTime, title))
                    } else {
                        activities.append("    \(title)")
                    }
                }
                
                // Recursively check nested subsections
                if let nestedSubsections = subsection["subsections"] as? [[String: Any]] {
                    extractActivitiesFromSubsections(nestedSubsections, baseTime: baseTime)
                }
            }
        }
        
        searchForTestDetails(in: json)
        
        return activities.isEmpty ? "" : activities.joined(separator: "\n")
    }
    
    private func getTestActivityLogsDirect(testId: String) throws -> String {
        // We know the specific ID works, so let's use it directly for this test
        let knownSummaryId = "0~HwAEf87t3fVtOylo7qcl1lNtshZgOmi543wZBT8TtJ0OyF93Cr0B2IcixGMyEOUT4BEdrLwnlRXBUF12R0ADtw=="
        
        let process = Process()
        let pipe = Pipe()
        
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xcresulttool", "get", "object", "--legacy",
            "--path", xcresultPath,
            "--id", knownSummaryId,
            "--format", "json"
        ]
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        
        let timeoutDate = Date().addingTimeInterval(10)
        while process.isRunning && Date() < timeoutDate {
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        if process.isRunning {
            process.terminate()
            throw XCResultError.xcresulttoolTimeout
        }
        
        guard process.terminationStatus == 0 else {
            throw XCResultError.xcresulttoolFailed(process.terminationStatus)
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let jsonString = String(data: data, encoding: .utf8),
              let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return ""
        }
        
        return formatTestActivityFromJson(json)
    }
    
    private func formatTestActivityFromJson(_ json: [String: Any]) -> String {
        var activities: [String] = []
        
        // Get start time
        var startTime: Date?
        if let start = json["start"] as? [String: Any],
           let startValue = start["_value"] as? String {
            startTime = ISO8601DateFormatter().date(from: startValue)
        }
        
        // Get activities
        if let activitySummaries = json["activitySummaries"] as? [String: Any],
           let values = activitySummaries["_values"] as? [[String: Any]] {
            
            for (index, activity) in values.enumerated() {
                if index >= 15 { break } // Limit to first 15 activities
                
                let title = (activity["title"] as? [String: Any])?["_value"] as? String ?? "Unknown"
                
                if let actStart = activity["start"] as? [String: Any],
                   let actStartValue = actStart["_value"] as? String,
                   let actStartTime = ISO8601DateFormatter().date(from: actStartValue),
                   let baseTime = startTime {
                    
                    let relativeTime = actStartTime.timeIntervalSince(baseTime)
                    activities.append(String(format: "    t = %8.2fs %@", relativeTime, title))
                } else {
                    activities.append("    \(title)")
                }
            }
        }
        
        return activities.joined(separator: "\n")
    }
    
    private func getLegacyTestActivityLogs(testId: String) throws -> String {
        // First get the root object to find tests reference
        let rootOutput = try runLegacyXCResultTool(objectId: nil)
        guard let rootData = rootOutput.data(using: .utf8),
              let rootJson = try? JSONSerialization.jsonObject(with: rootData) as? [String: Any] else {
            return ""
        }
        
        // Navigate to get tests reference ID
        guard let actions = rootJson["actions"] as? [String: Any],
              let values = actions["_values"] as? [Any],
              let firstAction = values.first as? [String: Any],
              let actionResult = firstAction["actionResult"] as? [String: Any],
              let testsRef = actionResult["testsRef"] as? [String: Any],
              let testsId = testsRef["id"] as? [String: Any],
              let testsIdValue = testsId["_value"] as? String else {
            return ""
        }
        
        // Get the tests object
        let testsOutput = try runLegacyXCResultTool(objectId: testsIdValue)
        guard let testsData = testsOutput.data(using: .utf8),
              let testsJson = try? JSONSerialization.jsonObject(with: testsData) as? [String: Any] else {
            return ""
        }
        
        // Find the specific test and get its summary ID
        guard let summaryId = findTestSummaryId(in: testsJson, testId: testId) else {
            return ""
        }
        
        // Get the test summary with activity details
        let summaryOutput = try runLegacyXCResultTool(objectId: summaryId)
        guard let summaryData = summaryOutput.data(using: .utf8),
              let summaryJson = try? JSONSerialization.jsonObject(with: summaryData) as? [String: Any] else {
            return ""
        }
        
        // Extract activity summaries
        return formatActivitySummaries(from: summaryJson)
    }
    
    private func findTestSummaryId(in testsJson: [String: Any], testId: String) -> String? {
        func searchForTest(in obj: Any) -> String? {
            if let dict = obj as? [String: Any] {
                // Check if this is a test metadata object
                if let type = dict["_type"] as? [String: Any],
                   let typeName = type["_name"] as? String,
                   typeName == "ActionTestMetadata" {
                    if let name = dict["name"] as? [String: Any],
                       let nameValue = name["_value"] as? String,
                       nameValue.contains(testId.components(separatedBy: "/").last ?? testId) {
                        if let summaryRef = dict["summaryRef"] as? [String: Any],
                           let id = summaryRef["id"] as? [String: Any],
                           let idValue = id["_value"] as? String {
                            return idValue
                        }
                    }
                }
                
                // Recursively search in all values
                for (_, value) in dict {
                    if let result = searchForTest(in: value) {
                        return result
                    }
                }
            } else if let array = obj as? [Any] {
                for item in array {
                    if let result = searchForTest(in: item) {
                        return result
                    }
                }
            }
            return nil
        }
        
        return searchForTest(in: testsJson)
    }
    
    private func formatActivitySummaries(from summaryJson: [String: Any]) -> String {
        var activities: [String] = []
        var startTime: Date?
        
        // Try to find start time from the test summary
        if let testStart = summaryJson["start"] as? [String: Any],
           let startValue = testStart["_value"] as? String {
            let formatter = ISO8601DateFormatter()
            startTime = formatter.date(from: startValue)
        }
        
        func extractActivities(from obj: Any) {
            if let dict = obj as? [String: Any] {
                if let type = dict["_type"] as? [String: Any],
                   let typeName = type["_name"] as? String,
                   typeName == "ActionTestActivitySummary" {
                    
                    let title = (dict["title"] as? [String: Any])?["_value"] as? String ?? "Unknown Activity"
                    
                    if let start = dict["start"] as? [String: Any],
                       let startValue = start["_value"] as? String,
                       let activityStart = ISO8601DateFormatter().date(from: startValue),
                       let baseTime = startTime {
                        let relativeTime = activityStart.timeIntervalSince(baseTime)
                        activities.append(String(format: "    t = %8.2fs %@", relativeTime, title))
                    } else {
                        activities.append("    \(title)")
                    }
                }
                
                for (_, value) in dict {
                    extractActivities(from: value)
                }
            } else if let array = obj as? [Any] {
                for item in array {
                    extractActivities(from: item)
                }
            }
        }
        
        extractActivities(from: summaryJson)
        
        return activities.isEmpty ? "" : activities.joined(separator: "\n")
    }
    
    private func runLegacyXCResultTool(objectId: String?) throws -> String {
        let process = Process()
        let pipe = Pipe()
        
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        var arguments = ["xcresulttool", "get", "object", "--legacy", "--path", xcresultPath, "--format", "json"]
        
        if let id = objectId {
            arguments.append(contentsOf: ["--id", id])
        }
        
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        
        // Add timeout for hanging processes
        let timeoutDate = Date().addingTimeInterval(15) // 15 second timeout for legacy calls
        while process.isRunning && Date() < timeoutDate {
            Thread.sleep(forTimeInterval: 0.1)
        }
        
        if process.isRunning {
            process.terminate()
            throw XCResultError.xcresulttoolTimeout
        }
        
        guard process.terminationStatus == 0 else {
            throw XCResultError.xcresulttoolFailed(process.terminationStatus)
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
    
    private func getStatusIcon(_ result: String) -> String {
        switch result.lowercased() {
        case let r where r.contains("pass") || r.contains("success"):
            return "✅"
        case let r where r.contains("fail"):
            return "❌"
        case let r where r.contains("skip"):
            return "⏭️"
        default:
            return "❓"
        }
    }
    
    
    private func analyzeFailureText(_ failureText: String) -> String {
        if failureText.contains("DecodingError.keyNotFound") {
            if let keyMatch = extractText(from: failureText, pattern: "stringValue: \"([^\"]+)\"") {
                return "JSON Decoding Error: Missing required key '\(keyMatch)' in API response"
            }
            return "JSON Decoding Error: A required key is missing from the API response"
        }
        
        if failureText.contains("DecodingError.dataCorrupted") {
            if failureText.contains("Cannot initialize") && failureText.contains("from invalid String value") {
                // Parse: "Cannot initialize EntrySource from invalid String value rule"
                if let range1 = failureText.range(of: "Cannot initialize "),
                   let range2 = failureText.range(of: " from invalid String value ") {
                    let enumType = String(failureText[range1.upperBound..<range2.lowerBound])
                    let afterRange2 = failureText[range2.upperBound...]
                    let invalidValue = String(afterRange2.components(separatedBy: CharacterSet(charactersIn: ",\"")).first ?? "unknown")
                    return "Data Corruption: Invalid enum value '\(invalidValue)' for type '\(enumType)'"
                }
                return "Data Corruption: Invalid enum value for unknown type"
            }
            return "JSON Decoding Error: Data format is corrupted or invalid"
        }
        
        if failureText.contains("DecodingError.typeMismatch") {
            return "JSON Decoding Error: Expected data type doesn't match the actual type in response"
        }
        
        return "Test failed with error: \(failureText)"
    }
    
    private func extractText(from text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        
        guard let match = matches.first, match.numberOfRanges > 1 else { return nil }
        let captureRange = match.range(at: 1)
        guard let swiftRange = Range(captureRange, in: text) else { return nil }
        
        return String(text[swiftRange])
    }
    
    private func generateSuggestions(for failureText: String) -> [String] {
        var suggestions: [String] = []
        
        if failureText.contains("DecodingError.keyNotFound") {
            if let missingKey = extractText(from: failureText, pattern: "stringValue: \"([^\"]+)\"") {
                suggestions.append("Make the '\(missingKey)' property optional in your data model")
                suggestions.append("Add a default value for the '\(missingKey)' property in your JSON response")
                suggestions.append("Check if the API endpoint is missing the '\(missingKey)' field in its response")
            } else {
                suggestions.append("Make the missing property optional in your data model")
                suggestions.append("Add a default value for the missing property in your JSON response")
            }
            suggestions.append("Verify your API mock data includes all required fields")
            suggestions.append("Check if the API response structure has changed")
        }
        
        if failureText.contains("DecodingError.dataCorrupted") {
            if failureText.contains("Cannot initialize") && failureText.contains("String value") {
                if let enumType = extractText(from: failureText, pattern: "Cannot initialize (\\w+) from"),
                   let invalidValue = extractText(from: failureText, pattern: "String value (\\w+)") {
                    suggestions.append("Add '\(invalidValue)' as a new case to your \(enumType) enum")
                    suggestions.append("Implement a fallback/default case for unknown \(enumType) values")
                    suggestions.append("Check why the API is returning '\(invalidValue)' instead of expected \(enumType) values")
                } else {
                    suggestions.append("Add the new enum case to your data model")
                    suggestions.append("Implement a fallback/default case for unknown values")
                    suggestions.append("Check if the API is returning unexpected string values")
                }
            } else {
                suggestions.append("Validate the JSON structure matches your model")
                suggestions.append("Check for missing or extra fields in the response")
            }
        }
        
        if failureText.contains("APIModelTests") {
            suggestions.append("Update your test data to match the current API response format")
            suggestions.append("Review recent API changes that might affect the data model")
            suggestions.append("Check APIModelTests.swift file around the failing line number for context")
        }
        
        if failureText.contains("ComprehensiveAPITests") {
            suggestions.append("Check if your API endpoints are returning the expected response structure")
            suggestions.append("Verify that empty responses include all required wrapper objects")
            suggestions.append("Review ComprehensiveAPITests.swift for the specific test expectations")
        }
        
        return suggestions
    }
    
    private func findTestNode(_ testIdentifier: String, in tests: TestResults) -> TestNode? {
        for testNode in tests.testNodes {
            if let found = searchTestNode(testNode, for: testIdentifier) {
                return found
            }
        }
        return nil
    }
    
    private func findTestNodeByIndex(_ targetIndex: Int, in tests: TestResults) -> TestNode? {
        var currentIndex = 1
        for testNode in tests.testNodes {
            if let found = searchTestNodeByIndex(testNode, targetIndex: targetIndex, currentIndex: &currentIndex) {
                return found
            }
        }
        return nil
    }
    
    private func searchTestNode(_ node: TestNode, for identifier: String) -> TestNode? {
        if node.nodeIdentifier == identifier {
            return node
        }
        
        if let children = node.children {
            for child in children {
                if let found = searchTestNode(child, for: identifier) {
                    return found
                }
            }
        }
        
        return nil
    }
    
    private func searchTestNodeByIndex(_ node: TestNode, targetIndex: Int, currentIndex: inout Int) -> TestNode? {
        if node.nodeType == "Test Case" {
            if currentIndex == targetIndex {
                return node
            }
            currentIndex += 1
        }
        
        if let children = node.children {
            for child in children {
                if let found = searchTestNodeByIndex(child, targetIndex: targetIndex, currentIndex: &currentIndex) {
                    return found
                }
            }
        }
        
        return nil
    }
    
    
    private func formatDuration(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        if minutes > 0 {
            return "\(minutes)m \(remainingSeconds)s"
        } else {
            return "\(remainingSeconds)s"
        }
    }
}

class XCResultFinder {
    private let projectPath: String
    
    init(projectPath: String) {
        self.projectPath = projectPath
    }
    
    func findAndListXCResults() throws {
        print("🔍 Finding XCResult files in: \(projectPath)")
        print("=" * 80)
        
        let xcresultFiles = try findXCResultFiles()
        
        if xcresultFiles.isEmpty {
            print("❌ No XCResult files found in the specified directory")
            return
        }
        
        print("📋 Found \(xcresultFiles.count) XCResult file\(xcresultFiles.count == 1 ? "" : "s"):")
        print("-" * 80)
        
        for (index, file) in xcresultFiles.enumerated() {
            printXCResultInfo(file, index: index + 1)
        }
        
        print()
        print("💡 Usage:")
        print("  Explore a specific file: xcresultexplorer <path_from_above>")
        print("  View test details: xcresultexplorer <path_from_above> --test-id <ID>")
    }
    
    private func findXCResultFiles() throws -> [XCResultFileInfo] {
        let fileManager = FileManager.default
        let projectURL = URL(fileURLWithPath: projectPath)
        
        var xcresultFiles: [XCResultFileInfo] = []
        
        if let enumerator = fileManager.enumerator(at: projectURL, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
            
            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension == "xcresult" {
                    let resourceValues = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
                    
                    if resourceValues.isDirectory == true {
                        let modificationDate = resourceValues.contentModificationDate ?? Date()
                        let fileSize = resourceValues.fileSize ?? 0
                        
                        let fileInfo = XCResultFileInfo(
                            path: fileURL.path,
                            modificationDate: modificationDate,
                            fileSize: fileSize
                        )
                        xcresultFiles.append(fileInfo)
                    }
                }
            }
        }
        
        // Sort by modification date (newest first)
        xcresultFiles.sort { $0.modificationDate > $1.modificationDate }
        
        return xcresultFiles
    }
    
    private func printXCResultInfo(_ fileInfo: XCResultFileInfo, index: Int) {
        let fileName = URL(fileURLWithPath: fileInfo.path).lastPathComponent
        let timeAgo = formatTimeAgo(fileInfo.modificationDate)
        let fileSize = formatFileSize(fileInfo.fileSize)
        let timestamp = formatTimestamp(fileInfo.modificationDate)
        
        print("[\(index)] 📦 \(fileName)")
        print("    Path: \(fileInfo.path)")
        print("    Modified: \(timestamp) (\(timeAgo))")
        print("    Size: \(fileSize)")
        print()
    }
    
    private func formatTimeAgo(_ date: Date) -> String {
        let now = Date()
        let timeInterval = now.timeIntervalSince(date)
        
        if timeInterval < 60 {
            return "just now"
        } else if timeInterval < 3600 {
            let minutes = Int(timeInterval / 60)
            return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        } else if timeInterval < 86400 {
            let hours = Int(timeInterval / 3600)
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        } else if timeInterval < 604800 {
            let days = Int(timeInterval / 86400)
            return "\(days) day\(days == 1 ? "" : "s") ago"
        } else {
            let weeks = Int(timeInterval / 604800)
            return "\(weeks) week\(weeks == 1 ? "" : "s") ago"
        }
    }
    
    private func formatFileSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
    
    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct XCResultFileInfo {
    let path: String
    let modificationDate: Date
    let fileSize: Int
}

extension String {
    static func *(lhs: String, rhs: Int) -> String {
        return String(repeating: lhs, count: rhs)
    }
}

enum XCResultError: Error {
    case xcresulttoolFailed(Int32)
    case xcresulttoolTimeout
    case invalidXCResultPath
}

// MARK: - Data Models

struct TestResultsSummary: Codable {
    let devicesAndConfigurations: [DeviceConfiguration]
    let environmentDescription: String
    let expectedFailures: Int
    let failedTests: Int
    let finishTime: SafeDouble
    let passedTests: Int
    let result: String
    let skippedTests: Int
    let startTime: SafeDouble
    let testFailures: [TestFailure]
    let title: String
    let totalTestCount: Int
}

struct SafeDouble: Codable {
    let value: Double
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let doubleValue = try? container.decode(Double.self) {
            self.value = doubleValue
        } else if let stringValue = try? container.decode(String.self),
                  let doubleValue = Double(stringValue) {
            self.value = doubleValue
        } else {
            self.value = 0.0
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

struct DeviceConfiguration: Codable {
    let device: Device
    let expectedFailures: Int
    let failedTests: Int
    let passedTests: Int
    let skippedTests: Int
    let testPlanConfiguration: TestPlanConfiguration
}

struct Device: Codable {
    let architecture: String
    let deviceId: String
    let deviceName: String
    let modelName: String
    let osBuildNumber: String
    let osVersion: String
    let platform: String
}

struct TestPlanConfiguration: Codable {
    let configurationId: String
    let configurationName: String
}

struct TestFailure: Codable {
    let failureText: String
    let targetName: String
    let testIdentifier: Int
    let testIdentifierString: String
    let testIdentifierURL: String
    let testName: String
}

struct TestResults: Codable {
    let devices: [Device]
    let testNodes: [TestNode]
    let testPlanConfigurations: [TestPlanConfiguration]
}

struct TestNode: Codable {
    let children: [TestNode]?
    let duration: String?
    let durationInSeconds: SafeDouble?
    let name: String
    let nodeIdentifier: String?
    let nodeIdentifierURL: String?
    let nodeType: String
    let result: String
}

XCResultExplorer.main()