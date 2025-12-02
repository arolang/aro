# ARO-0011: Concurrency and Async

* Proposal: ARO-0011
* Author: ARO Language Team
* Status: **Draft**
* Requires: ARO-0001, ARO-0008

## Abstract

This proposal introduces concurrency primitives to ARO, enabling parallel execution, async operations, and structured concurrency.

## Motivation

Modern applications require:

1. **Async I/O**: Non-blocking network/database calls
2. **Parallelism**: Process multiple items concurrently
3. **Coordination**: Synchronize concurrent operations
4. **Safety**: Prevent data races

---

### 1. Async Feature Sets

#### 1.1 Async Declaration

```ebnf
async_feature_set = "async" , feature_set ;
```

**Example:**
```
async (Fetch User Data: API) {
    <Retrieve> the <user> from the <remote-api>.
    <Retrieve> the <preferences> from the <preferences-service>.
    <Return> the <combined-data> for the <request>.
}
```

#### 1.2 Await Expression

```ebnf
await_expression = "await" , expression ;
```

**Example:**
```
async (Dashboard: UI) {
    <Set> the <user-future> to async <Fetch> the <user>.
    <Set> the <orders-future> to async <Fetch> the <orders>.
    
    // Explicit await
    <Set> the <user> to await <user-future>.
    <Set> the <orders> to await <orders-future>.
    
    <Compose> the <dashboard> from <user> and <orders>.
}
```

---

### 2. Parallel Execution

#### 2.1 Parallel For-Each

```ebnf
parallel_foreach = "parallel" , "for" , "each" , variable_reference ,
                   "in" , variable_reference ,
                   [ "with" , parallel_options ] ,
                   block ;

parallel_options = "{" , option_list , "}" ;
option_list = option , { "," , option } ;
option = identifier , ":" , expression ;
```

**Example:**
```
async (Process Orders: Batch) {
    <Retrieve> the <pending-orders> from the <order-queue>.
    
    parallel for each <order> in <pending-orders> with { maxConcurrency: 10 } {
        <Process> the <order>.
        <Update> the <order: status> to "completed".
    }
}
```

#### 2.2 Parallel Map

```
<Compute> the <results> from 
    <items>.parallelMap(<item> => <process>(<item>), concurrency: 5).
```

---

### 3. Concurrent Execution

#### 3.1 Concurrent Block

Execute multiple operations concurrently and wait for all:

```ebnf
concurrent_block = "concurrent" , "{" , { concurrent_task } , "}" ;
concurrent_task = [ identifier , "=" ] , statement ;
```

**Example:**
```
async (User Profile: Aggregation) {
    concurrent {
        user = <Retrieve> the <user> from the <user-service>.
        orders = <Retrieve> the <orders> from the <order-service>.
        recommendations = <Retrieve> the <recommendations> from the <ml-service>.
    }
    
    // All three complete before continuing
    <Compose> the <profile> from <user>, <orders>, <recommendations>.
}
```

#### 3.2 Race Block

Return first completed result:

```ebnf
race_block = "race" , "{" , { concurrent_task } , "}" ;
```

**Example:**
```
async (Fast Response: Caching) {
    race {
        cached = <Retrieve> the <data> from the <cache>.
        fresh = <Retrieve> the <data> from the <database>.
    }
    
    // First to complete wins
    <Return> the <data> for the <request>.
}
```

---

### 4. Actors

#### 4.1 Actor Definition

```ebnf
actor_definition = "actor" , identifier , "{" ,
                   { actor_member } ,
                   "}" ;

actor_member = state_declaration | message_handler ;
state_declaration = "state" , identifier , ":" , type_annotation , 
                    [ "=" , expression ] , ";" ;
message_handler = "on" , message_pattern , block ;
```

**Example:**
```
actor Counter {
    state count: Int = 0;
    
    on <Increment> {
        <Set> the <count> to <count> + 1.
    }
    
    on <Decrement> {
        <Set> the <count> to <count> - 1.
    }
    
    on <GetCount> {
        <Reply> with <count>.
    }
    
    on <Reset: value> {
        <Set> the <count> to <value>.
    }
}
```

#### 4.2 Actor Usage

```
async (Counter Demo: Example) {
    <Create> the <counter> as Counter.
    
    <Send> <Increment> to <counter>.
    <Send> <Increment> to <counter>.
    <Send> <Increment> to <counter>.
    
    <Ask> the <current: Int> from <counter> with <GetCount>.
    // current == 3
}
```

---

### 5. Channels

#### 5.1 Channel Creation

```ebnf
channel_creation = "<Create>" , "channel" , "<" , identifier , ">" ,
                   "of" , type_annotation ,
                   [ "with" , channel_options ] , "." ;
```

**Example:**
```
<Create> channel <tasks> of Task with { buffer: 100 }.
<Create> channel <results> of Result.  // Unbuffered
```

#### 5.2 Send and Receive

```
// Send to channel
<Send> the <task> to <tasks>.

// Receive from channel
<Receive> the <task> from <tasks>.

// Non-blocking receive
<TryReceive> the <task: Task?> from <tasks>.
```

#### 5.3 Select Statement

```ebnf
select_statement = "select" , "{" , { select_case } , "}" ;
select_case = "case" , channel_operation , block ;
```

**Example:**
```
select {
    case <Receive> the <task> from <tasks> {
        <Process> the <task>.
    }
    case <Receive> the <signal> from <shutdown> {
        <Break>.
    }
    case timeout 5.seconds {
        <Log> the <idle> for <monitoring>.
    }
}
```

---

### 6. Structured Concurrency

#### 6.1 Task Groups

```ebnf
task_group = "with" , "tasks" , [ "as" , identifier ] , block ;
```

**Example:**
```
async (Process Batch: Pipeline) {
    with tasks as <group> {
        for each <item> in <items> {
            <Spawn> <Process> the <item> in <group>.
        }
    }
    // All tasks complete when block exits
    
    <Log> the <batch-complete> for <monitoring>.
}
```

#### 6.2 Cancellation

```
async (Cancellable Operation: Control) {
    <Set> the <task> to async <LongRunning> operation.
    
    if <timeout-reached> then {
        <Cancel> the <task>.
    }
    
    try {
        <Set> the <result> to await <task>.
    } catch <CancellationError> {
        <Log> the <cancelled> for <monitoring>.
    }
}
```

---

### 7. Synchronization Primitives

#### 7.1 Mutex

```
async (Thread Safe: Concurrency) {
    <Acquire> the <mutex>.
    defer {
        <Release> the <mutex>.
    }
    
    <Update> the <shared-state>.
}

// Or with block syntax
with lock <mutex> {
    <Update> the <shared-state>.
}
```

#### 7.2 Semaphore

```
<Create> semaphore <connections> with { permits: 10 }.

async (Rate Limited: API) {
    <Acquire> permit from <connections>.
    defer {
        <Release> permit to <connections>.
    }
    
    <Call> the <external-api>.
}
```

#### 7.3 Barrier

```
async (Phased Computation: Parallel) {
    <Create> barrier <phase-complete> for <worker-count>.
    
    parallel for each <worker> in <workers> {
        <Execute> phase 1.
        <Await> the <phase-complete>.  // All workers sync here
        <Execute> phase 2.
    }
}
```

---

### 8. Async Streams

#### 8.1 Stream Definition

```
async (Event Stream: Reactive) {
    <Create> stream <events> of Event.
    
    // Producer
    async {
        for each <event> in <event-source> {
            <Yield> the <event> to <events>.
        }
        <Complete> the <events>.
    }
    
    // Consumer
    for await <event> in <events> {
        <Process> the <event>.
    }
}
```

#### 8.2 Stream Operators

```
<Transform> the <filtered-events> from 
    <events>
        .filter(<e> => <e>.type == "important")
        .map(<e> => <e>.payload)
        .buffer(100)
        .debounce(100.milliseconds).
```

---

### 9. Complete Grammar Extension

```ebnf
(* Concurrency Grammar *)

(* Async Feature Set *)
async_feature_set = "async" , feature_set ;

(* Await *)
await_expression = "await" , expression ;
async_expression = "async" , expression ;

(* Parallel *)
parallel_foreach = "parallel" , "for" , "each" , 
                   variable_reference , "in" , variable_reference ,
                   [ "with" , inline_object ] , block ;

(* Concurrent/Race *)
concurrent_block = "concurrent" , "{" , { task_binding } , "}" ;
race_block = "race" , "{" , { task_binding } , "}" ;
task_binding = [ identifier , "=" ] , statement ;

(* Actor *)
actor_definition = "actor" , identifier , "{" , { actor_member } , "}" ;
actor_member = state_decl | message_handler ;
state_decl = "state" , identifier , ":" , type_annotation , 
             [ "=" , expression ] , ";" ;
message_handler = "on" , pattern , block ;

(* Channels *)
channel_op = send_op | receive_op | select_stmt ;
send_op = "<Send>" , expression , "to" , variable_reference , "." ;
receive_op = "<Receive>" , variable_reference , "from" , 
             variable_reference , "." ;
select_stmt = "select" , "{" , { select_case } , "}" ;
select_case = "case" , ( channel_op | timeout_clause ) , block ;
timeout_clause = "timeout" , duration ;

(* Task Groups *)
task_group = "with" , "tasks" , [ "as" , identifier ] , block ;
spawn_stmt = "<Spawn>" , statement , "in" , variable_reference , "." ;
cancel_stmt = "<Cancel>" , variable_reference , "." ;

(* Synchronization *)
lock_block = "with" , "lock" , variable_reference , block ;

(* Async Streams *)
for_await = "for" , "await" , variable_reference , "in" , 
            variable_reference , block ;
yield_stmt = "<Yield>" , expression , "to" , variable_reference , "." ;
```

---

### 10. Complete Example

```
actor OrderProcessor {
    state pendingOrders: List<Order> = [];
    state processing: Bool = false;
    
    on <Enqueue: order> {
        <Add> the <order> to <pendingOrders>.
        if not <processing> then {
            <Send> <ProcessNext> to self.
        }
    }
    
    on <ProcessNext> {
        if <pendingOrders> is empty then {
            <Set> the <processing> to false.
        } else {
            <Set> the <processing> to true.
            <Dequeue> the <order> from <pendingOrders>.
            <Process> the <order>.
            <Send> <ProcessNext> to self.
        }
    }
}

async (Order Pipeline: E-Commerce) {
    <Create> channel <incoming> of Order with { buffer: 1000 }.
    <Create> the <processor> as OrderProcessor.
    
    // Producer task
    <Spawn> async {
        for await <order> in <order-stream> {
            <Send> the <order> to <incoming>.
        }
    }.
    
    // Consumer tasks
    parallel for each <_> in range(1, 10) with { maxConcurrency: 10 } {
        while true {
            select {
                case <Receive> the <order> from <incoming> {
                    <Send> <Enqueue: order> to <processor>.
                }
                case <Receive> <_> from <shutdown> {
                    <Break>.
                }
            }
        }
    }
}
```

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification |
