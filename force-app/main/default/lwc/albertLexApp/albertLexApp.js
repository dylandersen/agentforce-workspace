import { LightningElement, track } from "lwc";

/* ─────────────────────────────────────────────────────────
   Navigation
   ───────────────────────────────────────────────────────── */
const NAV_ITEMS = [
  { id: "home",        label: "Home",       icon: "utility:home",           section: "primary" },
  { id: "chat",        label: "Chat",       icon: "utility:chat",           section: "primary" },
  { id: "playbooks",   label: "Playbooks",  icon: "utility:knowledge_base", section: "primary" },
  { id: "automations", label: "Autonomous", icon: "utility:target",         section: "primary" },
  { id: "workflows",   label: "Workflows",  icon: "utility:flow",           section: "primary" },
  { id: "agents",      label: "Agents",     icon: "utility:agent_astro",    section: "build"   },
  { id: "skills",      label: "Skills",     icon: "utility:magicwand",      section: "build"   }
];

/* ─────────────────────────────────────────────────────────
   Home — pulse metrics
   Each metric is deliberate: a number that changes behavior.
   ───────────────────────────────────────────────────────── */
const PULSE_METRICS = [
  {
    id: "pipeline",
    label: "Pipeline",
    value: "$2.48M",
    delta: "+12.4%",
    deltaTone: "up",
    sub: "vs. 30d ago",
    sparkline: [32, 38, 41, 37, 44, 48, 52, 49, 56, 61, 58, 64]
  },
  {
    id: "risk",
    label: "At risk",
    value: "4",
    delta: "2 new",
    deltaTone: "warn",
    sub: "deals need a nudge",
    sparkline: [2, 2, 3, 2, 1, 2, 2, 3, 3, 4, 4, 4]
  },
  {
    id: "meetings",
    label: "Meetings",
    value: "3",
    delta: "next 10:30",
    deltaTone: "neutral",
    sub: "today",
    sparkline: [1, 2, 1, 3, 2, 4, 3, 2, 5, 3, 2, 3]
  },
  {
    id: "tasks",
    label: "Open tasks",
    value: "12",
    delta: "−3 since Fri",
    deltaTone: "down",
    sub: "across 7 accounts",
    sparkline: [18, 17, 16, 18, 15, 15, 14, 13, 13, 12, 12, 12]
  }
];

/* Subtle "morning briefing" — the one sentence that greets you */
const BRIEFING_LINES = [
  "3 agents are watching pipeline signals.",
  "Overnight: 2 drafts ready for your review.",
  "Quiet morning — nothing needs your attention yet.",
  "1 renewal risk surfaced since Friday."
];

/* What Albert is actively monitoring — each one has a live pulse */
const WATCHING_ITEMS = [
  {
    id: "w1",
    title: "14 accounts for renewal signals",
    meta: "NPS · product usage · support volume",
    active: true,
    lastSignal: "2h ago"
  },
  {
    id: "w2",
    title: "6 deals for stage velocity",
    meta: "stalls, backsteps, and quiet stakeholders",
    active: true,
    lastSignal: "38m ago"
  },
  {
    id: "w3",
    title: "Your calendar for prep opportunities",
    meta: "meetings without briefings in the next 48h",
    active: true,
    lastSignal: "live"
  },
  {
    id: "w4",
    title: "3 segments for expansion triggers",
    meta: "usage thresholds and feature adoption",
    active: false,
    lastSignal: "paused"
  }
];

/* Recent agent activity — the "what's been running" feed */
const ACTIVITY_FEED = [
  { id: "a1", time: "09:12", agent: "analyst",  title: "Pipeline review completed",         status: "ok",  detail: "12 opportunities · 2 flagged" },
  { id: "a2", time: "08:45", agent: "sdr",      title: "Prepped 3 meetings for today",      status: "ok",  detail: "Acme, Contoso, Initech" },
  { id: "a3", time: "07:30", agent: "analyst",  title: "Weekly forecast rolled up",         status: "ok",  detail: "Commit $1.9M · Best case $2.6M" },
  { id: "a4", time: "Yest.", agent: "writer",   title: "Drafted 2 follow-ups",              status: "review", detail: "waiting on your review" },
  { id: "a5", time: "Yest.", agent: "researcher", title: "Research on 4 new accounts",      status: "ok",  detail: "added to CRM with sources" },
  { id: "a6", time: "Yest.", agent: "sdr",      title: "Logged 11 calls to Salesforce",     status: "ok",  detail: "auto-enriched with next steps" }
];

const LEARNING_STATS = [
  { key: "playbooks",   label: "Playbooks",   value: 0  },
  { key: "workflows",   label: "Workflows",   value: 0  },
  { key: "automations", label: "Automations", value: 0  },
  { key: "skills",      label: "Skills",      value: 41 },
  { key: "patterns",    label: "Patterns",    value: 8  }
];

/* ─────────────────────────────────────────────────────────
   Chat — capability groupings + recent sessions
   (No suggestion chips. Albert teaches its shape instead.)
   ───────────────────────────────────────────────────────── */
const CHAT_CAPABILITIES = [
  {
    id: "pipeline",
    eyebrow: "Pipeline",
    title: "Know where to focus",
    example: "What deals are at risk this quarter and why?",
    skills: "8 skills"
  },
  {
    id: "accounts",
    eyebrow: "Accounts",
    title: "Go deep on any account",
    example: "Give me a 360° read on Acme — health, risks, opportunities.",
    skills: "11 skills"
  },
  {
    id: "drafts",
    eyebrow: "Drafts",
    title: "Write, summarize, handoff",
    example: "Draft a renewal email to the Contoso economic buyer.",
    skills: "9 skills"
  },
  {
    id: "research",
    eyebrow: "Research",
    title: "Find and verify anything",
    example: "Who just got hired at Initech and what signals a buying window?",
    skills: "6 skills"
  }
];

const CHAT_SESSIONS = [
  { id: "s1", when: "Yesterday 3:42 PM", title: "Pipeline review for Q2",        turns: 12, active: false },
  { id: "s2", when: "Yesterday 11:15 AM", title: "Draft QBR deck — Cirrus",      turns: 8,  active: false },
  { id: "s3", when: "Mon 4:08 PM",        title: "Research: Octane rebrand",     turns: 17, active: false },
  { id: "s4", when: "Fri 2:22 PM",        title: "Summarize weekly 1:1s",         turns: 6,  active: false }
];

const CHAT_MODES = [
  { id: "ask",  label: "Ask",  desc: "Answer with context"  },
  { id: "plan", label: "Plan", desc: "Draft a playbook"     },
  { id: "act",  label: "Act",  desc: "Run work in your CRM" }
];

/* ─────────────────────────────────────────────────────────
   Playbooks — template gallery with visible step-chains
   ───────────────────────────────────────────────────────── */
const PLAYBOOK_TEMPLATES = [
  {
    id: "p-qbr",
    name: "QBR Preparation",
    tagline: "Compile a customer-ready QBR in minutes.",
    steps: ["Pull account", "Analyze", "Draft deck", "Review", "Send"],
    runtime: "~8 min",
    usage: "used 142× this month",
    category: "Customer"
  },
  {
    id: "p-pipe",
    name: "Weekly Pipeline Review",
    tagline: "Surface at-risk deals and suggested nudges.",
    steps: ["Query CRM", "Score risk", "Rank", "Draft notes"],
    runtime: "~4 min",
    usage: "used 318× this month",
    category: "Pipeline"
  },
  {
    id: "p-prospect",
    name: "Net-new Prospecting",
    tagline: "Enrich, qualify, and queue outreach.",
    steps: ["Research", "Score", "Draft", "Log CRM"],
    runtime: "~6 min / lead",
    usage: "used 76× this month",
    category: "Sales"
  },
  {
    id: "p-renewal",
    name: "Renewal Risk Sweep",
    tagline: "Catch silent churn before it happens.",
    steps: ["Monitor", "Detect", "Summarize", "Alert owner"],
    runtime: "continuous",
    usage: "used 44× this month",
    category: "Customer"
  },
  {
    id: "p-comp",
    name: "Competitive Brief",
    tagline: "Fast read on any competitor from your data.",
    steps: ["Gather", "Analyze win/loss", "Synthesize"],
    runtime: "~3 min",
    usage: "used 52× this month",
    category: "Research"
  },
  {
    id: "p-onboard",
    name: "New-customer Onboarding",
    tagline: "Kick off a tailored 30/60/90 for every close.",
    steps: ["Pull deal", "Design plan", "Invite team", "Schedule"],
    runtime: "~5 min",
    usage: "used 28× this month",
    category: "Customer"
  }
];

/* ─────────────────────────────────────────────────────────
   Autonomous Work — delegation templates + timeline
   ───────────────────────────────────────────────────────── */
const AUTONOMOUS_SUMMARY = [
  { key: "active",    label: "Active",    value: 0 },
  { key: "scheduled", label: "Scheduled", value: 0 },
  { key: "today",     label: "Today",     value: 0 },
  { key: "month",     label: "This month", value: 0 }
];

const DELEGATION_TEMPLATES = [
  {
    id: "d-daily-pipe",
    name: "Daily pipeline review",
    cadence: "Every weekday · 7:30 AM",
    description: "Albert queries your opportunities, flags risk, and emails a digest before your first meeting.",
    owner: "analyst",
    runtime: "~2 min"
  },
  {
    id: "d-weekly-digest",
    name: "Weekly stakeholder digest",
    cadence: "Fridays · 4:00 PM",
    description: "Summarizes the week's account moves per stakeholder with a link back to CRM.",
    owner: "writer",
    runtime: "~4 min"
  },
  {
    id: "d-monthly-forecast",
    name: "Monthly forecast roll-up",
    cadence: "Last weekday · 5:00 PM",
    description: "Consolidates rep-level forecasts into a commit/best/worst tiered exec summary.",
    owner: "analyst",
    runtime: "~6 min"
  },
  {
    id: "d-meeting-prep",
    name: "48-hour meeting prep",
    cadence: "Triggered 48h before any customer meeting",
    description: "Drops a briefing into your calendar event with context, recent activity, and talking points.",
    owner: "researcher",
    runtime: "~3 min"
  }
];

/* ─────────────────────────────────────────────────────────
   Workflows — visual step chains for patterns
   ───────────────────────────────────────────────────────── */
const WORKFLOW_PATTERNS = [
  {
    id: "wf-triage",
    name: "Inbound triage",
    description: "Classify and route new inbound leads.",
    steps: [
      { label: "Receive",   role: "trigger" },
      { label: "Enrich",    role: "step" },
      { label: "Score",     role: "step" },
      { label: "Route",     role: "step" },
      { label: "Notify",    role: "end" }
    ]
  },
  {
    id: "wf-call",
    name: "Post-call follow-up",
    description: "From transcript to CRM updates to draft email.",
    steps: [
      { label: "Transcript", role: "trigger" },
      { label: "Summarize",  role: "step" },
      { label: "Log CRM",    role: "step" },
      { label: "Draft email", role: "end" }
    ]
  },
  {
    id: "wf-renewal",
    name: "Renewal signal",
    description: "Detect usage dips and alert the account owner.",
    steps: [
      { label: "Monitor", role: "trigger" },
      { label: "Detect",  role: "step" },
      { label: "Brief",   role: "step" },
      { label: "Alert",   role: "end" }
    ]
  },
  {
    id: "wf-qbr",
    name: "QBR generation",
    description: "Prepare a QBR deck from CRM and support data.",
    steps: [
      { label: "Pull",     role: "trigger" },
      { label: "Analyze",  role: "step" },
      { label: "Draft",    role: "step" },
      { label: "Review",   role: "step" },
      { label: "Export",   role: "end" }
    ]
  },
  {
    id: "wf-handoff",
    name: "Sales → CS handoff",
    description: "Generate and schedule a structured handoff.",
    steps: [
      { label: "Close won", role: "trigger" },
      { label: "Package",   role: "step" },
      { label: "Introduce", role: "step" },
      { label: "Schedule",  role: "end" }
    ]
  },
  {
    id: "wf-case",
    name: "Case escalation",
    description: "Route critical support cases with context.",
    steps: [
      { label: "Detect",   role: "trigger" },
      { label: "Classify", role: "step" },
      { label: "Enrich",   role: "step" },
      { label: "Escalate", role: "end" }
    ]
  }
];

/* ─────────────────────────────────────────────────────────
   Agents — built-in roster
   Monochrome initials, not colored icon tiles.
   ───────────────────────────────────────────────────────── */
const BUILTIN_AGENTS = [
  { id: "researcher",            name: "researcher",            role: "Research",  description: "Searches the web and knowledge bases to find information.",   tools: ["web_search", "knowledge", "scrape"],          model: "gpt-4.1-mini",  latency: "fast",   active: true },
  { id: "analyst",               name: "analyst",               role: "Analysis",  description: "Analyzes data and generates insights from structured information.", tools: ["knowledge", "code", "files"],            model: "gpt-4.1",       latency: "medium", active: true },
  { id: "writer",                name: "writer",                role: "Drafting",  description: "Creates and edits written content — emails, docs, reports.",  tools: ["web_search", "files"],                        model: "gpt-4.1",       latency: "medium", active: false },
  { id: "reviewer",              name: "reviewer",              role: "QA",        description: "Reviews documents, code, and content for quality and correctness.", tools: ["files", "knowledge", "code"],             model: "gpt-4.1-mini",  latency: "fast",   active: false },
  { id: "developer",             name: "developer",             role: "Engineering", description: "Writes, debugs, and runs code across languages.",             tools: ["files", "code", "web_search"],              model: "gpt-4.1",       latency: "medium", active: false },
  { id: "document",              name: "document",              role: "Documents", description: "Processes, parses, and extracts information from documents.",  tools: ["files", "knowledge", "doc_parser"],           model: "gpt-4.1-mini",  latency: "fast",   active: false },
  { id: "sdr",                   name: "sdr",                   role: "Sales dev", description: "Prospect research, outreach, and CRM updates.",                tools: ["web_search", "salesforce", "email"],         model: "gpt-4.1",       latency: "medium", active: true  },
  { id: "salesforce_specialist", name: "salesforce_specialist", role: "Platform",  description: "SOQL, record management, and automation across Salesforce.",   tools: ["salesforce", "knowledge"],                    model: "gpt-4.1",       latency: "medium", active: false }
];

/* ─────────────────────────────────────────────────────────
   Skills — 41 built-in, grouped by category for filters.
   ───────────────────────────────────────────────────────── */
const SKILL_CATEGORIES = [
  { id: "all",       label: "All"       },
  { id: "pipeline",  label: "Pipeline"  },
  { id: "customer",  label: "Customer"  },
  { id: "sales",     label: "Sales"     },
  { id: "research",  label: "Research"  },
  { id: "ops",       label: "Ops"       },
  { id: "content",   label: "Content"   }
];

const BUILTIN_SKILLS = [
  { id: "pipeline_review",   name: "Pipeline Review",             category: "pipeline", description: "Review Salesforce opportunities, analyze pipeline health, identify at-risk deals, and generate actionable reports.",       triggers: ["show me my pipeline", "pipeline review", "how's my pipeline", "what are my top opportunities today", "where should I focus first", "what deals are at risk"], uses: 318 },
  { id: "lead_research",     name: "Lead Research",               category: "sales",    description: "Research leads from Salesforce with company background, recent news, and qualification scoring.",                           triggers: ["research this lead", "tell me about this prospect", "what do we know about X"], uses: 142 },
  { id: "qbr_prep",          name: "QBR Preparation Package",     category: "customer", description: "Compile a full Quarterly Business Review package with account performance, metrics, wins/losses, and forward plan.",        triggers: ["prep QBR for X", "QBR package"], uses: 96 },
  { id: "competitor_analysis", name: "Competitor Analysis",       category: "research", description: "Analyze competitive landscape using CRM win/loss data, web research, and deal history.",                                   triggers: ["how are we doing vs X", "competitor brief"], uses: 52 },
  { id: "deal_risk",         name: "Deal Risk Assessment",        category: "pipeline", description: "Score individual deals on risk factors — activity gaps, stage velocity, competitive pressure, stakeholder engagement.",     triggers: ["is this deal at risk", "risk on Acme"], uses: 201 },
  { id: "account_health",    name: "Account Health Monitor",      category: "customer", description: "Calculate composite account health from support, engagement, product usage, renewal status, and NPS.",                     triggers: ["how is Contoso doing", "account health"], uses: 188 },
  { id: "soql_gen",          name: "SOQL Generation + Analysis",  category: "ops",      description: "Generate robust SOQL from intent, validate schema fields, execute queries, and synthesize CRM signals.",                   triggers: ["query opps where X", "write a SOQL"], uses: 67 },
  { id: "industry_region",   name: "Industry + Region Pipeline",  category: "pipeline", description: "Filter opportunities by industry and region using SOQL, then run pipeline-style analysis.",                                 triggers: ["fintech pipeline in emea"], uses: 34 },
  { id: "forecast_quota",    name: "Forecast vs Quota Analysis",  category: "pipeline", description: "Compare current pipeline and closed deals against quota targets, with gap analysis and attainment projections.",           triggers: ["how am I tracking to quota", "forecast gap"], uses: 111 },
  { id: "email_drafting",    name: "Email Drafting",              category: "content",  description: "Draft professional emails with appropriate tone, structure, and call-to-action based on context.",                         triggers: ["draft email to X", "reply to this"], uses: 624 },
  { id: "meeting_prep",      name: "Meeting Preparation",         category: "sales",    description: "Generate pre-meeting briefings with attendee background, recent activity, and suggested talking points.",                  triggers: ["prep my 2pm", "brief me on this meeting"], uses: 412 },
  { id: "call_summary",      name: "Call Summary + Next Steps",   category: "content",  description: "Summarize call transcripts into key takeaways, decisions, and assigned action items.",                                     triggers: ["summarize this call"], uses: 308 },
  { id: "activity_logger",   name: "Activity Logger",             category: "ops",      description: "Log calls, emails, and meetings to Salesforce with enriched context automatically.",                                       triggers: ["log this", "add to CRM"], uses: 892 },
  { id: "objection_handler", name: "Objection Handler",           category: "sales",    description: "Generate tailored responses to common sales objections based on product and persona context.",                              triggers: ["how do I handle X objection"], uses: 74 },
  { id: "proposal_builder",  name: "Proposal Builder",            category: "sales",    description: "Assemble proposals from templates, pricing data, and account-specific context.",                                           triggers: ["draft a proposal for X"], uses: 88 },
  { id: "renewal_monitor",   name: "Renewal Monitor",             category: "customer", description: "Track upcoming renewals, surface at-risk accounts, and recommend retention plays.",                                        triggers: ["renewals this quarter"], uses: 156 },
  { id: "expansion_finder",  name: "Expansion Opportunity Finder", category: "sales",   description: "Identify upsell and cross-sell opportunities across the installed base.",                                                   triggers: ["upsell opportunities"], uses: 63 },
  { id: "territory_planner", name: "Territory Planning",          category: "ops",      description: "Design and optimize territory assignments based on capacity, potential, and historical performance.",                     triggers: ["rebalance my territory"], uses: 12 },
  { id: "ramp_coaching",     name: "Rep Ramp Coaching",           category: "ops",      description: "Guide new hires through onboarding milestones and surface coaching moments from recorded calls.",                            triggers: ["coach this rep"], uses: 28 },
  { id: "win_loss",          name: "Win/Loss Analysis",           category: "research", description: "Aggregate win/loss reasons, stage conversion rates, and competitive trends for strategic review.",                          triggers: ["why are we losing"], uses: 46 },
  { id: "nps_analyzer",      name: "NPS + CSAT Analyzer",         category: "customer", description: "Parse customer satisfaction scores and verbatims for trending themes and escalation triggers.",                            triggers: ["what's our NPS trend"], uses: 52 },
  { id: "support_triage",    name: "Support Case Triage",         category: "customer", description: "Classify incoming cases, route to the right queue, and surface similar historical resolutions.",                           triggers: ["triage this case"], uses: 214 },
  { id: "knowledge_writer",  name: "Knowledge Article Drafting",  category: "content",  description: "Convert resolved cases and recurring questions into polished knowledge base articles.",                                    triggers: ["write KB from this"], uses: 31 },
  { id: "contract_reviewer", name: "Contract Review",             category: "ops",      description: "Extract key terms, flag non-standard clauses, and summarize risk for legal review.",                                       triggers: ["review this contract"], uses: 44 },
  { id: "quote_builder",     name: "Quote Builder",               category: "sales",    description: "Assemble quotes from product catalog, pricing rules, and opportunity context.",                                            triggers: ["build a quote"], uses: 128 },
  { id: "forecast_roll",     name: "Forecast Roll-up",            category: "pipeline", description: "Consolidate rep-level forecasts into manager and exec summaries with commit/best/worst tiers.",                            triggers: ["roll up the forecast"], uses: 22 },
  { id: "data_quality",      name: "Data Quality Sweep",          category: "ops",      description: "Detect duplicates, missing fields, and stale records; propose merges and enrichment actions.",                             triggers: ["clean up my data"], uses: 18 },
  { id: "segment_builder",   name: "Segment Builder",             category: "content",  description: "Construct target segments using CRM attributes, product usage, and engagement signals.",                                   triggers: ["build a segment of X"], uses: 26 },
  { id: "campaign_planner",  name: "Campaign Planner",            category: "content",  description: "Design multi-touch campaign plans aligned to audience, channel mix, and timing.",                                          triggers: ["plan a campaign for X"], uses: 19 },
  { id: "lead_scoring",      name: "Lead Scoring",                category: "sales",    description: "Score inbound leads on fit and intent to prioritize outreach.",                                                           triggers: ["score these leads"], uses: 174 },
  { id: "attribution_analyzer", name: "Marketing Attribution",    category: "research", description: "Trace pipeline influence across campaigns, channels, and touchpoints.",                                                    triggers: ["what drove this pipeline"], uses: 21 },
  { id: "ic_tracker",        name: "Compensation + IC Tracker",   category: "ops",      description: "Monitor incentive compensation earnings and forecast attainment.",                                                         triggers: ["my comp this quarter"], uses: 37 },
  { id: "churn_predictor",   name: "Churn Predictor",             category: "customer", description: "Predict account churn risk from engagement, support, and product signals.",                                               triggers: ["who's likely to churn"], uses: 83 },
  { id: "exec_summary",      name: "Executive Summary Writer",    category: "research", description: "Transform complex analyses into executive-ready narrative summaries.",                                                    triggers: ["summarize this for the exec team"], uses: 91 },
  { id: "meeting_minutes",   name: "Meeting Minutes",             category: "content",  description: "Generate structured minutes with decisions, action items, and owners from transcripts.",                                  triggers: ["minute this meeting"], uses: 144 },
  { id: "onboarding_plan",   name: "Customer Onboarding Plan",    category: "customer", description: "Assemble a tailored onboarding plan for new customers based on purchased products and segment.",                          triggers: ["onboarding plan for X"], uses: 29 },
  { id: "qbr_deck",          name: "QBR Deck Generator",          category: "customer", description: "Generate a QBR slide deck with performance metrics, wins/losses, and forward plan.",                                     triggers: ["QBR deck for X"], uses: 58 },
  { id: "sentiment_tracker", name: "Sentiment Tracker",           category: "customer", description: "Track customer sentiment trends across calls, emails, and support interactions.",                                        triggers: ["how does this customer feel"], uses: 41 },
  { id: "action_item_follower", name: "Action Item Follow-up",    category: "content",  description: "Track commitments from meetings and nudge owners as deadlines approach.",                                                 triggers: ["nudge my action items"], uses: 66 },
  { id: "crm_hygiene",       name: "CRM Hygiene Auditor",         category: "ops",      description: "Audit opportunity/contact/account data for compliance with CRM hygiene standards.",                                      triggers: ["audit my CRM"], uses: 14 },
  { id: "roi_calc",          name: "ROI Calculator",              category: "research", description: "Build ROI models for prospects using their business metrics and your product impact data.",                              triggers: ["calculate ROI for X"], uses: 24 }
];

/* ─────────────────────────────────────────────────────────
   Utility
   ───────────────────────────────────────────────────────── */
function greeting() {
  const h = new Date().getHours();
  if (h < 5)  return "Working late";
  if (h < 12) return "Good morning";
  if (h < 17) return "Good afternoon";
  if (h < 21) return "Good evening";
  return "Working late";
}

function sparklinePath(values, width = 64, height = 18) {
  if (!values || values.length < 2) return "";
  const max = Math.max(...values);
  const min = Math.min(...values);
  const range = max - min || 1;
  const step = width / (values.length - 1);
  return values
    .map((v, i) => {
      const x = (i * step).toFixed(2);
      const y = (height - ((v - min) / range) * height).toFixed(2);
      return `${i === 0 ? "M" : "L"}${x},${y}`;
    })
    .join(" ");
}

/* ─────────────────────────────────────────────────────────
   Component
   ───────────────────────────────────────────────────────── */
export default class AlbertLexApp extends LightningElement {
  /* state */
  @track activePage      = "home";
  @track sidebarChatQuery = "";
  @track expandedSkillId = null;
  @track selectedSkillId = "pipeline_review";
  @track skillFilter     = "all";
  @track skillSearch     = "";
  @track quickLaunch     = "";
  @track chatInput       = "";
  @track chatMode        = "ask";
  @track globalCommand   = "";

  connectedCallback() {
    /* nothing async yet; reserved for future LDS wire */
  }

  /* ───────── Nav ───────── */
  get primaryNav() {
    return NAV_ITEMS.filter((i) => i.section === "primary").map(this._decorateNav.bind(this));
  }

  get buildNav() {
    return NAV_ITEMS.filter((i) => i.section === "build").map(this._decorateNav.bind(this));
  }

  _decorateNav(item) {
    const active = item.id === this.activePage;
    return {
      ...item,
      navClass: `nav-item${active ? " is-active" : ""}`,
      ariaCurrent: active ? "page" : null
    };
  }

  get currentPageLabel() {
    const match = NAV_ITEMS.find((i) => i.id === this.activePage);
    return match ? match.label : "Home";
  }

  /* ───────── Page flags ───────── */
  get isHomePage()        { return this.activePage === "home"; }
  get isChatPage()        { return this.activePage === "chat"; }
  get isPlaybooksPage()   { return this.activePage === "playbooks"; }
  get isAutomationsPage() { return this.activePage === "automations"; }
  get isWorkflowsPage()   { return this.activePage === "workflows"; }
  get isAgentsPage()      { return this.activePage === "agents"; }
  get isSkillsPage()      { return this.activePage === "skills"; }

  /* ───────── Home ───────── */
  get greeting()       { return greeting(); }
  get userFirstName()  { return "Dylan"; }
  get briefingLine()   { return BRIEFING_LINES[0]; }

  get pulseMetrics() {
    return PULSE_METRICS.map((m) => ({
      ...m,
      deltaClass: `pulse-delta pulse-delta-${m.deltaTone}`,
      sparkPath: sparklinePath(m.sparkline)
    }));
  }

  get watchingItems() {
    return WATCHING_ITEMS.map((w) => ({
      ...w,
      rowClass: `watch-row${w.active ? " is-active" : ""}`,
      statusLabel: w.active ? "running" : "paused"
    }));
  }

  get activityFeed() {
    return ACTIVITY_FEED.map((a) => ({
      ...a,
      statusDotClass: `dot dot-${a.status}`
    }));
  }

  get learningStats() { return LEARNING_STATS; }

  get activeAgentCount() {
    return BUILTIN_AGENTS.filter((a) => a.active).length;
  }

  /* ───────── Chat ───────── */
  get chatCapabilities() {
    return CHAT_CAPABILITIES;
  }
  get chatSessions() {
    return CHAT_SESSIONS;
  }
  get chatSessionCount() { return CHAT_SESSIONS.length; }
  get chatModes() {
    return CHAT_MODES.map((m) => ({
      ...m,
      modeClass: `mode-pill${m.id === this.chatMode ? " is-active" : ""}`
    }));
  }
  get chatInputHasValue() {
    return this.chatInput.trim().length > 0;
  }
  get chatSendClass() {
    return `send-btn${this.chatInputHasValue ? " is-ready" : ""}`;
  }

  /* ───────── Playbooks ───────── */
  get playbookTemplates() {
    return PLAYBOOK_TEMPLATES.map((p) => ({
      ...p,
      stepsView: p.steps.map((s, i) => ({
        key: `${p.id}-s-${i}`,
        sepKey: `${p.id}-sep-${i}`,
        label: s,
        isLast: i === p.steps.length - 1
      }))
    }));
  }

  get playbookTemplateCount() { return PLAYBOOK_TEMPLATES.length; }

  /* ───────── Autonomous Work ───────── */
  get autonomousSummary() { return AUTONOMOUS_SUMMARY; }
  get delegationTemplates() {
    return DELEGATION_TEMPLATES.map((d) => ({
      ...d,
      ownerInitial: d.owner.charAt(0).toUpperCase()
    }));
  }

  /* ───────── Workflows ───────── */
  get workflowPatterns() {
    return WORKFLOW_PATTERNS.map((wf) => ({
      ...wf,
      nodes: wf.steps.map((s, i) => ({
        key: `${wf.id}-n-${i}`,
        edgeKey: `${wf.id}-e-${i}`,
        label: s.label,
        role: s.role,
        nodeClass: `wf-node wf-node-${s.role}`,
        isLast: i === wf.steps.length - 1
      }))
    }));
  }

  get workflowPatternCount() { return WORKFLOW_PATTERNS.length; }

  /* ───────── Agents ───────── */
  get builtinAgents() {
    return BUILTIN_AGENTS.map((a) => ({
      ...a,
      initial: a.name.charAt(0).toUpperCase(),
      cardClass: `agent-card${a.active ? " is-active" : ""}`,
      toolChips: a.tools.map((t, i) => ({ key: `${a.id}-t-${i}`, label: t }))
    }));
  }

  get builtinAgentCount() { return BUILTIN_AGENTS.length; }
  get customAgentCount()  { return 0; }

  /* ───────── Skills ───────── */
  get skillCategories() {
    return SKILL_CATEGORIES.map((c) => ({
      ...c,
      chipClass: `filter-chip${c.id === this.skillFilter ? " is-active" : ""}`
    }));
  }

  get filteredSkills() {
    const term = this.skillSearch.trim().toLowerCase();
    return BUILTIN_SKILLS.filter((s) => {
      if (this.skillFilter !== "all" && s.category !== this.skillFilter) return false;
      if (!term) return true;
      return (
        s.name.toLowerCase().includes(term) ||
        s.description.toLowerCase().includes(term) ||
        (s.triggers || []).some((t) => t.toLowerCase().includes(term))
      );
    }).map((s) => ({
      ...s,
      rowClass: `skill-row${s.id === this.selectedSkillId ? " is-selected" : ""}`
    }));
  }

  get filteredSkillCount() {
    return this.filteredSkills.length;
  }

  get selectedSkill() {
    const match = BUILTIN_SKILLS.find((s) => s.id === this.selectedSkillId);
    if (!match) return null;
    const triggers = match.triggers || [];
    return {
      ...match,
      triggerChips: triggers.map((t, i) => ({ key: `t-${i}`, label: t })),
      hasTriggers: triggers.length > 0,
      triggerCount: triggers.length,
      categoryLabel: (SKILL_CATEGORIES.find((c) => c.id === match.category) || { label: "Skill" }).label
    };
  }

  get skillsTotalCount() { return BUILTIN_SKILLS.length; }

  /* ───────── Handlers ───────── */
  handleNavClick(event) {
    const navId = event.currentTarget.dataset.nav;
    if (navId) this.activePage = navId;
  }

  handleGoToChat() { this.activePage = "chat"; }
  handleGoToPlaybooks() { this.activePage = "playbooks"; }

  handleSidebarChatSearch(event) {
    this.sidebarChatQuery = event.target.value;
  }

  handleQuickLaunch(event) {
    this.quickLaunch = event.target.value;
  }

  handleQuickLaunchSubmit(event) {
    if (event.key === "Enter" && this.quickLaunch.trim()) {
      /* in a real build this would create a draft playbook */
      this.quickLaunch = "";
    }
  }

  handleGlobalCommand(event) {
    this.globalCommand = event.target.value;
  }

  handleGlobalCommandSubmit(event) {
    if (event.key === "Enter" && this.globalCommand.trim()) {
      this.activePage = "chat";
      this.chatInput = this.globalCommand;
      this.globalCommand = "";
    }
  }

  handleChatInput(event) {
    this.chatInput = event.target.value;
  }

  handleChatKeyDown(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      /* placeholder — would send */
    }
  }

  handleChatModeSelect(event) {
    const id = event.currentTarget.dataset.mode;
    if (id) this.chatMode = id;
  }

  handleChatCapability(event) {
    const id = event.currentTarget.dataset.cap;
    const match = CHAT_CAPABILITIES.find((c) => c.id === id);
    if (match) this.chatInput = match.example;
  }

  handleSkillFilter(event) {
    const id = event.currentTarget.dataset.cat;
    if (id) this.skillFilter = id;
  }

  handleSkillSearch(event) {
    this.skillSearch = event.target.value;
  }

  handleSkillSelect(event) {
    const id = event.currentTarget.dataset.skillId;
    if (id) this.selectedSkillId = id;
  }
}
