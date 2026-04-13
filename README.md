# Agentforce Workspace

Agentforce Workspace is a production-oriented conversational analytics surface for Salesforce. It combines Lightning Web Components, Apex orchestration, and the Salesforce Models API to turn natural language into secure data retrieval, structured record actions, and high-value analysis inside Lightning Experience.

This project is not a chat wrapper around SOQL. It is an attempt to build a serious reasoning interface for CRM and service operations: schema-aware, user-context-aware, resilient under ambiguity, and disciplined about how AI is allowed to interact with enterprise data.

While Agentforce Workspace is technically a proof-of-concept, there are many components that might be new or re-envisioned design patterns here. The goal of this is to spark ideas, conversation, and find a way to serve users in LEX with an incredible AI-first, multimodal experience.

![Salesforce API v65.0](https://img.shields.io/badge/Salesforce%20API-v65.0-blue)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

---

## Executive Summary

Agentforce Workspace gives business users a single surface where they can:

- ask analytical questions in natural language
- issue operational commands such as record updates or task creation
- request drafted content such as activity summaries or emails
- inspect structured result sets in native Salesforce UI
- receive follow-up guidance when intent is unclear or data is unavailable

The current architecture reflects a substantial shift from a simple NL-to-SOQL pipeline toward a multi-pass reasoning system with explicit intent classification, adaptive retry behavior, prompt modularity, dynamic schema introspection, and UI states that accurately reflect what the system is doing.

---

## Why This Project Matters

Most Salesforce AI prototypes fail in predictable ways:

- they treat every input as a question
- they rely on one large prompt that tries to do everything
- they break when generated SOQL fails
- they confuse content generation with record mutation
- they expose brittle UX states when results are empty or partial
- they hardcode object and field lists that go stale as the org evolves

Agentforce Workspace is designed to address those failure modes directly. The goal is a system that can interpret user intent, choose the right execution path, recover from model mistakes, and either produce an answer or explain clearly why it cannot — against any object the running user can access.

---

## System Architecture

### High-Level Runtime

```text
+--------------------+        +-----------------------------------+
| Lightning UI       |        | Apex Orchestration Layer          |
| agentforceWorkspace|        | AgentforceWorkspaceController     |
+---------+----------+        +----------------+------------------+
          |                                  |
          | user input                       |
          v                                  v
          |                        +------------------------------+
          |                        | Pass 0: Intent Classification|
          |                        | Cheap model, fast decision   |
          |                        +-------------+----------------+
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

---

## Latest Changes (April 2026)

### AgentforceWorkspaceSchemaService — Dynamic Schema Introspection

The most significant addition is a new service class that replaces all hardcoded object lists and field maps throughout the workspace. Previously, objects like `Account`, `Opportunity`, `Task`, and `Case` had their icon names, name fields, sort fields, and display columns defined as static constants spread across `BusinessIntelligence` and `AgentforceWorkspaceQueryService`. That approach worked but broke silently when custom objects were involved and required code changes whenever a new object needed first-class support.

`AgentforceWorkspaceSchemaService` centralizes all of that into a single describe-based lookup layer with:

- **Transaction-scoped caching** — one `getGlobalDescribe()` call per transaction, with per-object `DescribeSObjectResult` cached in a static map
- **Well-known overrides** — curated maps for icons, name fields, list fields, and sort configuration on core CRM objects where generic describe-based defaults are suboptimal (e.g. `Task` uses `Subject` not `Name`, `Case` uses `CaseNumber`)
- **Dynamic fallback** — for any object not in the override maps, the service resolves icon, name field, sort field, and display columns via `DescribeSObjectResult` and a priority-ordered field selection heuristic
- **Preferred tab order** — known objects maintain a fixed display order in the sidebar; unknown or custom objects are appended alphabetically by label
- **Custom object support** — `listAccessibleCustomObjects()` returns lightweight object metadata for the org's custom objects, used to inject dynamic task suggestions on the landing page
- **Schema context for LLM** — `buildCustomObjectSchemaContext()` produces a structured field/relationship summary for any custom object, injected into the prompt so the model can generate accurate SOQL without guessing field names

This service is now used by `AgentforceWorkspaceQueryService`, `AgentforceWorkspaceRecordCreator`, and `BusinessIntelligence`. The effect is that the workspace can now query, display, create, and update records on any accessible object in the org — standard or custom — without requiring any code changes.

### Dynamic Task Suggestions on Landing Page

The landing page task suggestions grid is now org-aware. On load, `getOrgSchemaContext` is called to retrieve a list of accessible custom objects. Up to 5 of those objects are injected as additional task suggestions (e.g. "Show me recent ServiceRequest__c records"). The static suggestions are shuffled using the current hour as a seed so different useful prompts surface across work sessions.

### Usage Estimate Tracking

A new Usage Estimate section in the sidebar tracks cumulative Flex Credit consumption per session. The component estimates token counts from message content and maps model IDs to their credit tier (`basic`, `standard`, `advanced`) to produce a per-request and cumulative credit estimate. This is a client-side estimate, not a billing-accurate figure, but it gives users and admins a useful signal about relative cost across model choices.

This component was built, designed, and assembled by the inimitable [@Hunter Reh](https://github.com/hrehcodes/) and was first used in his fantastic [Agentforce Record Insights](https://github.com/hrehcodes/models-api-lwc-solution-pattern) design pattern.

### Updated Model Roster

The workspace now reflects the current Salesforce Models API model IDs:

| Model | Provider | Tier | API ID |
|---|---|---|---|
| Gemini 3.1 Flash | Google Vertex AI | basic | `sfdc_ai__DefaultVertexAIGemini31FlashLite` |
| Gemini 3.1 Pro | Google Vertex AI | standard | `sfdc_ai__DefaultVertexAIGeminiPro31` |
| GPT-5.2 | OpenAI | standard | `sfdc_ai__DefaultGPT52` |
| GPT-5.4 | OpenAI | standard | `sfdc_ai__DefaultGPT54` |
| Nemotron 3 Nano | NVIDIA Bedrock | basic | `sfdc_ai__DefaultBedrockNvidiaNemotronNano330b` |
| Sonnet 4.5 | Anthropic Bedrock | standard | `sfdc_ai__DefaultBedrockAnthropicClaude45Sonnet` |
| Opus 4.5 | Anthropic Bedrock | advanced | `sfdc_ai__DefaultBedrockAnthropicClaude45Opus` |

The intent classifier (Pass 0) always uses the cheapest fast-path model regardless of user selection. User-selected models are applied to reasoning (Pass 1-3) and analysis passes.

### Controller: getOrgSchemaContext

A new controller method `getOrgSchemaContext` is exposed to the LWC. It uses `AgentforceWorkspaceSchemaService.listAccessibleCustomObjects()` to return lightweight object metadata for dynamic schema injection on the landing page and into prompts.

---

## Core Design Principles

### 1. Intent before execution

The system does not assume that every utterance is a report request. A user message might be a query, a command, a comparison, a composition request, a follow-up confirmation, or a vague statement that requires clarification. That distinction is handled explicitly by `AgentforceWorkspaceReasoningEngine`, not left implicit inside one oversized prompt.

### 2. Recovery over brittleness

Generated SOQL is fallible. The system is designed to recover from non-groupable fields in aggregate queries, invalid field or relationship references, object resolution mistakes, malformed SOQL structure, and semantic mismatches between user wording and org data.

### 3. Security by execution context

Queries are executed as the running user and supplementary queries use `WITH USER_MODE` where appropriate. The architecture respects sharing, CRUD, field visibility, and object availability in the connected org.

### 4. Schema-driven, not hardcode-driven

The workspace is designed to work against any org without configuration. Object support is not a list that must be maintained — it is resolved dynamically from the org's own metadata at runtime.

### 5. Structured UX, not opaque AI output

The frontend does not merely dump model text into a chat bubble. It renders progress stages, related record tabs, created or updated record cards, charts, geographic map views, follow-up suggestions, failure explanations with alternatives, and usage estimates.

---

## Apex Service Architecture

| Class | Responsibility |
|---|---|
| `AgentforceWorkspaceController` | Public Apex entry point for `buildQueries`, `analyzeResults`, `classifyIntent`, and user-context methods including `getOrgSchemaContext` |
| `AgentforceWorkspaceReasoningEngine` | Pass 0 intent classification and Pass 1-3 reasoning loop |
| `AgentforceWorkspaceAnalysisService` | Prompt construction, Models API calls, analysis prompt generation, response parsing |
| `AgentforceWorkspaceQueryService` | Query execution support, supplementary queries, record tab building, formatting |
| `AgentforceWorkspaceLinkService` | Safe record-link injection into model-generated HTML |
| `AgentforceWorkspaceRecordCreator` | Create/update action parsing, execution, post-create follow-up field completion |
| `AgentforceWorkspaceSchemaService` | Dynamic schema introspection — icons, name fields, list fields, sort config, custom object catalog |
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
   |        +--> AgentforceWorkspaceSchemaService
   |
   +--> AgentforceWorkspaceQueryService
   |        |
   |        +--> AgentforceWorkspaceSchemaService
   |
   +--> AgentforceWorkspaceLinkService
   +--> AgentforceWorkspaceRecordCreator
   |        |
   |        +--> AgentforceWorkspaceSchemaService
   |
   +--> AgentforceWorkspaceModels
   +--> AgentforceWorkspaceSchemaService
```

---

## Prompt Architecture

### Prompt Modules

| Module | Included when | Purpose |
|---|---|---|
| Core SOQL rules | Always | Baseline query constraints, date logic, grouping rules, object resolution |
| Create/update rules | `CREATE`, `UPDATE`, `FOLLOWUP` | Structured action JSON for record creation and updates |
| Compose rules | `COMPOSE` | Drafting and summarization behavior without accidental record mutation |
| Complex query patterns | `QUERY`, `COMPARE`, `COMPOSE` | Multi-object retrieval patterns such as meetings to accounts to cases |
| Custom object schema | When custom objects are mentioned | Field names, types, and relationships for accurate SOQL generation |
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
  -> attach schema context (dynamic, from org metadata)
  -> attach only high-value examples
  -> generate more precise output

Future model
------------
Much better (hopefully)
```

### Dynamic Error Diagnosis

The reasoning loop sends the actual failure back to the model, including the failed SOQL and the platform error text. That allows the retry pass to reason about specific issues like `Field Subject is not groupable`, `No such column`, unsupported objects, or malformed relationship paths.

---

## Intent Taxonomy

The intent classifier returns a structured `IntentResult` with `intent`, `plan`, `confidence`, and `clarification`.

| Intent | Meaning |
|---|---|
| `QUERY` | Retrieve or analyze Salesforce data |
| `CREATE` | Create a record |
| `UPDATE` | Modify an existing record |
| `COMPARE` | Compare entities or metrics |
| `COMPOSE` | Draft or summarize content from retrieved data |
| `FOLLOWUP` | Continue a pending action or respond to an existing workflow |
| `CLARIFY` | Ask the user for a more specific request |

---

## LWC Surface Architecture

| Bundle | Responsibility |
|---|---|
| `agentforceWorkspace` | Main shell, chat timeline, progress system, model picker, caching, usage tracking, org-schema context loading, orchestration |
| `investigatorRecordList` | Tabbed record grids with sorting, navigation, expandable list views, and export paths into native Salesforce reports |
| `investigatorCreatedRecord` | Action-result card for created, updated, or deleted records |
| `investigatorChart` | Chart rendering for structured numeric summaries |
| `investigatorMapView` | Geographic visualization for records with address data |

### Sidebar State Model

```text
Details Panel
  |
  +--> Progress (agent steps)
  +--> Related Records  (investigatorRecordList)
  +--> Record Action
         |
         +--> Created Record   (investigatorCreatedRecord, action-type="created")
         +--> Updated Record   (investigatorCreatedRecord, action-type="updated")
         +--> Deleted Record   (investigatorCreatedRecord, action-type="deleted")
  +--> Chart Visualization     (investigatorChart)
  +--> Geographic Map          (investigatorMapView)
  +--> Usage Estimate          (token count + Flex Credit estimate)
```

The workspace tracks action semantics explicitly. A successful update no longer renders as a creation event. The usage estimate section is collapsible and updates incrementally per turn.

Related record lists also connect cleanly to Salesforce reporting. When the workspace surfaces a structured set of related records, users can move that same context into native reports instead of treating the list as a dead-end view. That keeps the experience aligned with standard Salesforce analytics workflows while still preserving the conversational entry point that brought the data into focus.

---

## Fuzzy Matching and Retrieval Robustness

A notable improvement in the current architecture is explicit support for fuzzy account-name resolution. In enterprise CRM, the user rarely types the legal or exact account name. The prompt and examples explicitly instruct the model to use `LIKE '%keyword%'` patterns through account subqueries for child-object retrieval, especially for `Task`, `Event`, `Contact`, `Opportunity`, and `Case`. This materially improves activity summaries, contact lookups, and account-scoped analysis.

---

## Repository Layout

```text
force-app/main/default/
├── classes/
│   ├── AgentforceWorkspaceController.cls
│   ├── AgentforceWorkspaceController.cls-meta.xml
│   ├── AgentforceWorkspaceReasoningEngine.cls
│   ├── AgentforceWorkspaceReasoningEngine.cls-meta.xml
│   ├── AgentforceWorkspaceAnalysisService.cls
│   ├── AgentforceWorkspaceAnalysisService.cls-meta.xml
│   ├── AgentforceWorkspaceQueryService.cls
│   ├── AgentforceWorkspaceQueryService.cls-meta.xml
│   ├── AgentforceWorkspaceLinkService.cls
│   ├── AgentforceWorkspaceLinkService.cls-meta.xml
│   ├── AgentforceWorkspaceRecordCreator.cls
│   ├── AgentforceWorkspaceRecordCreator.cls-meta.xml
│   ├── AgentforceWorkspaceSchemaService.cls          ← new
│   ├── AgentforceWorkspaceSchemaService.cls-meta.xml ← new
│   ├── AgentforceWorkspaceModels.cls
│   ├── AgentforceWorkspaceModels.cls-meta.xml
│   ├── BusinessIntelligence.cls
│   ├── BusinessIntelligence.cls-meta.xml
│   └── test classes (AgentforceWorkspaceControllerTest, AgentforceWorkspaceModelsTest,
│                      AgentforceWorkspaceServiceTest, BusinessIntelligenceTest)
├── lwc/
│   ├── agentforceWorkspace/
│   ├── investigatorRecordList/
│   ├── investigatorCreatedRecord/
│   ├── investigatorChart/
│   └── investigatorMapView/
├── flexipages/
│   └── Agentforce_Workspace.flexipage-meta.xml
└── staticresources/
    ├── AgentforceRGBIcon.png
    ├── Gemini.png
    ├── OpenAI.svg
    ├── Claude.svg
    └── nvidia.png
```

---

## Operational Characteristics

| Concern | Current behavior |
|---|---|
| Query security | Executes in user context, respects Salesforce security boundaries |
| Schema resolution | Dynamic describe-based — works with any accessible standard or custom object |
| Result rendering | Native Lightning UI with records, actions, charts, maps, and links |
| Empty results | Treated as analyzable outcomes, not necessarily failures |
| Retry behavior | Multi-attempt reasoning loop with dynamic diagnostics |
| Prompt cost control | Intent-gated modular prompt sections |
| Mutations | Explicit action JSON path for create and update operations |
| Session continuity | Client-side conversation and model-selection persistence |
| Usage tracking | Per-session Flex Credit estimate displayed in sidebar |

---

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

---

## Testing and Validation

This codebase includes Apex test coverage for the core workspace services and shared business-intelligence utilities. Beyond unit coverage, the architecture is designed for scenario testing across:

- analytical questions
- account-scoped activity summaries
- comparison flows
- create and update commands
- vague requests that should trigger clarification
- failure scenarios involving malformed or unsupported SOQL
- custom object queries resolved dynamically at runtime

---

## Project Positioning

Agentforce Workspace is best understood as a deep software systems project at the intersection of:

- Agentforce interaction design
- Salesforce data security
- Apex service decomposition
- Lightning Web Component experience design
- controlled use of foundation models in enterprise workflows
- dynamic schema introspection for org-agnostic operation

It demonstrates that advanced conversational software on Salesforce does not need to choose between ambition and discipline. With the right architecture, a Lightning application can reason about intent, retrieve data safely, adapt to model failure, and render operationally useful outcomes in a form that business users can trust — against any object in any org, without requiring code changes to support new data models.

---

## License

This project was first designed, created, and built by Dylan Andersen - a Senior Solution Engineer at Salesforce, working with Agentforce + Data 360.
Countless people have influenced this project and played a huge role but special thanks to Sreeram Nambiar, Hunter Reh, Eddie Broadhead, Brendan Sheridan, Scott Hendrix, and countless others for the inspiration and support.

No support is provided. Please email dylan.andersen@salesforce.com or create a PR with feedback.

MIT. See [LICENSE](LICENSE) for details.
