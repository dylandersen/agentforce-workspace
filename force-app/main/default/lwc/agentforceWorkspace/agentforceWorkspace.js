import { LightningElement, track } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import AGENTFORCE_ICON from "@salesforce/resourceUrl/AgentforceRGBIcon";
import GEMINI_LOGO from "@salesforce/resourceUrl/Gemini";
import OPENAI_LOGO from "@salesforce/resourceUrl/OpenAI";
import CLAUDE_LOGO from "@salesforce/resourceUrl/Claude";
import NVIDIA_LOGO from "@salesforce/resourceUrl/nvidia";
import buildQueries from "@salesforce/apex/AgentforceWorkspaceController.buildQueries";
import analyzeResults from "@salesforce/apex/AgentforceWorkspaceController.analyzeResults";
import getUserFirstName from "@salesforce/apex/AgentforceWorkspaceController.getUserFirstName";
import getUserPhotoUrl from "@salesforce/apex/AgentforceWorkspaceController.getUserPhotoUrl";

const CACHE_MAX_AGE = 30 * 60 * 1000; // 30 minutes

const MAX_HISTORY_TURNS = 10;

const PROMPT_OVERHEAD_TOKENS = 800;
const USAGE_KEY = "agentforceWorkspace_usage";

// Flex credit cost per 2,000-token chunk by model tier
const CREDIT_COSTS = { basic: 2, standard: 4, advanced: 16 };

// Map model IDs to credit tiers
const MODEL_CREDIT_TIER = {
  sfdc_ai__DefaultVertexAIGemini30Flash: "basic",
  sfdc_ai__DefaultVertexAIGeminiPro30: "standard",
  sfdc_ai__DefaultGPT5: "standard",
  sfdc_ai__DefaultGPT52: "standard",
  sfdc_ai__DefaultBedrockNvidiaNemotronNano330b: "basic",
  sfdc_ai__DefaultBedrockAnthropicClaude45Sonnet: "standard",
  sfdc_ai__DefaultBedrockAnthropicClaude45Opus: "advanced"
};

const MODELS = [
  { id: "sfdc_ai__DefaultVertexAIGemini30Flash", label: "Gemini Flash 3.0", logoKey: "gemini", premium: false },
  { id: "sfdc_ai__DefaultVertexAIGeminiPro30",   label: "Gemini Pro 3.0",   logoKey: "gemini", premium: false },
  { id: "sfdc_ai__DefaultGPT5",                  label: "GPT-5",            logoKey: "openai", premium: false },
  { id: "sfdc_ai__DefaultGPT52",                 label: "GPT-5.2",          logoKey: "openai", premium: false },
  { id: "sfdc_ai__DefaultBedrockNvidiaNemotronNano330b",  label: "Nemotron 3 Nano", logoKey: "nvidia", premium: false },
  { id: "sfdc_ai__DefaultBedrockAnthropicClaude45Sonnet", label: "Sonnet 4.5", logoKey: "claude", premium: false },
  { id: "sfdc_ai__DefaultBedrockAnthropicClaude45Opus",   label: "Opus 4.5",   logoKey: "claude", premium: true }
];

const LOGO_MAP = {
  gemini: GEMINI_LOGO,
  openai: OPENAI_LOGO,
  nvidia: NVIDIA_LOGO,
  claude: CLAUDE_LOGO
};

const DEFAULT_MODEL = MODELS[0].id;

const CACHE_KEY = "agentforceWorkspace_session";
const MODEL_KEY = "agentforceWorkspace_model";
const TYPEWRITER_BLOCK_DELAY = 100;

export default class AgentforceWorkspace extends NavigationMixin(LightningElement) {
  // ─── Landing State ───────────────────────────────────
  @track isLanding = true;
  @track landingInputValue = "";
  @track isLandingModelPickerOpen = false;
  @track isExiting = false;
  @track isEntering = false;
  @track heroHeadline = "";

  // ─── Chat State ──────────────────────────────────────
  @track messages = [];
  @track suggestedReplies = [];
  @track selectedModelId = DEFAULT_MODEL;
  @track isModelPickerOpen = false;
  @track agentSteps = [];
  @track isDetailsPanelOpen = true;
  @track sidebarRecordTabs = [];
  @track sidebarChartData = null;

  // ─── Collapsible Sidebar Sections ──────────────────
  @track isProgressExpanded = true;
  @track isRecordsExpanded = false;
  @track isChartExpanded = false;
  @track _recordsBadgeVisible = false;
  @track _chartBadgeVisible = false;
  @track isRecordsModalOpen = false;
  @track isRecordViewModalOpen = false;
  @track recordViewModalRecordId = null;
  @track recordViewModalObjectApiName = null;
  @track sidebarCreatedRecord = null;
  @track isCreatedRecordExpanded = false;
  @track _createdRecordBadgeVisible = false;

  // ─── Usage Estimate State ──────────────────────────
  @track sessionTokens = 0;
  @track sessionCredits = 0;
  @track contextTokens = 0;
  @track isUsageExpanded = false;

  inputValue = "";
  isLoading = false;
  _typewriterTimerIds = [];
  _cachedRecordTabs = [];

  agentIcon = AGENTFORCE_ICON;
  @track userPhotoUrl = '';

  // ─── Task Suggestions ────────────────────────────────

  get taskSuggestions() {
    const ALL_TASKS = [
      // Pipeline / Opportunity (orange)
      { iconName: "utility:opportunity",  iconWrapClass: "task-icon-wrap task-icon-pipeline",  question: "What's my pipeline by stage?" },
      { iconName: "utility:opportunity",  iconWrapClass: "task-icon-wrap task-icon-pipeline",  question: "Which deals are closing this month?" },
      { iconName: "utility:opportunity",  iconWrapClass: "task-icon-wrap task-icon-pipeline",  question: "Show me deals in Negotiation over $50K" },
      { iconName: "utility:opportunity",  iconWrapClass: "task-icon-wrap task-icon-pipeline",  question: "Deals stuck in Qualification for over 60 days?" },
      { iconName: "utility:opportunity",  iconWrapClass: "task-icon-wrap task-icon-pipeline",  question: "Open deals with close dates that already passed?" },
      { iconName: "utility:opportunity",  iconWrapClass: "task-icon-wrap task-icon-pipeline",  question: "Largest deals closing in the next 30 days?" },
      // Deals / Money (green)
      { iconName: "utility:moneybag",     iconWrapClass: "task-icon-wrap task-icon-deals",     question: "What's my total pipeline value right now?" },
      { iconName: "utility:moneybag",     iconWrapClass: "task-icon-wrap task-icon-deals",     question: "Average deal size for closed-won this year?" },
      { iconName: "utility:moneybag",     iconWrapClass: "task-icon-wrap task-icon-deals",     question: "Closed-won deals from last quarter?" },
      { iconName: "utility:moneybag",     iconWrapClass: "task-icon-wrap task-icon-deals",     question: "What's my win rate — closed-won vs closed-lost?" },
      { iconName: "utility:moneybag",     iconWrapClass: "task-icon-wrap task-icon-deals",     question: "Deals I moved to Proposal/Quote this quarter?" },
      // Accounts (blue)
      { iconName: "utility:company",      iconWrapClass: "task-icon-wrap task-icon-accounts",  question: "Accounts with no activity in the last 30 days?" },
      { iconName: "utility:company",      iconWrapClass: "task-icon-wrap task-icon-accounts",  question: "Accounts I own with no open opportunities?" },
      { iconName: "utility:company",      iconWrapClass: "task-icon-wrap task-icon-accounts",  question: "Accounts with open opps but no recent activities?" },
      { iconName: "utility:company",      iconWrapClass: "task-icon-wrap task-icon-accounts",  question: "Show me my top accounts by annual revenue" },
      // Contacts / People (purple)
      { iconName: "utility:people",       iconWrapClass: "task-icon-wrap task-icon-contacts",  question: "Prospects with no email or call in 90 days?" },
      { iconName: "utility:people",       iconWrapClass: "task-icon-wrap task-icon-contacts",  question: "Decision makers on my open deals over $100K?" },
      { iconName: "utility:people",       iconWrapClass: "task-icon-wrap task-icon-contacts",  question: "Which leads have been stuck in the same status?" },
      // Campaigns / Analytics (coral)
      { iconName: "utility:graph",        iconWrapClass: "task-icon-wrap task-icon-campaigns", question: "How are my campaigns performing this quarter?" },
      { iconName: "utility:graph",        iconWrapClass: "task-icon-wrap task-icon-campaigns", question: "Which campaigns drove the most won deals?" },
      { iconName: "utility:graph",        iconWrapClass: "task-icon-wrap task-icon-campaigns", question: "Break down my open cases by priority" },
      // Activities (teal)
      { iconName: "utility:log_a_call",   iconWrapClass: "task-icon-wrap task-icon-create",    question: "Log a call" },
      { iconName: "utility:task",         iconWrapClass: "task-icon-wrap task-icon-create",    question: "Log a task" },
      { iconName: "utility:event",        iconWrapClass: "task-icon-wrap task-icon-create",    question: "Schedule a meeting" },
      // Create (teal)
      { iconName: "utility:add",          iconWrapClass: "task-icon-wrap task-icon-create",    question: "Create a new account" }
    ];

    // Shuffle and pick 5 — use current hour as seed for session consistency
    const seed = new Date().getHours();
    const shuffled = [...ALL_TASKS].sort(
      (a, b) => Math.sin(seed + ALL_TASKS.indexOf(a) * 7) - Math.sin(seed + ALL_TASKS.indexOf(b) * 7)
    );
    return shuffled.slice(0, 5).map((t, i) => ({ ...t, id: `t${i}` }));
  }

  // ─── Computed: Landing ────────────────────────────────

  get isActive() {
    return !this.isLanding;
  }

  get selectedModelLabel() {
    const model = MODELS.find((m) => m.id === this.selectedModelId);
    return model ? model.label : MODELS[0].label;
  }

  get selectedModelLogo() {
    const model = MODELS.find((m) => m.id === this.selectedModelId);
    return model ? LOGO_MAP[model.logoKey] : LOGO_MAP[MODELS[0].logoKey];
  }

  get selectedModelLogoClass() {
    const model = MODELS.find((m) => m.id === this.selectedModelId);
    const key = model ? model.logoKey : MODELS[0].logoKey;
    return "model-btn-logo" + (key === "openai" ? " model-btn-logo-openai" : "") + (key === "nvidia" ? " model-btn-logo-nvidia" : "");
  }

  get landingModelBtnClass() {
    return "landing-model-btn" + (this.isLandingModelPickerOpen ? " landing-model-btn-open" : "");
  }

  get landingSendDisabled() {
    return !this.landingInputValue.trim();
  }

  get landingSendBtnClass() {
    return "landing-send-btn" + (this.landingSendDisabled ? " landing-send-btn-disabled" : "");
  }

  get landingSectionClass() {
    return "landing-section" + (this.isExiting ? " landing-exit" : "");
  }

  get activeSectionClass() {
    return "active-section" + (this.isEntering ? " chat-enter" : "");
  }

  // ─── Computed: Layout ──────────────────────────────────

  get chatBodyClass() {
    return "chat-body" + (this.showDetailsPanel ? " chat-body-split" : "");
  }

  get showDetailsPanel() {
    return this.isDetailsPanelOpen;
  }

  // ─── Computed: Steps ───────────────────────────────────

  get hasSteps() {
    return this.agentSteps.length > 0;
  }

  get progressPercent() {
    if (this.agentSteps.length === 0) return 0;
    const completed = this.agentSteps.filter(s => s.status === "complete").length;
    return Math.round((completed / this.agentSteps.length) * 100);
  }

  get progressBadgeClass() {
    return "progress-badge" + (this.progressPercent === 100 ? " progress-badge-complete" : "");
  }

  get showStepsPlaceholder() {
    return !this.hasSteps && !this.isLoading;
  }

  get hasRecordTabs() {
    return this.sidebarRecordTabs && this.sidebarRecordTabs.length > 0;
  }

  get hasSidebarChart() {
    return this.sidebarChartData && this.sidebarChartData.items && this.sidebarChartData.items.length > 0;
  }

  get noRecordTabs() {
    return !this.hasRecordTabs;
  }

  get noSidebarChart() {
    return !this.hasSidebarChart;
  }

  // ─── Collapsible Section Getters ─────────────────────

  get progressChevronClass() {
    return "collapsible-chevron" + (this.isProgressExpanded ? " collapsible-chevron-expanded" : "");
  }

  get recordsChevronClass() {
    return "collapsible-chevron" + (this.isRecordsExpanded ? " collapsible-chevron-expanded" : "");
  }

  get chartChevronClass() {
    return "collapsible-chevron" + (this.isChartExpanded ? " collapsible-chevron-expanded" : "");
  }

  get showRecordsBadge() {
    return this._recordsBadgeVisible && !this.isRecordsExpanded;
  }

  get showChartBadge() {
    return this._chartBadgeVisible && !this.isChartExpanded;
  }

  get hasSidebarCreatedRecord() {
    return this.sidebarCreatedRecord !== null;
  }

  get showCreatedRecordBadge() {
    return this._createdRecordBadgeVisible && !this.isCreatedRecordExpanded;
  }

  get createdRecordChevronClass() {
    return "collapsible-chevron" + (this.isCreatedRecordExpanded ? " collapsible-chevron-expanded" : "");
  }

  get recordViewModalTitle() {
    if (this.recordViewModalObjectApiName === 'Task') return 'Task Details';
    if (this.recordViewModalObjectApiName === 'Event') return 'Event Details';
    if (this.recordViewModalObjectApiName === 'Account') return 'Account Details';
    return 'Record Details';
  }

  get recordViewSupportsUiApi() {
    const unsupported = new Set(['Task', 'Event']);
    return !unsupported.has(this.recordViewModalObjectApiName);
  }

  get recordViewIsActivity() {
    return this.recordViewModalObjectApiName === 'Task' || this.recordViewModalObjectApiName === 'Event';
  }

  get recordViewIconName() {
    if (this.sidebarCreatedRecord?.iconName) return this.sidebarCreatedRecord.iconName;
    if (this.recordViewModalObjectApiName === 'Task') return 'standard:task';
    if (this.recordViewModalObjectApiName === 'Event') return 'standard:event';
    return 'standard:record';
  }

  get recordViewRecordName() {
    return this.sidebarCreatedRecord?.recordName || '';
  }

  get recordViewFields() {
    return (this.sidebarCreatedRecord?.fields || []).map((f, i) => ({
      ...f,
      key: `rv-field-${i}`
    }));
  }

  get allSectionsExpanded() {
    return this.isProgressExpanded && this.isRecordsExpanded && this.isChartExpanded && this.isUsageExpanded;
  }

  get toggleAllSectionsTitle() {
    return this.allSectionsExpanded ? "Collapse all sections" : "Expand all sections";
  }

  // ─── Computed: Usage Estimate ─────────────────────

  get formattedContextTokens() {
    return this.contextTokens > 0 ? `~${this.contextTokens.toLocaleString()}` : "0";
  }

  get formattedSessionTokens() {
    return this.sessionTokens.toLocaleString();
  }

  get formattedSessionCredits() {
    return this.sessionCredits.toLocaleString();
  }

  get tokenMeterWidth() {
    // Show meter relative to 20k token reference (a reasonable prompt ceiling)
    const reference = 20000;
    const pct = this.contextTokens > 0
      ? Math.min((this.contextTokens / reference) * 100, 100)
      : 0;
    return `width: ${pct}%`;
  }

  get tokenMeterFillClass() {
    const reference = 20000;
    const pct = this.contextTokens > 0 ? (this.contextTokens / reference) * 100 : 0;
    let color = "meter-fill-green";
    if (pct > 75) color = "meter-fill-red";
    else if (pct > 50) color = "meter-fill-yellow";
    return `token-meter-fill ${color}`;
  }

  get usageChevronClass() {
    return "usage-chevron" + (this.isUsageExpanded ? " usage-chevron-expanded" : "");
  }

  // ─── Computed: Chat ───────────────────────────────────

  get sendDisabled() {
    return this.isLoading || !this.inputValue.trim();
  }

  get sendButtonClass() {
    return "send-btn" + (this.sendDisabled ? " send-btn-disabled" : "");
  }

  get showSuggestedReplies() {
    if (this.isLoading || this.suggestedReplies.length === 0) return false;
    const last = this.messages[this.messages.length - 1];
    return last && last.isAgent;
  }

  get showTypingIndicator() {
    return this.isLoading;
  }

  get modelBtnClass() {
    return "model-btn" + (this.isModelPickerOpen ? " model-btn-open" : "");
  }

  get modelOptions() {
    return MODELS.map((m) => ({
      ...m,
      logo: LOGO_MAP[m.logoKey],
      isActive: m.id === this.selectedModelId,
      itemClass: "model-item" + (m.id === this.selectedModelId ? " model-item-active" : ""),
      logoClass: "model-logo" + (m.logoKey === "openai" ? " model-logo-openai" : "") + (m.logoKey === "nvidia" ? " model-logo-nvidia" : "")
    }));
  }

  // ─── Lifecycle ────────────────────────────────────────

  connectedCallback() {
    this.hideDefaultHeader();
    this._restoreModelChoice();
    this._loadLandingHeadline();
    this._loadUserPhoto();
    this._restoreFromCache();
    this._loadUsageMetrics();
  }

  async _loadLandingHeadline() {
    try {
      const firstName = await getUserFirstName();
      const days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
      const dayName = days[new Date().getDay()];
      if (firstName) {
        this.heroHeadline = `Happy ${dayName}, ${firstName} \u2014`;
      } else {
        this.heroHeadline = `Happy ${dayName} \u2014`;
      }
    } catch (_e) {
      // keep default
    }
  }

  async _loadUserPhoto() {
    try {
      const url = await getUserPhotoUrl();
      if (url) this.userPhotoUrl = url;
    } catch (_e) { /* keep empty */ }
  }

  disconnectedCallback() {
    this._clearTypewriterTimers();
  }

  // ─── Landing Handlers ─────────────────────────────────

  handleLandingInput(event) {
    this.landingInputValue = event.target.value;
    this._resizeTextarea(event.target, 160);
  }

  handleLandingKeyDown(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      this.handleLandingSend();
    }
  }

  handleLandingSend() {
    const text = this.landingInputValue.trim();
    if (!text) return;
    this._transitionToChat(text);
  }

  handleSuggestionClick(event) {
    const question = event.currentTarget.dataset.question;
    if (question) {
      this._transitionToChat(question);
    }
  }

  // ─── Landing Model Picker ────────────────────────────

  handleLandingModelPickerToggle(event) {
    event.stopPropagation();
    this.isLandingModelPickerOpen = !this.isLandingModelPickerOpen;
  }

  handleLandingModelPickerClose() {
    this.isLandingModelPickerOpen = false;
  }

  handleLandingModelSelect(event) {
    event.stopPropagation();
    const newModelId = event.currentTarget.dataset.modelId;
    if (newModelId) {
      this.selectedModelId = newModelId;
      this._persistModelChoice();
    }
    this.isLandingModelPickerOpen = false;
  }

  // ─── Details Panel ─────────────────────────────────────

  handleToggleDetailsPanel() {
    this.isDetailsPanelOpen = !this.isDetailsPanelOpen;
  }

  handleCloseDetailsPanel() {
    this.isDetailsPanelOpen = false;
  }

  handleToggleProgress() {
    this.isProgressExpanded = !this.isProgressExpanded;
  }

  handleToggleRecords() {
    this.isRecordsExpanded = !this.isRecordsExpanded;
    // Dismiss badge when opening
    if (this.isRecordsExpanded) {
      this._recordsBadgeVisible = false;
    }
  }

  handleToggleCreatedRecord() {
    this.isCreatedRecordExpanded = !this.isCreatedRecordExpanded;
    if (this.isCreatedRecordExpanded) {
      this._createdRecordBadgeVisible = false;
    }
  }

  handleOpenRecordsModal() {
    this.isRecordsModalOpen = true;
  }

  handleCloseRecordsModal() {
    this.isRecordsModalOpen = false;
  }

  handleViewRecord(event) {
    const { recordId, objectApiName } = event.detail;
    if (recordId) {
      this.recordViewModalRecordId = recordId;
      this.recordViewModalObjectApiName = objectApiName;
      this.isRecordViewModalOpen = true;
    }
  }

  handleCloseRecordViewModal() {
    this.isRecordViewModalOpen = false;
    this.recordViewModalRecordId = null;
    this.recordViewModalObjectApiName = null;
  }

  handleNavigateToRecord() {
    if (this.recordViewModalRecordId) {
      this[NavigationMixin.Navigate]({
        type: "standard__recordPage",
        attributes: {
          recordId: this.recordViewModalRecordId,
          objectApiName: this.recordViewModalObjectApiName,
          actionName: "view"
        }
      });
      this.handleCloseRecordViewModal();
    }
  }

  handleToggleChart() {
    this.isChartExpanded = !this.isChartExpanded;
    // Dismiss badge when opening
    if (this.isChartExpanded) {
      this._chartBadgeVisible = false;
    }
  }

  handleToggleUsage() {
    this.isUsageExpanded = !this.isUsageExpanded;
  }

  handleToggleAllSections() {
    const expand = !this.allSectionsExpanded;
    this.isProgressExpanded = expand;
    this.isRecordsExpanded = expand;
    this.isChartExpanded = expand;
    this.isCreatedRecordExpanded = expand;
    this.isUsageExpanded = expand;
    if (expand) {
      this._recordsBadgeVisible = false;
      this._chartBadgeVisible = false;
      this._createdRecordBadgeVisible = false;
    }
  }

  // ─── Transition ───────────────────────────────────────

  _transitionToChat(message) {
    this.isExiting = true;

    // eslint-disable-next-line @lwc/lwc/no-async-operation
    setTimeout(() => {
      this.isLanding = false;
      this.isExiting = false;
      this.isEntering = true;
      this._saveToCache();

      // Auto-send the initial message
      if (message) {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
          this.inputValue = message;
          this.handleSend();
        }, 100);
      }

      // eslint-disable-next-line @lwc/lwc/no-async-operation
      setTimeout(() => {
        this.isEntering = false;
      }, 400);
    }, 300);
  }

  // ─── Cache ────────────────────────────────────────────

  _saveToCache() {
    try {
      const payload = {
        isLanding: this.isLanding,
        messages: this.messages,
        selectedModelId: this.selectedModelId,
        suggestedReplies: this.suggestedReplies,
        isDetailsPanelOpen: this.isDetailsPanelOpen,
        sidebarRecordTabs: this.sidebarRecordTabs,
        sidebarChartData: this.sidebarChartData,
        sidebarCreatedRecord: this.sidebarCreatedRecord,
        timestamp: Date.now()
      };
      localStorage.setItem(CACHE_KEY, JSON.stringify(payload));
    } catch (_e) {
      // storage full or unavailable
    }
  }

  _persistModelChoice() {
    try {
      localStorage.setItem(MODEL_KEY, this.selectedModelId);
    } catch (_e) {
      // storage full
    }
  }

  _restoreModelChoice() {
    try {
      const stored = localStorage.getItem(MODEL_KEY);
      if (stored && MODELS.some((m) => m.id === stored)) {
        this.selectedModelId = stored;
      }
    } catch (_e) {
      // ignore
    }
  }

  _restoreFromCache() {
    try {
      const raw = localStorage.getItem(CACHE_KEY);
      if (!raw) return;

      const cached = JSON.parse(raw);
      const age = Date.now() - (cached.timestamp || 0);
      if (age > CACHE_MAX_AGE) {
        this._clearCache();
        return;
      }

      if (cached.selectedModelId) {
        this.selectedModelId = cached.selectedModelId;
      }

      if (cached.isDetailsPanelOpen !== undefined) {
        this.isDetailsPanelOpen = cached.isDetailsPanelOpen;
      }

      // Restore active chat state — only if there are actual messages to show
      if (cached.isLanding === false && cached.messages && cached.messages.length > 0) {
        this.isLanding = false;
        this.messages = cached.messages;
        this.suggestedReplies = cached.suggestedReplies || [];
        // Restore sidebar data from cache
        if (cached.sidebarRecordTabs && cached.sidebarRecordTabs.length > 0) {
          this.sidebarRecordTabs = cached.sidebarRecordTabs;
          this._cachedRecordTabs = cached.sidebarRecordTabs;
        }
        if (cached.sidebarChartData) {
          this.sidebarChartData = cached.sidebarChartData;
        }
        if (cached.sidebarCreatedRecord) {
          this.sidebarCreatedRecord = cached.sidebarCreatedRecord;
          this.isCreatedRecordExpanded = true;
        }
      }
    } catch (_e) {
      // corrupt cache
    }
  }

  _clearCache() {
    try {
      localStorage.removeItem(CACHE_KEY);
    } catch (_e) {
      // ignore
    }
  }

  // ─── Chat Input Handlers ──────────────────────────────

  handleInput(event) {
    this.inputValue = event.target.value;
    this._resizeTextarea(event.target, 160);
  }

  handleKeyDown(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      this.handleSend();
    }
  }

  handleChatSuggestion(event) {
    const question = event.currentTarget.dataset.question;
    if (question) {
      this.suggestedReplies = [];
      this.inputValue = question;
      this.handleSend();
    }
  }

  // ─── Chat Model Picker ───────────────────────────────

  handleModelPickerToggle(event) {
    event.stopPropagation();
    this.isModelPickerOpen = !this.isModelPickerOpen;
  }

  handleModelPickerClose() {
    this.isModelPickerOpen = false;
  }

  handleModelSelect(event) {
    event.stopPropagation();
    const newModelId = event.currentTarget.dataset.modelId;
    if (!newModelId || newModelId === this.selectedModelId) {
      this.isModelPickerOpen = false;
      return;
    }
    this.selectedModelId = newModelId;
    this._persistModelChoice();
    this.isModelPickerOpen = false;
    this._pendingModelSwitch = true;
  }

  // ─── Home ──────────────────────────────────────────────

  handleHome() {
    this._resetChatState();
    this.isLanding = true;
    this.landingInputValue = "";
    this._saveToCache();
  }

  // ─── Clear Chat ────────────────────────────────────────

  handleReset() {
    this._resetChatState();
  }

  _resetChatState() {
    this._clearCache();
    this.messages = [];
    this.suggestedReplies = [];
    this._cachedRecordTabs = [];
    this.sidebarRecordTabs = [];
    this.sidebarChartData = null;
    this.agentSteps = [];
    this.sidebarCreatedRecord = null;
    this.isProgressExpanded = true;
    this.isRecordsExpanded = false;
    this.isChartExpanded = false;
    this.isCreatedRecordExpanded = false;
    this._recordsBadgeVisible = false;
    this._chartBadgeVisible = false;
    this._createdRecordBadgeVisible = false;
    this.inputValue = "";
    this._clearInput();
    this.isLoading = false;
    this._clearTypewriterTimers();
    this.sessionTokens = 0;
    this.sessionCredits = 0;
    this.contextTokens = 0;
    this._saveUsageMetrics();
  }

  // ─── Step Management ──────────────────────────────────

  _addStep(label) {
    const step = {
      id: "step-" + Date.now() + "-" + Math.random().toString(36).substr(2, 4),
      label,
      status: "in-progress",
      isComplete: false,
      isInProgress: true,
      isPending: false,
      statusClass: "step-item step-in-progress"
    };
    this.agentSteps = [...this.agentSteps, step];
    return step.id;
  }

  _completeStep(stepId) {
    this.agentSteps = this.agentSteps.map(s =>
      s.id === stepId
        ? { ...s, status: "complete", isComplete: true, isInProgress: false, isPending: false, statusClass: "step-item step-complete" }
        : s
    );
  }

  _addCompletedStep(label) {
    const step = {
      id: "step-" + Date.now() + "-" + Math.random().toString(36).substr(2, 4),
      label,
      status: "complete",
      isComplete: true,
      isInProgress: false,
      isPending: false,
      statusClass: "step-item step-complete"
    };
    this.agentSteps = [...this.agentSteps, step];
    return step.id;
  }

  _clearSteps() {
    this.agentSteps = [];
  }

  _getModelLabel() {
    const model = MODELS.find(m => m.id === this.selectedModelId);
    return model ? model.label : "AI";
  }

  // ─── Send ─────────────────────────────────────────────

  async handleSend() {
    const text = this.inputValue.trim();
    if (!text || this.isLoading) return;

    // If model was switched mid-chat, wipe and start fresh
    if (this._pendingModelSwitch) {
      this._pendingModelSwitch = false;
      this._resetChatState();
    }

    this.suggestedReplies = [];
    this.messages = [...this.messages, this._makeMsg("user", text)];
    this.inputValue = "";
    this._clearInput();
    this.isLoading = true;
    this._clearSteps();
    this.isDetailsPanelOpen = true;
    this._scrollToBottom();
    this._saveToCache();
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    setTimeout(() => {
      const input = this.template.querySelector(".chat-input");
      if (input) input.focus();
    }, 0);

    try {
      const history = this._buildHistory();

      // ── Step 1: Build queries + get records ──
      const buildStepId = this._addStep("Querying your Salesforce data...");

      const queryResult = await buildQueries({
        userMessage: text,
        conversationHistory: history,
        modelName: this.selectedModelId
      });

      this._completeStep(buildStepId);

      // Show record tabs inline in the chat
      const newRecordTabs = queryResult?.recordTabs ?? [];
      if (newRecordTabs.length > 0) {
        // Add a completed step for each object type found
        for (const tab of newRecordTabs) {
          const label = tab.recordCount === 1 ? this._singularize(tab.objectLabel) : tab.objectLabel;
          this._addCompletedStep(`Found ${tab.recordCount} ${label}...`);
        }
        this._cachedRecordTabs = newRecordTabs;
        // Show records in the sidebar with notification badge
        this.sidebarRecordTabs = newRecordTabs;
        if (!this.isRecordsExpanded) {
          this._recordsBadgeVisible = true;
        }
        this._scrollToBottom();
      } else {
        this._addCompletedStep("No matching records found...");
      }

      // ── Step 2: Analyze results ──
      const analyzeStepId = this._addStep("Agentforce is analyzing the data...");

      const executionDataJson = queryResult?.executionDataJson ?? "";
      const summary = queryResult?.querySummary ?? "";
      if (!executionDataJson) {
        this._completeStep(analyzeStepId);
        const fallback = summary || "I couldn't process that question. Try rephrasing or switching to a different model.";
        this.messages = [...this.messages, this._makeMsg("agent", `<p>${fallback}</p>`)];
        this._trackUsage(text, fallback);
        this._saveToCache();
      } else {
        const analysis = await analyzeResults({
          executionDataJson,
          userMessage: text,
          conversationHistory: history,
          modelName: this.selectedModelId
        });

        this._completeStep(analyzeStepId);

        const rawResponse = analysis?.response ?? analysis ?? "";
        const responseText = this._normalizeMarkdown(rawResponse);

        // Guard against empty AI responses
        if (!responseText || responseText.trim().length === 0) {
          this.messages = [...this.messages, this._makeMsg("agent", "<p>I received an empty response from the AI. Please try your question again or try a different model.</p>")];
          this._saveToCache();
          this.isLoading = false;
          this._scrollToBottom();
          return;
        }

        this._addCompletedStep("Response ready...");
        await this._typewriterReveal(responseText);

        this._reconcileRecordTabs(responseText);
        this._trackUsage(text, responseText);

        this.suggestedReplies = analysis?.suggestions ?? [];
        this._saveToCache();

        // Show chart in the sidebar with notification badge
        const chartData = analysis?.chartData;
        if (chartData && chartData.items && chartData.items.length > 0) {
          this.sidebarChartData = chartData;
          if (!this.isChartExpanded) {
            this._chartBadgeVisible = true;
          }
          this._saveToCache();
        }

        // Insert created record inline if present
        if (analysis?.createdRecord) {
          this.sidebarCreatedRecord = analysis.createdRecord;
          this.isCreatedRecordExpanded = true;
          this._createdRecordBadgeVisible = false;
          this._saveToCache();
        }
      }
    } catch (error) {
      const errMsg = error?.body?.message || error?.message || "";
      let userMessage;
      if (errMsg.includes("Models API") || errMsg.includes("generation") || errMsg.includes("AI")) {
        userMessage = "<p>The AI service is temporarily unavailable. Please try again in a moment or switch to a different model.</p>";
      } else if (errMsg) {
        userMessage = `<p>Sorry, something went wrong: ${errMsg}</p><p>Try rephrasing your question or switching models.</p>`;
      } else {
        userMessage = "<p>Something went wrong while processing your request. Please try again or rephrase your question.</p>";
      }
      this.messages = [...this.messages, this._makeMsg("agent", userMessage)];
      this._saveToCache();
    } finally {
      this.isLoading = false;
      this._scrollToBottom();
    }
  }

  // ─── Record Click Navigation ──────────────────────────

  handleRecordClick(event) {
    const path = event.composedPath();
    const link = path.find(
      (el) =>
        el.tagName === "A" &&
        el.getAttribute &&
        el.getAttribute("href")?.includes("/lightning/r/")
    );
    if (link) {
      event.preventDefault();
      event.stopPropagation();
      const href = link.getAttribute("href");
      const parts = href.split("/");
      const objectApiName = parts[3];
      const recordId = parts[4];
      if (recordId) {
        this[NavigationMixin.Navigate]({
          type: "standard__recordPage",
          attributes: {
            recordId: recordId,
            objectApiName: objectApiName,
            actionName: "view"
          }
        });
      }
    }
  }

  // ─── Conversation History ─────────────────────────────

  _buildHistory() {
    const turns = this.messages.filter(m => m.isAgent || m.isUser);
    const recent = turns.slice(-MAX_HISTORY_TURNS * 2);
    return recent
      .map((m) => (m.role === "user" ? "USER: " : "ASSISTANT: ") + m.content)
      .join("\n");
  }

  // ─── Typewriter Effect ────────────────────────────────

  _clearTypewriterTimers() {
    for (const id of this._typewriterTimerIds) {
      clearTimeout(id);
    }
    this._typewriterTimerIds = [];
  }

  _typewriterReveal(html) {
    this._clearTypewriterTimers();

    const blocks = this._parseHtmlBlocks(html);
    if (blocks.length <= 1) {
      this.messages = [...this.messages, this._makeMsg("agent", html)];
      return Promise.resolve();
    }

    const msgId = this._uid();
    const timestamp = this._now();
    let revealed = `<span class="typewriter-block">${blocks[0]}</span>`;

    this.messages = [
      ...this.messages,
      {
        id: msgId,
        role: "agent",
        content: revealed,
        timestamp,
        isAgent: true,
        isUser: false,
        isRecords: false,
        isChart: false,
        isCreatedRecord: false,
        rowClass: "message-row agent-msg"
      }
    ];
    this._scrollToBottom();

    if (blocks.length === 1) return Promise.resolve();

    return new Promise((resolve) => {
      for (let idx = 1; idx < blocks.length; idx++) {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        const timerId = setTimeout(() => {
          revealed += `<span class="typewriter-block">${blocks[idx]}</span>`;
          this.messages = this.messages.map((m) =>
            m.id === msgId ? { ...m, content: revealed } : m
          );
          this._scrollToBottom();

          if (idx === blocks.length - 1) {
            resolve();
          }
        }, idx * TYPEWRITER_BLOCK_DELAY);
        this._typewriterTimerIds.push(timerId);
      }
    });
  }

  _parseHtmlBlocks(html) {
    if (!html) return [];
    const blockPattern = /(<(?:p|h[1-6]|ul|ol|table|hr\s*\/?)[\s>][\s\S]*?<\/(?:p|h[1-6]|ul|ol|table)>|<hr\s*\/?>)/gi;
    const blocks = [];
    let lastIndex = 0;
    let match;
    // eslint-disable-next-line no-cond-assign
    while ((match = blockPattern.exec(html)) !== null) {
      if (match.index > lastIndex) {
        const between = html.substring(lastIndex, match.index).trim();
        if (between) blocks.push(between);
      }
      blocks.push(match[0]);
      lastIndex = blockPattern.lastIndex;
    }
    if (lastIndex < html.length) {
      const trailing = html.substring(lastIndex).trim();
      if (trailing) blocks.push(trailing);
    }
    return blocks.length > 0 ? blocks : [html];
  }

  // ─── Post-Analysis Record Reconciliation ──────────────

  _reconcileRecordTabs(analysisHtml) {
    if (!this._cachedRecordTabs || this._cachedRecordTabs.length === 0) return;

    const referencedIds = this._extractLinkedRecordIds(analysisHtml);

    if (referencedIds.size === 0) {
      // No specific records mentioned — keep original tabs as-is
      return;
    }

    // Find the object tab with the most mentioned records
    let bestTab = null;
    let bestRows = [];

    for (const tab of this._cachedRecordTabs) {
      const matchedRows = (tab.rows || []).filter(row =>
        this._rowMatchesIds(row, referencedIds)
      );
      if (matchedRows.length > bestRows.length) {
        bestTab = tab;
        bestRows = matchedRows;
      }
    }

    if (bestTab && bestRows.length > 0) {
      const specificTab = {
        objectApiName: "__SpecificRecords__",
        objectLabel: "Specific Records",
        iconName: bestTab.iconName,
        recordCount: bestRows.length,
        columns: bestTab.columns,
        rows: bestRows
      };
      const combined = [specificTab, ...this._cachedRecordTabs];
      this._cachedRecordTabs = combined;
      this.sidebarRecordTabs = combined;
    }
  }

  _extractLinkedRecordIds(html) {
    const ids = new Set();
    if (!html) return ids;
    const linkPattern = /href="\/lightning\/r\/[^/]+\/([a-zA-Z0-9]{15,18})\/view"/g;
    let match;
    // eslint-disable-next-line no-cond-assign
    while ((match = linkPattern.exec(html)) !== null) {
      ids.add(match[1]);
    }
    return ids;
  }

  _rowMatchesIds(row, referencedIds) {
    if (!row._id) return false;
    if (referencedIds.has(row._id)) return true;
    if (row._id.length === 18) {
      return referencedIds.has(row._id.substring(0, 15));
    }
    if (row._id.length === 15) {
      for (const refId of referencedIds) {
        if (refId.startsWith(row._id)) return true;
      }
    }
    return false;
  }

  // ─── Markdown Normalizer ──────────────────────────────

  _normalizeMarkdown(text) {
    if (!text) return text;
    let out = text;
    out = out.replace(/\*\*([^*\n]+?)\*\*/g, "<strong>$1</strong>");
    out = out.replace(/__([^_\n]+?)__/g, "<strong>$1</strong>");
    out = out.replace(/\*([^*\n]+?)\*/g, "<em>$1</em>");
    out = out.replace(/_([^_\n]+?)_/g, "<em>$1</em>");
    out = out.replace(/`([^`\n]+?)`/g, "<code>$1</code>");
    // Convert newlines to <br> for proper spacing
    // Only convert \n that are NOT immediately between closing and opening block tags
    out = out.replace(/\n\n/g, "<br><br>");
    out = out.replace(/(?<!\>)\n(?!\<)/g, "<br>");
    out = out.replace(/\n/g, " ");
    out = this._inlineTableStyles(out);
    out = this._inlineBlockStyles(out);
    return out;
  }

  /**
   * Inject inline styles on block elements (p, blockquote, ul, ol, hr).
   * lightning-formatted-rich-text shadow DOM blocks external CSS,
   * so we must inline styles — same pattern as _inlineTableStyles.
   */
  _inlineBlockStyles(html) {
    if (!html) return html;
    // <p> — add bottom margin for paragraph spacing
    html = html.replace(/<p(?:\s[^>]*)?>/gi, (match) => {
      if (match.includes("style=")) return match;
      return '<p style="margin:0 0 0.75rem 0">';
    });
    // <blockquote> — teal left border, padding, background
    html = html.replace(/<blockquote(?:\s[^>]*)?>/gi, (match) => {
      if (match.includes("style=")) return match;
      return '<blockquote style="margin:1rem 0;padding:0.75rem 1rem;border-left:3px solid #17B0A4;background:rgba(23,176,164,0.04);border-radius:0 6px 6px 0">';
    });
    // <ul> / <ol> — left padding + margin
    html = html.replace(/<ul(?:\s[^>]*)?>/gi, (match) => {
      if (match.includes("style=")) return match;
      return '<ul style="margin:0.375rem 0;padding-left:1.25rem">';
    });
    html = html.replace(/<ol(?:\s[^>]*)?>/gi, (match) => {
      if (match.includes("style=")) return match;
      return '<ol style="margin:0.375rem 0;padding-left:1.25rem">';
    });
    // <hr> — subtle divider
    html = html.replace(/<hr\s*\/?>/gi, '<hr style="border:none;border-top:1px solid rgba(0,0,0,0.1);margin:1rem 0">');
    return html;
  }

  _inlineTableStyles(html) {
    if (!html || !html.includes("<table")) return html;
    const borderStyle = "border:0.5px solid rgba(0,0,0,0.15)";
    html = html.replace(/<table(?:\s[^>]*)?>/gi, (match) => {
      if (match.includes("style=")) return match;
      return match.replace("<table", `<table style="width:100%;border-collapse:collapse;margin:0.5rem 0;font-size:0.8125rem;${borderStyle}"`);
    });
    const cellStyle = `style="padding:0.375rem 0.75rem;text-align:left;${borderStyle}"`;
    html = html.replace(/<th(?:\s[^>]*)?>/gi, (match) => {
      if (match.includes("style=")) return match;
      return match.replace("<th", `<th ${cellStyle}`);
    });
    html = html.replace(/<td(?:\s[^>]*)?>/gi, (match) => {
      if (match.includes("style=")) return match;
      return match.replace("<td", `<td ${cellStyle}`);
    });
    return html;
  }

  // ─── Usage Tracking ──────────────────────────────

  _estimateContextTokens() {
    const history = this._buildHistory();
    const historyTokens = history ? Math.ceil(history.length / 4) : 0;
    return historyTokens + PROMPT_OVERHEAD_TOKENS;
  }

  _trackUsage(userText, assistantText) {
    const contextTokens = this._estimateContextTokens();
    const messageTokens = Math.ceil((userText.length + assistantText.length) / 4);
    const totalTokens = contextTokens + messageTokens;

    // Each 2,000-token chunk counts as one prompt (rounded up)
    const promptChunks = Math.ceil(totalTokens / 2000);

    const creditTier = MODEL_CREDIT_TIER[this.selectedModelId] || "standard";
    const costPerChunk = CREDIT_COSTS[creditTier] || 4;
    const creditsUsed = promptChunks * costPerChunk;

    this.contextTokens = contextTokens;
    this.sessionTokens += totalTokens;
    this.sessionCredits += creditsUsed;

    this._saveUsageMetrics();
  }

  _saveUsageMetrics() {
    try {
      localStorage.setItem(USAGE_KEY, JSON.stringify({
        sessionTokens: this.sessionTokens,
        sessionCredits: this.sessionCredits,
        contextTokens: this.contextTokens
      }));
    } catch (_e) {
      // storage full
    }
  }

  _loadUsageMetrics() {
    try {
      const stored = localStorage.getItem(USAGE_KEY);
      if (stored) {
        const data = JSON.parse(stored);
        this.sessionTokens = data.sessionTokens || 0;
        this.sessionCredits = data.sessionCredits || 0;
        this.contextTokens = data.contextTokens || 0;
      }
    } catch (_e) {
      // corrupt
    }
  }

  // ─── DOM Helpers ──────────────────────────────────────

  _clearInput() {
    const input = this.template.querySelector(".chat-input");
    if (input) {
      input.value = "";
      this._resizeTextarea(input, 160);
    }
  }

  _resizeTextarea(el, maxHeightPx = 160) {
    if (!el || el.tagName !== "TEXTAREA") return;
    const prevOverflow = el.style.overflowY;
    el.style.overflowY = "hidden";
    el.style.height = "0";
    el.style.height = Math.min(el.scrollHeight, maxHeightPx) + "px";
    el.style.overflowY = prevOverflow || "auto";
  }

  _scrollToBottom() {
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    setTimeout(() => {
      const container = this.template.querySelector(".messages-area");
      if (container) {
        container.scrollTop = container.scrollHeight;
      }
    }, 50);
  }

  _makeMsg(role, content) {
    return {
      id: this._uid(),
      role,
      content,
      timestamp: this._now(),
      isAgent: role === "agent",
      isUser: role === "user",
      isRecords: false,
      isChart: false,
      isCreatedRecord: false,
      rowClass: role === "user" ? "message-row user-msg" : "message-row agent-msg"
    };
  }

  _makeRecordsMsg(recordTabsData) {
    return {
      id: this._uid(),
      role: "records",
      content: "",
      timestamp: this._now(),
      isAgent: false,
      isUser: false,
      isRecords: true,
      isChart: false,
      isCreatedRecord: false,
      recordTabsData,
      rowClass: "message-row records-msg"
    };
  }

  _makeChartMsg(chartData) {
    return {
      id: this._uid(),
      role: "chart",
      content: "",
      timestamp: this._now(),
      isAgent: false,
      isUser: false,
      isRecords: false,
      isChart: true,
      isCreatedRecord: false,
      chartData,
      rowClass: "message-row chart-msg"
    };
  }

  _makeCreatedRecordMsg(createdRecordData) {
    return {
      id: this._uid(),
      role: "created-record",
      content: "",
      timestamp: this._now(),
      isAgent: false,
      isUser: false,
      isRecords: false,
      isChart: false,
      isCreatedRecord: true,
      createdRecordData,
      rowClass: "message-row created-record-msg"
    };
  }

  _singularize(label) {
    if (!label) return label;
    if (label.endsWith("ies")) return label.slice(0, -3) + "y";
    if (label.endsWith("ses") || label.endsWith("xes") || label.endsWith("zes") || label.endsWith("hes")) return label.slice(0, -2);
    if (label.endsWith("s") && !label.endsWith("ss")) return label.slice(0, -1);
    return label;
  }

  _uid() {
    return "m-" + Date.now() + "-" + Math.random().toString(36).substr(2, 5);
  }

  _now() {
    return new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  }

  // ─── Hide Default Header ─────────────────────────────

  hideDefaultHeader() {
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    setTimeout(() => {
      const flexipageContainer = document.querySelector(".flexipageTemplate");
      if (!flexipageContainer) return;

      const defaultHeaders = flexipageContainer.querySelectorAll(
        ".slds-page-header, header.slds-page-header"
      );

      defaultHeaders.forEach((header) => {
        const isOurs = header.closest("c-agentforce-workspace");
        if (!isOurs) {
          const text = header.textContent || "";
          if (
            text.includes("Agentforce Workspace") ||
            header.querySelector(".slds-page-header__title")
          ) {
            header.style.display = "none";
            header.style.visibility = "hidden";
            header.style.height = "0";
            header.style.overflow = "hidden";
          }
        }
      });
    }, 200);
  }
}
