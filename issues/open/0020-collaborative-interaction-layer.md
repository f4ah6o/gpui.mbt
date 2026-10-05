# Collaborative interaction layer

Status: open
Related: [0003-testing-pbt-mutation-and-visual-validation.md](0003-testing-pbt-mutation-and-visual-validation.md), [0009-browser-backend.md](0009-browser-backend.md), [0013-generated-api-and-mcp-adapters.md](0013-generated-api-and-mcp-adapters.md)
Updated: 2026-10-05

## Goal

Make gpui.mbt applications natively operable by multiple actors on the same UI
surface without hard-coding a fixed "AI decides, human clicks" or "AI drives the
browser" workflow.

The framework should support a shared interaction model where a human, an AI
agent, automation, and framework/system logic can all observe and act on the
same application state through the same semantic controls.

The target architecture is:

```text
                         application state
                                |
                    semantic interaction model
                                |
                 +--------------+--------------+
                 |              |              |
               Human          Agent          System
                 |              |              |
                 +------- shared UI state -----+
                                |
                 +--------------+--------------+
                 |              |              |
              native         browser           TUI
                                |
                       optional WebMCP bridge
```

WebMCP is an adapter for the browser backend, not the core abstraction.
Likewise MCP, direct API calls, accessibility tooling, remote operators, test
automation, and future agent transports must be able to reuse the same
interaction semantics without making any one transport mandatory.

## Non-goals

This issue does not require:

- autonomous browser-use or vision-driven clicking as the primary control path
- making WebMCP a mandatory dependency of gpui.mbt
- exposing every widget or application function to external agents
- replacing the existing event/focus/input model with an agent-specific model
- giving agents unconditional authority to mutate or commit application state
- defining product-specific confirmation UX for every destructive action
- treating accessibility APIs as an agent transport or vice versa

Browser-use, VLM, and accessibility-tree automation remain useful fallback and
validation mechanisms, but they are not the semantic contract defined here.

## Design principle: actor and authority are separate

Do not encode policy as a fixed actor role such as:

```text
Human = execute
Agent = propose only
```

Instead, define actor identity separately from authority.

Conceptually:

```text
Actor
  - kind: human | agent | system | automation | other
  - stable session-local identity
  - optional display metadata

Authority
  - observe
  - focus
  - highlight
  - select
  - propose
  - edit
  - activate
  - commit
  - destructive
```

The exact public types may differ, but policy must be able to grant different
capabilities to different actors and contexts without changing the application
domain handler.

An agent may be allowed to edit one field directly, propose another change, and
be denied a destructive command. A human may normally have broad authority but
still encounter application policy or platform permission constraints.

## Shared semantic targets

Interactions must address stable semantic targets rather than pixels, DOM
coordinates, native object handles, or renderer internals.

A target should be identifiable by framework/application-owned semantic identity
that can survive backend differences.

Examples include:

- a setting field
- a button/action
- a document tab
- a list item
- a command palette entry
- a validation error
- a selection range
- an application-defined capability target

The interaction layer must not require DOM IDs, accessibility node IDs,
NSView/HWND handles, canvas coordinates, or JavaScript references in portable
application APIs.

A backend may map a semantic target to native focus, DOM, canvas hit regions,
accessibility nodes, or renderer structures internally.

## Shared interaction state

The framework should be able to represent interaction state with actor
provenance where that distinction matters.

Candidate state includes:

- focused target and actor
- selection and actor
- highlight/attention target and actor
- pending proposal and actor
- active edit ownership or revision
- validation result
- interaction status
- last accepted mutation revision

This does not require every application to render cursors or labels for every
actor. Visual representation is a presentation concern.

The portable contract must, however, preserve enough provenance that a backend
or application can choose to render:

```text
Timeout

[ 45 ] sec
  ^ human is editing

Agent suggestion: 60 sec
                  ^ highlighted proposal
```

without inventing a second agent-only state store.

## Semantic actions

Define a small interaction vocabulary above raw pointer/keyboard events.

The first design pass should cover at least:

- observe/read
- focus
- blur/release focus where meaningful
- highlight/bring attention
- reveal/scroll into view
- select
- propose a value or action
- edit/set a value
- activate/invoke
- validate
- commit/submit
- cancel/revert
- undo where supported by the application

These operations are semantic intents. They need not map one-to-one to public
widget methods.

Pointer and keyboard input remain valid human/platform inputs. The interaction
layer is an additional semantic route into the same application behavior, not a
replacement for physical input.

## One domain action, multiple ingress paths

Do not duplicate application logic for GUI, agent, MCP, WebMCP, and direct API
paths.

The preferred flow is:

```text
GUI input -----------+
Agent interaction ---+
MCP/WebMCP ----------+--> semantic action/capability --> domain handler
Direct MoonBit ------+
```

Where an operation already belongs in the semantic capability registry, reuse
that registry and policy path.

Where the operation is framework interaction state such as focus/highlight or
selection ownership, define a framework-owned interaction primitive rather than
inventing a fake application command.

The boundary between interaction primitives and application semantic
capabilities must be explicit and testable.

## Concurrent human and agent activity

The design must not assume serialized ownership of the whole UI.

At minimum, define behavior for this case:

```text
base value:       30
human edit:       45
agent intended:   60
```

An agent action created against revision 30 must not silently overwrite a newer
human edit to 45 merely because it arrived later.

Use explicit revision/precondition semantics for mutations that can conflict.
The exact mechanism may be optimistic revision tokens, value preconditions, or
an equivalent deterministic contract.

Required properties:

- stale mutations are detectable
- conflict is returned as data, not hidden by last-writer-wins
- a caller can re-observe and intentionally retry
- unrelated targets can progress independently where safe
- framework-internal focus/highlight updates do not accidentally serialize all
  domain mutations
- application authors can opt into stronger serialization where required

Do not promise CRDT-style arbitrary merge semantics as part of this issue.

## Interaction policy and confirmation

Policy is evaluated at action time.

A policy decision may allow, deny, or require mediated confirmation depending on:

- actor identity/kind
- semantic target/action
- current application state
- effect class
- platform permission or user-gesture requirements
- application-specific rules

Confirmation must not be implemented by teaching an AI to find and click a
confirmation button through pixels.

Instead, the semantic action should expose that confirmation is required, and
the UI may present the confirmation on the same shared surface for a permitted
actor to resolve.

Human override/cancel must remain possible for in-progress mediated operations
unless the underlying domain operation is already irreversibly committed.

## Web backend and WebMCP

The browser backend should be able to project eligible semantic interactions to
WebMCP without making browser DOM structure the source of truth.

Desired direction:

```text
gpui.mbt interaction/capability registry
            |
            +--> browser UI/canvas
            |
            +--> WebMCP adapter
```

The adapter should expose only explicitly permitted operations and semantic
targets.

WebMCP-specific JavaScript objects, schemas, browser feature detection, and
registration lifecycle stay below the browser/adapter boundary.

A browser application must still work without WebMCP support.

When WebMCP is unavailable, other adapters may remain available. Browser-use or
vision automation can be a last-resort external fallback, but gpui.mbt does not
need to emulate pixel automation internally.

## MCP/direct API relationship

[0013-generated-api-and-mcp-adapters.md](0013-generated-api-and-mcp-adapters.md)
already defines generated machine-consumable APIs from semantic capabilities.

This issue extends the model in two directions:

1. represent framework interaction primitives that are not naturally domain
   commands, such as focus/highlight/reveal and actor-attributed selection;
2. make actor identity, authority, revision/precondition, and conflict semantics
   available consistently to applicable direct/MCP/WebMCP paths.

Do not fork the MCP adapter into a separate "agent UI" implementation.

## Accessibility relationship

Accessibility and collaborative agent interaction overlap in semantic structure
but have different contracts.

Reuse stable semantic metadata where appropriate, but keep distinct concerns for:

- accessibility roles/names/states/actions
- assistive technology platform bridges
- agent exposure policy
- agent identity and authority
- machine API schemas
- concurrent mutation preconditions

An element being accessible must not automatically make it remotely agent
writable.

Likewise, an externally exposed semantic capability must not imply that its
visual control satisfies accessibility requirements.

## Observability and audit

Accepted semantic interactions should be observable enough for tests and
applications to reason about actor provenance and outcomes.

At minimum, record or emit structured information for:

- actor
- semantic target/action
- accepted/denied/conflicted status
- relevant revision/precondition
- domain result or typed failure
- confirmation requirement where applicable

Do not put secrets or full sensitive values into diagnostics merely for audit.

Persistent audit logging is application policy and is not required in the
portable core.

## Work packets

### A. Actor and interaction primitives

Define portable types for:

- actor identity/kind
- semantic target identity
- semantic interaction action
- action outcome
- typed denial/unavailable/conflict states

Acceptance:

- types compile on all configured MoonBit targets
- no platform, DOM, MCP, or native-window handle leaks into portable types
- human, agent, system, and automation actors can be represented without
  encoding fixed authority in the actor enum/type

### B. Shared focus/highlight/selection model

Add the smallest framework-owned state required to support actor-attributed:

- focus
- highlight/attention
- reveal
- selection

Acceptance:

- existing human input semantics remain compatible
- agent focus/highlight does not require synthetic pointer motion
- backend rendering may distinguish actors but core semantics do not depend on a
  particular visual treatment
- teardown removes actor/session-owned transient interaction state

### C. Authority and mediated actions

Define policy hooks for semantic interactions.

Acceptance:

- an agent can be allowed to highlight while denied edit
- an agent can edit an allowed target without requiring browser-use
- a policy can require human confirmation for a specific effect
- denial is typed and does not silently degrade into a GUI click attempt
- authority changes are checked at execution time

### D. Revision and conflict semantics

Add deterministic stale-write detection for applicable semantic mutations.

Acceptance:

- a human edit after an agent observation causes the stale agent mutation to
  conflict rather than overwrite
- the agent can re-observe and retry with a fresh revision
- independent target mutations are not globally blocked
- conformance tests cover ordering and conflict outcomes

### E. Adapter projection

Project eligible interactions through existing/generated machine interfaces.

Initial targets:

- direct MoonBit invocation
- MCP where semantically appropriate
- browser WebMCP adapter when supported by the browser host

Acceptance:

- one domain handler is shared across GUI/direct/MCP/WebMCP ingress
- WebMCP remains optional
- explicit exposure policy controls machine-visible operations
- adapter schemas include required precondition/revision data where applicable
- unsupported backend capabilities fail explicitly

### F. Cross-backend and black-box validation

Add conformance coverage across headless/native/browser surfaces as they become
available.

Include:

- deterministic interaction state tests
- concurrent actor mutation tests
- policy/confirmation tests
- lifecycle/teardown tests
- browser adapter tests
- VLMKit black-box checks for visual focus/highlight state where useful

VLMKit is validation evidence, not the semantic control transport.

## Acceptance for closing this issue

This issue can close when all of the following are demonstrated:

- gpui.mbt has a backend-neutral multi-actor interaction contract
- actor identity is distinct from action authority
- a human and an agent can operate the same application state without separate
  domain implementations
- focus/highlight/selection can be driven semantically without pixel automation
- conflicting concurrent mutations are detected rather than silently
  last-writer-wins
- policy can allow direct agent action, proposal-only action, or mediated human
  confirmation without changing the underlying domain handler
- machine adapters reuse the common semantic path
- browser WebMCP support, if enabled, is an optional projection rather than the
  framework core
- headless conformance tests cover actor/policy/conflict semantics
- at least one browser or native integration fixture demonstrates shared-screen
  human + agent interaction
- repository documentation states the fallback boundary: semantic interaction
  first, accessibility/host automation where appropriate, pixel/VLM browser-use
  only when no semantic route exists

## Open design questions

Resolve during implementation rather than freezing them in this roadmap:

1. whether actor identity belongs in a dedicated interaction package or a more
   general execution context
2. whether focus is singular per window while highlight/attention is multi-actor
3. whether edit ownership needs leases or revision checks are sufficient for the
   first production contract
4. how much interaction provenance belongs in SceneSnapshot versus a parallel
   observable interaction snapshot
5. which framework interaction primitives should be projected as generated
   external capabilities and which should stay adapter-specific
6. how browser user-gesture requirements should be represented without leaking
   browser concepts into portable APIs
7. whether remote human operators should use the same actor representation as
   local humans or a distinct actor kind
8. what minimum visual convention, if any, gpui.mbt should provide for actor
   focus/highlight versus leaving all styling to applications

The implementation should prefer the smallest backend-neutral contract that can
prove real shared-screen collaboration before expanding the abstraction.
