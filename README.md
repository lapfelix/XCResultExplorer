# XCResultExplorer
Interactive command line tool to explore XCResult files - list all tests and view detailed information including console output.

## Features
- 🔍 Find all XCResult files in a project with timestamps and file sizes
- 📋 List all tests with their status and IDs
- 🔍 View detailed information about specific tests
- 🔬 Access extreme details including console output (with --console)
- 💡 Smart failure analysis with suggested fixes
- 🎯 Much easier to use than xcresulttool

## Usage

### Find all XCResult files in a project
```bash
xcresultexplorer . --project
```

### List all tests in an XCResult file
```bash
xcresultexplorer path/to/result.xcresult
```

### View details for a specific test
```bash
xcresultexplorer path/to/result.xcresult --test-id "TestIdentifier"
```

### View extreme details with console output
```bash
xcresultexplorer path/to/result.xcresult --test-id "TestIdentifier" --console
```

## Installation
```bash
swift build -c release
cp .build/release/xcresultexplorer /usr/local/bin/
```
