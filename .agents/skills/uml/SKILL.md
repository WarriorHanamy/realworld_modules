---
name: uml
description: Create UML diagrams using PlantUML syntax. Best for software modeling — Class, Sequence, Activity, State Machine, Component, Use Case, and Deployment diagrams with concise text-based notation and auto-layout.
metadata:
  author: UML diagrams are powered by Markdown Viewer — the best multi-platform Markdown extension (Chrome/Edge/Firefox/VS Code) with diagrams, formulas, and one-click Word export. Learn more at https://docu.md
---

# UML Diagram Generator
**Quick Start:** Choose diagram type → Write PlantUML text → Define elements and relationships → Wrap in ` ```plantuml ` fence.
> ⚠️ **IMPORTANT:** Always use ` ```plantuml ` or ` ```puml ` code fence. NEVER use ` ```text ` — it will NOT render as a diagram.

## Critical Rules

- Every diagram starts with `@startuml` and ends with `@enduml`
- Use standard PlantUML keywords: `class`, `interface`, `abstract`, `enum`, `actor`, `participant`, `component`, `node`, `database`, `package`
- Relationships use arrow syntax: `-->`, `<|--`, `*--`, `o--`, `..>`, `..|>`
- Use `skinparam` for global styling and colors
- Use `#color` on individual elements for specific colors
- Notes use `note left of`, `note right of`, `note over`, or standalone `note "text" as N`

## UML Diagram Types
| Type | Purpose | Key Syntax | Example |
|------|---------|------------|---------|
| Class | Class structure and relationships | `class`, `interface`, `<\|--` | [class-diagram.md](examples/class-diagram.md) |
| Sequence | Message interactions over time | `participant`, `->`, `-->` | [sequence-diagram.md](examples/sequence-diagram.md) |
| Activity | Workflow and process flow | `start`, `:action;`, `if/else` | [activity-diagram.md](examples/activity-diagram.md) |
| Swimlane Activity | Multi-role activity with swimlanes | `\|Lane\|`, `:action;` | [swimlane-activity-diagram.md](examples/swimlane-activity-diagram.md) |
| State Machine | Object lifecycle states | `state`, `[*] -->` | [state-machine-diagram.md](examples/state-machine-diagram.md) |
| Component | System component organization | `component`, `[name]`, `interface` | [component-diagram.md](examples/component-diagram.md) |
| Use Case | User-system interactions | `actor`, `usecase`, `(name)` | [use-case-diagram.md](examples/use-case-diagram.md) |
| Deployment | Physical deployment architecture | `node`, `artifact`, `database` | [deployment-diagram.md](examples/deployment-diagram.md) |
| Object | Runtime object snapshot | `object "name" as id` | [object-diagram.md](examples/object-diagram.md) |
| Package | Module organization | `package "name"` | [package-diagram.md](examples/package-diagram.md) |
| Communication | Object collaboration | Numbered messages with sequence syntax | [communication-diagram.md](examples/communication-diagram.md) |
| Composite Structure | Internal class structure | `component` with nested `port` | [composite-structure-diagram.md](examples/composite-structure-diagram.md) |
| Interaction Overview | Activity + sequence combination | `group`, `ref over` | [interaction-overview-diagram.md](examples/interaction-overview-diagram.md) |
| Profile | UML extension mechanisms | `<<stereotype>>` labels | [profile-diagram.md](examples/profile-diagram.md) |

## Mxgraph Stencil Icons

draw-uml supports 9500+ mxgraph stencil icons (AWS, Azure, Cisco, Kubernetes, etc.) via the `mxgraph.*` syntax. Default colors are applied automatically — you do NOT need to specify `fillColor` or `strokeColor`.

**Full stencil reference:** See [stencils/README.md](stencils/README.md).

### Syntax

```
mxgraph.<namespace>.<icon> "Label" as <alias>
mxgraph.<namespace>.<icon> "Label" as <alias> #color
mxgraph.<namespace>.<icon> <alias>
```

- `mxgraph.<namespace>.<icon>` — the stencil shape key (e.g. `mxgraph.aws4.lambda`, `mxgraph.kubernetes.pod`)
- `"Label"` — display text (quoted if contains spaces, unquoted for single word)
- `as <alias>` — identifier for use in relationships
- `#color` — optional override color (e.g. `#FF6600`, `#LightBlue`)

### Examples

```plantuml
@startuml
' Simple icon declaration
mxgraph.aws4.lambda "Lambda\nFunction" as fn
mxgraph.aws4.api_gateway "API GW" as gw
mxgraph.aws4.dynamodb "DynamoDB" as db

gw --> fn
fn --> db
@enduml
```

```plantuml
@startuml
' Kubernetes architecture with icons
mxgraph.kubernetes.ing "Ingress" as ing
mxgraph.kubernetes.svc "Service" as svc
mxgraph.kubernetes.pod "Pod" as pod
mxgraph.kubernetes.deploy "Deployment" as deploy

ing --> svc
svc --> pod
deploy --> pod
@enduml
```

```plantuml
@startuml
' Mixing standard UML with stencil icons
node "Cloud" {
  mxgraph.aws4.ec2 "EC2" as ec2
  mxgraph.aws4.rds "RDS" as rds
}
database "Legacy DB" as legacy

ec2 --> rds
rds --> legacy
@enduml
```

## Failure Experiences (Losses)

Real-world syntax traps encountered when compiling PlantUML state / activity diagrams.

### 1. Colored notes on states is NOT valid

```
' WRONG — plantuml rejects this:
note right of IDLE -[#FFA726]
  text
end note

' RIGHT — plain note, no color suffix:
note right of IDLE
  text
end note
```

`note` lines do NOT support the `-[#color]` arrow-coloring syntax. PlantUml interprets the dash as a malformed transition and errors out. If you need visual emphasis, use HTML tags inside the note body instead.

### 2. Markdown-style formatting does NOT work in notes

```
' WRONG — **bold** and `code` are not parsed:
note right of IDLE
  **GUARD #1** requires `check()`
end note

' RIGHT — use HTML tags:
note right of IDLE
  <b>GUARD #1</b> requires <i>check()</i>
end note
```

PlantUML notes only support a subset of HTML-like tags (`<b>`, `<i>`, `<u>`, `<s>`, `<w>`, `<font>`, `<color>`, `<size>`, `<img>`). Markdown asterisk/backtick syntax is silently ignored or rendered as literal text.

### 3. `partition {}` inside a swimlane breaks compilation

```
' WRONG — partition inside |lane| context:
|cycle_demo|
partition "my_block" {
  :action;
}

' RIGHT — choose one or the other:
' Option A: swimlanes only (no partition)
|cycle_demo|
:action;

' Option B: partition only (no |lane|)
partition "my_block" {
  :action;
}
```

Mixing `partition {...}` blocks inside swimlanes (`|Lane|`) produces unreliable output or outright syntax errors. Prefer swimlanes for multi-actor pipelines; use partitions only in single-swimlane (or no-swimlane) activity diagrams.

### 4. `repeat` / `repeat while` across swimlanes is fragile

When the body of a `repeat { ... }   repeat while (cond)` loop crosses swimlane boundaries (e.g. starts in `|User|`, then goes to `|cycle_demo|`, then back to `|User|`), the rendering engine often fails to draw the loop-back arrow correctly. The resulting diagram may have disconnected arrows or missing flows.

**Mitigation:** For multi-swimlane cyclic flows, use a **state machine diagram** instead of an activity diagram with `repeat`.

### 5. Nested substate notes may not render

In a state machine diagram, notes attached to deeply nested substates sometimes get dropped by the renderer:

```
state "LEVEL1" as L1 {
  state "LEVEL2" as L2 {
    state "DEEP" as DEEP
  }
}

' This note may not appear in the output:
note right of DEEP : some text
```

**Mitigation:** Attach the note to the **outermost** state that still makes semantic sense, or use a `note as VAR ... end note` standalone note linked via a dashed arrow.

### 6. State diagram vs activity diagram — choose the right type

| You want to show...                     | Use                  |
| --------------------------------------- | -------------------- |
| States + transitions + guard conditions | `state` (state machine) |
| Sequential pipeline of actions          | `:action;` (activity)    |
| Multi-actor workflow                    | `|Lane|` (swimlane activity) |
| Both state machine AND internal pipeline | Prefer two separate diagrams in one file, linked by `newpage` or a comment |

Trying to cram a 10-stage sequential pipeline into a state machine's substates produces a deeply nested diagram that is hard to read and prone to render bugs. Keep it simple: one diagram per concept.
