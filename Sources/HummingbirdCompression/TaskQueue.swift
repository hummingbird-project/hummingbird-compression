//===----------------------------------------------------------------------===//
//
// This source file is part of the Soto for AWS open source project
//
// Copyright (c) 2020-2021 the Soto project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Soto project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import NIO

/// Manage a queue of tasks, ensuring only one task is running concurrently. Based off code posted by
/// Cory Benfield on Vapor Discord. https://discord.com/channels/431917998102675485/448584561845338139/766320821206908959
class TaskQueue<Value> {
    struct PendingTask<Value> {
        let id: UUID
        let task: () -> EventLoopFuture<Value>
        let promise: EventLoopPromise<Value>

        init(_ task: @escaping () -> EventLoopFuture<Value>, on eventLoop: EventLoop) {
            self.id = UUID()
            self.task = task
            self.promise = eventLoop.makePromise(of: Value.self)
        }
    }

    struct Cancelled: Error {}

    let eventLoop: EventLoop
    private var queue: CircularBuffer<PendingTask<Value>>
    private var inflightTask: PendingTask<Value>?

    init(on eventLoop: EventLoop) {
        self.eventLoop = eventLoop
        self.queue = CircularBuffer(initialCapacity: 1)
        self.inflightTask = nil
    }

    @discardableResult func submitTask(_ task: @escaping () -> EventLoopFuture<Value>) -> EventLoopFuture<Value> {
        self.eventLoop.flatSubmit {
            let task = PendingTask(task, on: self.eventLoop)

            if self.inflightTask == nil {
                self.invoke(task)
            } else {
                self.queue.append(task)
            }

            return task.promise.futureResult
        }
    }

    /// Return EventLoopFuture that succeeds when all the tasks have completed
    func flush() -> EventLoopFuture<Void> {
        self.eventLoop.flatSubmit {
            var futures = self.queue.map { $0.promise.futureResult }
            if let inflightTaskFuture = self.inflightTask?.promise.futureResult {
                futures.append(inflightTaskFuture)
            }
            return EventLoopFuture.andAllComplete(futures, on: self.eventLoop)
        }
    }
    
    private func invoke(_ task: PendingTask<Value>) {
        self.eventLoop.preconditionInEventLoop()

        self.inflightTask = task
        task.task().hop(to: self.eventLoop).whenComplete { result in
            self.inflightTask = nil
            self.invokeIfNeeded()
            task.promise.completeWith(result)
        }
    }

    private func invokeIfNeeded() {
        self.eventLoop.preconditionInEventLoop()

        if let first = self.queue.popFirst() {
            self.invoke(first)
        }
    }

    public func cancelQueue() {
        self.eventLoop.preconditionInEventLoop()
        while let task = self.queue.popFirst() {
            task.promise.fail(Cancelled())
        }
    }
}
