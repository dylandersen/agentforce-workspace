import { LightningElement, track } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import AGENTFORCE_ICON from "@salesforce/resourceUrl/AgentforceRGBIcon";
import GEMINI_LOGO from "@salesforce/resourceUrl/Gemini";
import OPENAI_LOGO from "@salesforce/resourceUrl/OpenAI";
import CLAUDE_LOGO from "@salesforce/resourceUrl/Claude";
import NVIDIA_LOGO from "@salesforce/resourceUrl/nvidia";
import buildQueries from "@salesforce/apex/AgentforceInvestigatorController.buildQueries";
import analyzeResults from "@salesforce/apex/AgentforceInvestigatorController.analyzeResults";
import getUserFirstName from "@salesforce/apex/AgentforceInvestigatorController.getUserFirstName";
import getUserPhotoUrl from "@salesforce/apex/AgentforceInvestigatorController.getUserPhotoUrl";

const CACHE_MAX_AGE = 30 * 60 * 1000; // 30 minutes

const MAX_HISTORY_TURNS = 10;

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

const LOADING_STAGES = [
  { text: "Building queries",       delay: 0 },
  { text: "Querying your org data", delay: 3000 },
  { text: "Analyzing results",      delay: 6000 },
  { text: "Preparing your answer",  delay: 10000 },
  { text: "Almost done",            delay: 15000 }
];

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
  @track loadingText = LOADING_STAGES[0].text;
  @track suggestedReplies = [];
  @track selectedModelId = DEFAULT_MODEL;
  @track isModelPickerOpen = false;
  @track intermediateStatus = "";
  @track recordTabs = [];
  @track pendingRecordTabs = null;
  @track isChatLoading = false;
  @track createdRecord = null;

  inputValue = "";
  isLoading = false;
  _loadingTimerIds = [];
  _typewriterTimerIds = [];
  _cachedRecordTabs = [];

  agentIcon = AGENTFORCE_ICON;
  @track userPhotoUrl = '';

  // ─── Task Suggestions ────────────────────────────────

  get taskSuggestions() {
    return [
      { id: "t1", iconName: "utility:opportunity",  iconWrapClass: "task-icon-wrap task-icon-pipeline",  question: "What's my pipeline by stage?" },
      { id: "t2", iconName: "utility:moneybag",     iconWrapClass: "task-icon-wrap task-icon-deals",     question: "What's the average deal size for closed-won this year?" },
      { id: "t3", iconName: "utility:account",       iconWrapClass: "task-icon-wrap task-icon-accounts",  question: "Show me accounts with open opps but zero activities in the last 60 days" },
      { id: "t4", iconName: "utility:graph",          iconWrapClass: "task-icon-wrap task-icon-campaigns", question: "How are my campaigns performing this quarter?" },
      { id: "t5", iconName: "utility:add",            iconWrapClass: "task-icon-wrap task-icon-create",    question: "Create a new account" }
    ];
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

  get showIntermediateStatus() {
    return this.isLoading && this.intermediateStatus;
  }

  get showTypingAvatar() {
    return !this.showIntermediateStatus;
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

  // ─── Record List ──────────────────────────────────────

  get hasRecordTabs() {
    return this.recordTabs && this.recordTabs.length > 0;
  }

  get showRecordList() {
    return (this.hasRecordTabs || this.isChatLoading) && !this.createdRecord;
  }

  get hasCreatedRecord() {
    return this.createdRecord !== null;
  }

  get hasPendingUpdate() {
    return this.pendingRecordTabs !== null;
  }

  // ─── Lifecycle ────────────────────────────────────────

  connectedCallback() {
    this.hideDefaultHeader();
    this._restoreModelChoice();
    this._loadLandingHeadline();
    this._loadUserPhoto();
    this._restoreFromCache();
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
    this._stopLoadingRotation();
    this._clearTypewriterTimers();
  }

  // ─── Landing Handlers ─────────────────────────────────

  handleLandingInput(event) {
    this.landingInputValue = event.target.value;
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
        recordTabs: this._cachedRecordTabs,
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

      // Restore active chat state — only if there are actual messages to show
      if (cached.isLanding === false && cached.messages && cached.messages.length > 0) {
        this.isLanding = false;
        this.messages = cached.messages;
        this.suggestedReplies = cached.suggestedReplies || [];
        this._cachedRecordTabs = cached.recordTabs || [];
        this.recordTabs = cached.recordTabs || [];
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
    this.intermediateStatus = "";
    this._cachedRecordTabs = [];
    this.recordTabs = [];
    this.pendingRecordTabs = null;
    this.isChatLoading = false;
    this.createdRecord = null;
    this.inputValue = "";
    this._clearInput();
    this.isLoading = false;
    this._stopLoadingRotation();
    this._clearTypewriterTimers();
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
    this.intermediateStatus = "";
    this.messages = [...this.messages, this._makeMsg("user", text)];
    this.inputValue = "";
    this._clearInput();
    this.isLoading = true;
    this.isChatLoading = true;
    this._startLoadingRotation();
    this._scrollToBottom();
    this._saveToCache();
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    setTimeout(() => {
      const input = this.template.querySelector(".chat-input");
      if (input) input.focus();
    }, 0);

    try {
      const history = this._buildHistory();

      // Stage 1: Build queries + get records
      const queryResult = await buildQueries({
        userMessage: text,
        conversationHistory: history,
        modelName: this.selectedModelId
      });

      // Show record tabs immediately
      const newRecordTabs = queryResult?.recordTabs ?? [];
      if (newRecordTabs.length > 0) {
        this._cachedRecordTabs = newRecordTabs;
        this._applyRecordTabs(newRecordTabs, false);
      }

      // Show intermediate status
      const summary = queryResult?.querySummary ?? "";
      if (summary && queryResult?.hasResults) {
        this.intermediateStatus = summary + " \u2014 analyzing now...";
        this._scrollToBottom();
      }

      this._setLoadingStageText("Analyzing results");

      // Stage 2: Analyze results
      const executionDataJson = queryResult?.executionDataJson ?? "";
      if (!executionDataJson) {
        const fallback = summary || "I couldn't process that question. Try rephrasing or switching to a different model.";
        this.messages = [...this.messages, this._makeMsg("agent", `<p>${fallback}</p>`)];
        this._saveToCache();
      } else {
        const analysis = await analyzeResults({
          executionDataJson,
          userMessage: text,
          conversationHistory: history,
          modelName: this.selectedModelId
        });

        const rawResponse = analysis?.response ?? analysis ?? "";
        const responseText = this._normalizeMarkdown(rawResponse);

        // Guard against empty AI responses
        if (!responseText || responseText.trim().length === 0) {
          this.messages = [...this.messages, this._makeMsg("agent", "<p>I received an empty response from the AI. Please try your question again or try a different model.</p>")];
          this.intermediateStatus = "";
          this._saveToCache();
          return;
        }

        this.intermediateStatus = "";
        await this._typewriterReveal(responseText);

        this._reconcileRecordTabs(responseText);

        this.suggestedReplies = analysis?.suggestions ?? [];
        this._saveToCache();

        if (analysis?.createdRecord) {
          this.createdRecord = analysis.createdRecord;
          this.recordTabs = [];
          this.pendingRecordTabs = null;
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
      this.isChatLoading = false;
      this.intermediateStatus = "";
      this._stopLoadingRotation();
      this._scrollToBottom();
    }
  }

  // ─── Record Management ────────────────────────────────

  _applyRecordTabs(newTabs, forceUpdate) {
    if (newTabs.length > 0 || forceUpdate) {
      this.createdRecord = null;
    }

    if (forceUpdate) {
      this.recordTabs = newTabs;
      this.pendingRecordTabs = null;
    } else if (newTabs.length > 0) {
      if (this.recordTabs.length === 0) {
        this.recordTabs = newTabs;
        this.pendingRecordTabs = null;
      } else {
        this.pendingRecordTabs = newTabs;
      }
    }
  }

  handleRefreshRecords() {
    if (this.pendingRecordTabs !== null) {
      this.recordTabs = this.pendingRecordTabs;
      this.pendingRecordTabs = null;
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
    const recent = this.messages.slice(-MAX_HISTORY_TURNS * 2);
    return recent
      .map((m) => (m.role === "user" ? "USER: " : "ASSISTANT: ") + m.content)
      .join("\n");
  }

  // ─── Stage-Aware Loading ──────────────────────────────

  _startLoadingRotation() {
    this._stopLoadingRotation();
    this.loadingText = LOADING_STAGES[0].text;
    for (let i = 1; i < LOADING_STAGES.length; i++) {
      const stage = LOADING_STAGES[i];
      // eslint-disable-next-line @lwc/lwc/no-async-operation
      const timerId = setTimeout(() => {
        if (this.isLoading) {
          this.loadingText = stage.text;
        }
      }, stage.delay);
      this._loadingTimerIds.push(timerId);
    }
  }

  _stopLoadingRotation() {
    for (const id of this._loadingTimerIds) {
      clearTimeout(id);
    }
    this._loadingTimerIds = [];
  }

  _setLoadingStageText(text) {
    if (this.isLoading) {
      this._stopLoadingRotation();
      this.loadingText = text;
    }
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

    // No specific records mentioned — keep original tabs as-is
    if (referencedIds.size === 0) {
      this._applyRecordTabs(this._cachedRecordTabs, true);
      return;
    }

    // Group mentioned rows by their source tab (object type)
    // Pick the object with the most mentioned records for the Specific Records tab
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
      // Prepend specific tab, then keep all original tabs
      const combined = [specificTab, ...this._cachedRecordTabs];
      this._applyRecordTabs(combined, true);
    } else {
      this._applyRecordTabs(this._cachedRecordTabs, true);
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

  _extractMentionedRows(referencedIds) {
    const seen = new Set();
    const rows = [];
    for (const tab of this._cachedRecordTabs) {
      for (const row of tab.rows || []) {
        if (this._rowMatchesIds(row, referencedIds) && !seen.has(row._id)) {
          seen.add(row._id);
          rows.push(row);
        }
      }
    }
    return rows;
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
    // Inject inline styles for tables (lightning-formatted-rich-text shadow DOM blocks CSS)
    out = this._inlineTableStyles(out);
    return out;
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

  // ─── DOM Helpers ──────────────────────────────────────

  _clearInput() {
    const input = this.template.querySelector(".chat-input");
    if (input) input.value = "";
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
      rowClass: role === "user" ? "message-row user-msg" : "message-row agent-msg"
    };
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
