# Agentforce Workspace

A conversational AI-powered business intelligence workspace for Salesforce.

![Salesforce API v65.0](https://img.shields.io/badge/Salesforce%20API-v65.0-blue)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

<!-- Screenshot placeholder — replace with your own -->
<!-- ![Agentforce Workspace](docs/screenshot.png) -->

## What It Does

Agentforce Workspace lets users ask business questions in plain English inside Salesforce. It translates natural language into SOQL, executes queries as the running user, and returns AI-generated analysis — all within a single Lightning component.

- **Natural language → SOQL → AI analysis** in one conversation flow
- **Multi-model support** — switch between 7 models (Gemini, GPT, Claude, NVIDIA Nemotron) via the Salesforce Models API
- **Interactive record list views** with sortable, resizable columns across 8 core CRM objects
- **Record creation** directly from chat responses
- **Session caching** and conversation history that persist across page navigations
- **Suggested follow-ups** after every response

## Architecture

Agentforce Workspace uses a **two-stage AI pipeline** powered by the Salesforce Models API:

```
User question (natural language)
         |
         v
  +-----------------+        +-------+        +--------------+        +---------+
  | NL question     |  --->  |  LLM  |  --->  | SOQL queries |  --->  | Execute |
  | + schema context|        |       |        |              |        | as user |
  +-----------------+        +-------+        +--------------+        +---------+
                                                     ^                     |
                                                     |    error feedback   |
                                                     +---------------------+
                                                       (auto-retry on failure)
         |
         v
  +-----------------+        +-------+        +----------------------------+
  | Query results   |  --->  |  LLM  |  --->  | HTML analysis with         |
  | + chat history  |        |       |        | record links + follow-ups  |
  +-----------------+        +-------+        +----------------------------+
```

**Stage 1 — `buildQueries`:** Translates the user's question + org schema into SOQL, executes as the running user. Failed queries are automatically retried with the error fed back to the LLM for self-correction.

**Stage 2 — `analyzeResults`:** Sends query results + conversation history to the LLM, which returns formatted analysis with clickable record links and suggested follow-up questions.

All queries run as the current user, respecting sharing rules and field-level security. 26 objects supported out of the box (13 CRM + 13 ITSM/service), plus any custom objects.

## Component Map

```
force-app/main/default/
├── lwc/
│   ├── agentforceWorkspace/        ← Main LWC: landing page + chat + model picker
│   ├── agentforceChat/             ← Standalone chat variant
│   ├── investigatorRecordList/     ← Tabbed record list with column resize & sort
│   └── investigatorCreatedRecord/  ← Record creation confirmation card
├── classes/
│   ├── AgentforceInvestigatorController.cls  ← Apex orchestrator (chat ↔ BI)
│   ├── BusinessIntelligence.cls              ← Invocable BI action (Agentforce-compatible)
│   └── BusinessIntelligenceTest.cls          ← Test coverage
├── flexipages/
│   └── Agentforce_Workspace.flexipage-meta.xml  ← Pre-built App Page
└── staticresources/                ← Model logos (Gemini, OpenAI, Claude, NVIDIA, Agentforce icons)
```

## Supported AI Models

| Model | Provider | Model API ID |
|-------|----------|-------------|
| Gemini Flash 3.0 | Google (Vertex AI) | `sfdc_ai__DefaultVertexAIGemini30Flash` |
| Gemini Pro 3.0 | Google (Vertex AI) | `sfdc_ai__DefaultVertexAIGeminiPro30` |
| GPT-5 | OpenAI | `sfdc_ai__DefaultGPT5` |
| GPT-5.2 | OpenAI | `sfdc_ai__DefaultGPT52` |
| Nemotron 3 Nano | NVIDIA (Bedrock) | `sfdc_ai__DefaultBedrockNvidiaNemotronNano330b` |
| Sonnet 4.5 | Anthropic (Bedrock) | `sfdc_ai__DefaultBedrockAnthropicClaude45Sonnet` |
| Opus 4.5 | Anthropic (Bedrock) | `sfdc_ai__DefaultBedrockAnthropicClaude45Opus` |

## Prerequisites

- Salesforce org with **Einstein / Models API** enabled
- API version **65.0+**
- Models API access configured for the models you want to use (see [Salesforce Models API docs](https://developer.salesforce.com/docs/einstein/genai/guide/models-api.html))

## Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/dylandersen/agentforce-workspace.git
cd agentforce-workspace

# 2. Authenticate to your org
sf org login web -a myorg

# 3. Deploy
sf project deploy start -o myorg
```

Then in Salesforce:

4. Open **Setup → Lightning App Builder** and create a new App Page (or use the included `Agentforce_Workspace` flexipage)
5. Add the `agentforceWorkspace` component to the page
6. Assign the page to a Lightning app and navigate to it

## Configuration

| Setting | Default | Location |
|---------|---------|----------|
| Default model | Gemini Flash 3.0 | Model picker in UI (persists to localStorage) |
| Session cache TTL | 30 minutes | `CACHE_MAX_AGE` in `agentforceWorkspace.js` |
| Max conversation turns | 10 | `MAX_HISTORY_TURNS` in `agentforceWorkspace.js` |
| Max SOQL result rows | 200 | `MAX_QUERY_LIMIT` in `BusinessIntelligence.cls` |

## Key Features

### Multi-Model Switching
Swap between 7 AI models mid-conversation using the model picker. Your selection persists across sessions.

### Smart Record Linking
Record names in AI analysis are rendered as clickable links that navigate directly to the Salesforce record.

### Auto-Retry
When a generated SOQL query fails, the error is automatically fed back to the LLM for self-correction before returning a response.

### Conversational Follow-Ups
Every response includes a contextual follow-up question and 3 suggestion pills to keep the analysis flowing.

### Interactive Record Lists
Query results populate tabbed record list views with sortable columns, resizable headers, and direct navigation to records.

### Record Creation
The AI can create records (e.g., Tasks, Events) directly from the conversation, with a confirmation card displayed in chat.

### Session Caching
Conversation state, selected model, and scroll position persist across page navigations via localStorage.

## Project Structure

```
agentforce-workspace/
├── force-app/
│   └── main/default/
│       ├── classes/
│       │   ├── AgentforceInvestigatorController.cls
│       │   ├── AgentforceInvestigatorController.cls-meta.xml
│       │   ├── BusinessIntelligence.cls
│       │   ├── BusinessIntelligence.cls-meta.xml
│       │   ├── BusinessIntelligenceTest.cls
│       │   └── BusinessIntelligenceTest.cls-meta.xml
│       ├── flexipages/
│       │   └── Agentforce_Workspace.flexipage-meta.xml
│       ├── lwc/
│       │   ├── agentforceChat/
│       │   │   ├── agentforceChat.css
│       │   │   ├── agentforceChat.html
│       │   │   ├── agentforceChat.js
│       │   │   └── agentforceChat.js-meta.xml
│       │   ├── agentforceWorkspace/
│       │   │   ├── agentforceWorkspace.css
│       │   │   ├── agentforceWorkspace.html
│       │   │   ├── agentforceWorkspace.js
│       │   │   └── agentforceWorkspace.js-meta.xml
│       │   ├── investigatorCreatedRecord/
│       │   │   ├── investigatorCreatedRecord.css
│       │   │   ├── investigatorCreatedRecord.html
│       │   │   ├── investigatorCreatedRecord.js
│       │   │   └── investigatorCreatedRecord.js-meta.xml
│       │   └── investigatorRecordList/
│       │       ├── investigatorRecordList.css
│       │       ├── investigatorRecordList.html
│       │       ├── investigatorRecordList.js
│       │       └── investigatorRecordList.js-meta.xml
│       └── staticresources/
│           ├── AgentforceIcon.png
│           ├── AgentforceRGBIcon.png
│           ├── Claude.svg
│           ├── Gemini.png
│           ├── nvidia.png
│           └── OpenAI.svg
└── sfdx-project.json
```

## License

MIT — see [LICENSE](LICENSE) for details.
