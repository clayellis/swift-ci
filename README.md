# SwiftCI

SwiftCI is a CI/CD scheme written in Swift that leverages the Swift ecosystem.

A basic SwiftCI setup looks like this:

> CICD.swift
```swift
import SwiftCI

@main
struct CICD: Workflow {
    func run() async throws {
        let project = "MyProject.xcodeproj"
        try await buildAndTest(project: project)
        try await archiveAndUploadToAppStore(project: project)
    }
}
```

## Getting Started

_// TODO: Package.swift, directory structure, GitHub Action, etc._

## Overview

SwiftCI has two main types: `Workflow` and `Step`. Workflows run steps or other workflows. Steps can run other steps, but not workflows. Steps return `Output`.

_// TODO: `Context`_

## Developing Steps

There are three main methods to make your custom steps discoverable. It is recommended to support all three when vending steps so that users can discover your step in any context.

**1. Add a `typealias` to the `Steps` namespace:**

```swift
extension Steps {
    public typealias MyStep = MyModule.MyStep
}

public struct MyStep: Step {
    let input: String
    
    public init(input: String) {...} 
}
```

This method enables users to discover your step using autocompletion when choosing a step to run:

```swift
try await step(Steps.MyStep(input: "hello"))
```

**2. Add your step using static member lookup:**

```swift
extension Step where Self == MyStep {
    public static func myStep(input: String) -> MyStep {
        MyStep(input: input)
    }
}
```

This method enables users to discover your step using autocompletion when invoking the `step(_:)` methods:

```swift
func run() async throws {
    try await step(.myStep(input: "hello"))
}
```

**3. Add a method to `Workflow`:**

```swift
extension Workflow {
    public func myStep(input: String) async throws -> MyStep.Output {
        try await step(MyStep(input: input))
    }
}
```

This method enables users to run your step directly, without invoking the `step(_:)` methods:

```swift
func run() async throws {
    try await myStep(input: "hello")
}
```
