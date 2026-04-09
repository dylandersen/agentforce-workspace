# Agentforce Workspace

Agentforce Workspace is a production-oriented conversational analytics surface for Salesforce. It combines Lightning Web Components, Apex orchestration, and the Salesforce Models API to turn natural language into secure data retrieval, structured record actions, and high-value analysis inside Lightning Experience.

This project is not a chat wrapper around SOQL. It is an attempt to build a serious reasoning interface for CRM and service operations: schema-aware, user-context-aware, resilient under ambiguity, and disciplined about how AI is allowed to interact with enterprise data.

![Salesforce API v65.0](https://img.shields.io/badge/Salesforce%20API-v65.0-blue)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

## Executive Summary

Agentforce Workspace gives business users a single surface where they can:

- ask analytical questions in natural language
- issue operational commands such as record updates or task creation
- request drafted content such as activity summaries or emails
- inspect structured result sets in native Salesforce UI
- receive follow-up guidance when intent is unclear or data is unavailable

The current architecture reflects a substantial shift from a simple NL-to-SOQL pipeline toward a multi-pass reasoning system with explicit intent classification, adaptive retry behavior, prompt modularity, and UI states that accurately reflect what the system is doing.

## Why This Project Matters

Most Salesforce AI prototypes fail in predictable ways:

- they treat every input as a question
- they rely on one large prompt that tries to do everything
- they break when generated SOQL fails
- they confuse content generation with record mutation
- they expose brittle UX states when results are empty or partial

Agentforce Workspace is designed to address those failure modes directly. The goal is a system that can interpret user intent, choose the right execution path, recover from model mistakes, and either produce an answer or explain clearly why it cannot.

## System Architecture

### High-Level Runtime

```text
+------------------+        +-----------------------------------+
| Lightning UI     |        | Apex Orchestration Layer          |
| agentforceWorkspace       | AgentforceWorkspaceController      |
+---------+--------+        +----------------+------------------+
          |                                  |
          | user input                       |
          v                                  v
          |                        +-----------------------------+
          |                        | Pass 0: Intent Classification|
          |                        | Cheap model, fast decision   |
          |                        +-------------+---------------+
          |                                      |
          |                                      v
          |                        +-----------------------------+
          |                        | Pass 1-3: Reasoning Loop    |
          |                        | Generate SOQL or action JSON|
          |                        | Retry with diagnostics      |
          |                        +-------------+---------------+
          |                                      |
          |                                      v
          |                        +-----------------------------+
          |                        | Query / Action Execution    |
          |                        | USER_MODE, sharing-respect  |
          |                        +-------------+---------------+
          |                                      |
          |                                      v
          |                        +-----------------------------+
          |                        | Pass 2 Analysis             |
          |                        | HTML response, links, chart |
          |                        +-------------+---------------+
          |                                      |
          +--------------------------------------+
                         structured UI payload
```

### Detailed Flow

```text
User message
   |
   v
[Pass 0] Classify intent
   |   QUERY | CREATE | UPDATE | COMPARE | COMPOSE | FOLLOWUP | CLARIFY
   |
   +--> CLARIFY -> return clarification prompt + suggestions
   |
   v
[Pass 1] Build intent-aware prompt modules
   |
   v
LLM response
   |
   +--> action JSON -> record create / update flow
   |
   +--> SOQL -> parse -> validate -> execute
                         |
                         +--> success -> collect results
                         |
                         +--> failure -> [Pass 2] diagnostic retry
                                           |
                                           +--> still failing -> [Pass 3] simplified retry
                                                               |
                                                               +--> structured failure explanation
   |
   v
Build record tabs + links + execution summary
   |
   v
Analysis pass -> HTML answer + suggestions + optional chart metadata
```

## Major Architectural Advances

The latest revision introduces six meaningful changes to the platform.

| Change | What changed | Why it matters |
|---|---|---|
| `R1` Intent classification | Added a lightweight Pass 0 classifier before SOQL generation | Distinguishes data retrieval, record mutation, content composition, follow-up actions, and clarification scenarios |
| `R2` LLM-driven reasoning loop | Replaced the rigid single retry with a structured 3-attempt loop | Improves recovery from malformed SOQL, ambiguous user phrasing, and partial failures |
| `R4` Modular prompt architecture | Split the NL-to-SOQL prompt into intent-gated modules | Reduces prompt noise, cost, and instruction conflicts |
| `R5` Dynamic error analysis | Retry prompts now include actual failed SOQL and platform errors | Enables diagnosis of real SOQL issues instead of relying on a short hardcoded hint list |
| `R6` Few-shot guidance | Added concrete examples for multi-object, aggregation, fuzzy name matching, and activity summary patterns | Gives the model reliable examples for difficult cases |
| UI hardening | Progress states and action cards now reflect intent and outcome more accurately | Produces a more trustworthy user experience during create, update, empty-result, and analysis flows |

## Core Design Principles

### 1. Intent before execution

The system does not assume that every utterance is a report request. A user message might be:

- a query
- a command
- a comparison
- a composition request
- a follow-up confirmation
- a vague statement that requires clarification

That distinction is handled explicitly by `AgentforceWorkspaceReasoningEngine`, not left implicit inside one oversized prompt.

### 2. Recovery over brittleness

Generated SOQL is fallible. The system is designed to recover from:

- non-groupable fields in aggregate queries
- invalid field or relationship references
- object resolution mistakes
- malformed SOQL structure
- semantic mismatches between user wording and org data

### 3. Security by execution context

Queries are executed as the running user and supplementary queries use `WITH USER_MODE` where appropriate. The architecture is built to respect:

- sharing
- CRUD
- field visibility
- object availability in the connected org

### 4. Structured UX, not opaque AI output

The frontend does not merely dump model text into a chat bubble. It renders:

- progress stages
- related record tabs
- created or updated record cards
- charts
- follow-up suggestions
- failure explanations with alternatives

## Apex Service Architecture

The server-side implementation is intentionally decomposed into focused classes rather than one monolithic controller.

| Class | Responsibility |
|---|---|
| `AgentforceWorkspaceController` | Public Apex entry point for `buildQueries`, `analyzeResults`, and user-context methods |
| `AgentforceWorkspaceReasoningEngine` | Pass 0 intent classification and Pass 1-3 reasoning loop |
| `AgentforceWorkspaceAnalysisService` | Prompt construction, Models API calls, analysis prompt generation, response parsing |
| `AgentforceWorkspaceQueryService` | Query execution support, supplementary queries, record tab building, formatting |
| `AgentforceWorkspaceLinkService` | Safe record-link injection into model-generated HTML |
| `AgentforceWorkspaceRecordCreator` | Create/update action parsing, execution, post-create follow-up field completion |
| `AgentforceWorkspaceModels` | DTOs shared between Apex and LWC |
| `BusinessIntelligence` | Shared schema-context, parsing, query-plan, and execution primitives |

### Apex Interaction Model

```text
AgentforceWorkspaceController
   |
   +--> AgentforceWorkspaceReasoningEngine
   |        |
   |        +--> AgentforceWorkspaceAnalysisService
   |        +--> BusinessIntelligence
   |
   +--> AgentforceWorkspaceQueryService
   +--> AgentforceWorkspaceLinkService
   +--> AgentforceWorkspaceRecordCreator
   +--> AgentforceWorkspaceModels
```

## Prompt Architecture

One of the most important engineering improvements in this project is the move away from a single monolithic prompt.

### Prompt Modules

| Module | Included when | Purpose |
|---|---|---|
| Core SOQL rules | Always | Baseline query constraints, date logic, grouping rules, object resolution |
| Create/update rules | `CREATE`, `UPDATE`, `FOLLOWUP` | Structured action JSON for record creation and updates |
| Compose rules | `COMPOSE` | Drafting and summarization behavior without accidental record mutation |
| Complex query patterns | `QUERY`, `COMPARE`, `COMPOSE` | Multi-object retrieval patterns such as meetings to accounts to cases |
| Data Cloud rules | Consumption and usage prompts | Account lookup strategy for Data Cloud enrichment scenarios |
| Few-shot examples | All relevant passes | High-signal examples for tricky retrieval patterns |

### Prompt Evolution

```text
Old model
---------
One large prompt
  -> high token load
  -> conflicting instructions
  -> weaker compliance

Current model
-------------
Intent classification
  -> select relevant prompt modules
  -> attach schema context
  -> attach only high-value examples
  -> generate more precise output
```

### Dynamic Error Diagnosis

Earlier versions used a static retry hint list. The current reasoning loop sends the actual failure back to the model, including the failed SOQL and the platform error text.

That allows the retry pass to reason about issues such as:

- `Field Subject is not groupable`
- `No such column`
- unsupported objects in the current org
- malformed relationship paths
- implementation restrictions on specific query patterns

## Intent Taxonomy

The intent classifier returns a structured `IntentResult` with:

- `intent`
- `plan`
- `confidence`
- `clarification`

Supported intent classes:

| Intent | Meaning |
|---|---|
| `QUERY` | Retrieve or analyze Salesforce data |
| `CREATE` | Create a record |
| `UPDATE` | Modify an existing record |
| `COMPARE` | Compare entities or metrics |
| `COMPOSE` | Draft or summarize content from retrieved data |
| `FOLLOWUP` | Continue a pending action or respond to an existing workflow |
| `CLARIFY` | Ask the user for a more specific request |

## LWC Surface Architecture

The frontend is designed as a composed operational workspace rather than a single chat transcript.

| Bundle | Responsibility |
|---|---|
| `agentforceWorkspace` | Main shell, chat timeline, progress system, model picker, caching, orchestration |
| `investigatorRecordList` | Tabbed record grids with sorting, navigation, and expandable list views |
| `investigatorCreatedRecord` | Action-result card for created, updated, or deleted records |
| `investigatorChart` | Chart rendering for structured numeric summaries |
| `investigatorMapView` | Geographic visualization for records with address data |

### Sidebar State Model

```text
Details Panel
  |
  +--> Progress
  +--> Related Records
  +--> Record Action
         |
         +--> Created Record
         +--> Updated Record
         +--> Deleted Record
  +--> Visualization
  +--> Map
  +--> Usage Estimate
```

The workspace now tracks action semantics explicitly. A successful update no longer renders as a creation event. Progress text has also been revised to better reflect real system states such as intent understanding and analysis preparation.

## Result Handling and UX Semantics

The system deliberately separates execution from presentation.

### Stage 1: `buildQueries`

Returns:

- intent label for the UI
- reasoning attempt count
- record tabs for immediate rendering
- serialized execution data for the analysis pass
- structured action results for create and update flows

### Stage 2: `analyzeResults`

Consumes the serialized execution data and returns:

- HTML response
- suggestions
- created or updated record info
- chart metadata
- pending record completion prompts

### Failure Handling

Failures are represented as structured application states, not generic exceptions:

- clarification required
- all reasoning attempts exhausted
- create/update action needs more fields
- empty data with valid analysis path
- model/service error

## Fuzzy Matching and Retrieval Robustness

A notable improvement in the current architecture is explicit support for fuzzy account-name resolution. In enterprise CRM, the user rarely types the legal or exact account name.

Examples:

- user says `Meridian Financial`
- account is `Meridian Financial Services`
- user says `PDC`
- account is `Pacific Distribution Centers`

The prompt and examples now explicitly instruct the model to use `LIKE '%keyword%'` patterns through account subqueries for child-object retrieval, especially for:

- `Task`
- `Event`
- `Contact`
- `Opportunity`
- `Case`

This materially improves activity summaries, contact lookups, and account-scoped analysis.

## Supported Models

The workspace exposes multiple foundation models through the Salesforce Models API.

| Model | Provider | Model API ID |
|---|---|---|
| Gemini 3.1 Flash | Google Vertex AI | `sfdc_ai__DefaultVertexAIGemini31FlashLite` |
| Gemini 3.1 Pro | Google Vertex AI | `sfdc_ai__DefaultVertexAIGeminiPro31` |
| GPT-5 | OpenAI | `sfdc_ai__DefaultGPT5` |
| GPT-5.2 | OpenAI | `sfdc_ai__DefaultGPT52` |
| Nemotron 3 Nano | NVIDIA Bedrock | `sfdc_ai__DefaultBedrockNvidiaNemotronNano330b` |
| Sonnet 4.5 | Anthropic Bedrock | `sfdc_ai__DefaultBedrockAnthropicClaude45Sonnet` |
| Opus 4.5 | Anthropic Bedrock | `sfdc_ai__DefaultBedrockAnthropicClaude45Opus` |

The classifier always uses the cheapest fast-path model for Pass 0. User-selected models are applied to reasoning and analysis passes.

## Repository Layout

```text
force-app/main/default/
├── classes/
│   ├── AgentforceWorkspaceController.cls
│   ├── AgentforceWorkspaceReasoningEngine.cls
│   ├── AgentforceWorkspaceAnalysisService.cls
│   ├── AgentforceWorkspaceQueryService.cls
│   ├── AgentforceWorkspaceLinkService.cls
│   ├── AgentforceWorkspaceRecordCreator.cls
│   ├── AgentforceWorkspaceModels.cls
│   └── BusinessIntelligence.cls
├── lwc/
│   ├── agentforceWorkspace/
│   ├── investigatorRecordList/
│   ├── investigatorCreatedRecord/
│   ├── investigatorChart/
│   └── investigatorMapView/
├── flexipages/
│   └── Agentforce_Workspace.flexipage-meta.xml
└── staticresources/
    └── model and product artwork
```

## Development Prerequisites

- Salesforce org with Models API access
- API version `65.0+`
- access to the foundation models configured for the workspace
- permission to deploy Apex classes, LWCs, and flexipages

## Deployment

```bash
# Authenticate
sf org login web -a myorg

# Deploy project metadata
sf project deploy start -o myorg
```

After deployment:

1. Open Lightning App Builder.
2. Use the included `Agentforce_Workspace` flexipage or place `agentforceWorkspace` on a custom page.
3. Assign the page to the target app and user audience.

## Operational Characteristics

| Concern | Current behavior |
|---|---|
| Query security | Executes in user context and respects Salesforce security boundaries |
| Result rendering | Native Lightning UI with records, actions, charts, and links |
| Empty results | Treated as analyzable outcomes, not necessarily failures |
| Retry behavior | Multi-attempt reasoning loop with dynamic diagnostics |
| Prompt cost control | Intent-gated modular prompt sections |
| Mutations | Explicit action JSON path for create and update operations |
| Session continuity | Client-side conversation and model-selection persistence |

## Testing and Validation

This codebase includes Apex test coverage for the core workspace services and shared business-intelligence utilities. Beyond unit coverage, the architecture is designed for scenario testing across:

- analytical questions
- account-scoped activity summaries
- comparison flows
- create and update commands
- vague requests that should trigger clarification
- failure scenarios involving malformed or unsupported SOQL

## Project Positioning

Agentforce Workspace is best understood as a deep software systems project at the intersection of:

- Agentforce interaction design
- Salesforce data security
- Apex service decomposition
- Lightning Web Component experience design
- controlled use of foundation models in enterprise workflows

It demonstrates that advanced conversational software on Salesforce does not need to choose between ambition and discipline. With the right architecture, a Lightning application can reason about intent, retrieve data safely, adapt to model failure, and render operationally useful outcomes in a form that business users can trust.

## License

MIT. See [LICENSE](LICENSE) for details.
