import { LightningElement, api, track } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import AGENTFORCE_ICON from "@salesforce/resourceUrl/AgentforceRGBIcon";
import GEMINI_LOGO  from "@salesforce/resourceUrl/Gemini";
import OPENAI_LOGO  from "@salesforce/resourceUrl/OpenAI";
import CLAUDE_LOGO  from "@salesforce/resourceUrl/Claude";
import buildQueries from "@salesforce/apex/AgentforceInvestigatorController.buildQueries";
import analyzeResults from "@salesforce/apex/AgentforceInvestigatorController.analyzeResults";
import getUserFirstName from "@salesforce/apex/AgentforceInvestigatorController.getUserFirstName";

const MAX_HISTORY_TURNS = 10;

const MODELS = [
  { id: "sfdc_ai__DefaultVertexAIGemini30Flash",          label: "Gemini Flash 3.0", logoKey: "gemini", premium: false },
  { id: "sfdc_ai__DefaultVertexAIGeminiPro30",            label: "Gemini Pro 3.0",   logoKey: "gemini", premium: false },
  { id: "sfdc_ai__DefaultGPT5",                           label: "GPT-5",            logoKey: "openai", premium: false },
  { id: "sfdc_ai__DefaultGPT52",                          label: "GPT-5.2",          logoKey: "openai", premium: false },
  { id: "sfdc_ai__DefaultBedrockAnthropicClaude45Sonnet", label: "Sonnet 4.5",       logoKey: "claude", premium: false },
  { id: "sfdc_ai__DefaultBedrockAnthropicClaude45Opus",   label: "Opus 4.5",         logoKey: "claude", premium: true  }
];

const LOGO_MAP = {
  gemini: GEMINI_LOGO,
  openai: OPENAI_LOGO,
  claude: CLAUDE_LOGO
};

const DEFAULT_MODEL = MODELS[0].id;

// Stage-aware loading messages — sequential progression
const LOADING_STAGES = [
  { text: "Building queries",          delay: 0 },
  { text: "Querying your org data",    delay: 3000 },
  { text: "Analyzing results",         delay: 6000 },
  { text: "Preparing your answer",     delay: 10000 },
  { text: "Almost done",               delay: 15000 }
];

const GREETING_TEMPLATES = [
  "Hey {name}! {dayGreeting} \u{1F44B} I can query any records in your org, spot pipeline gaps, analyze campaign performance, and even create new accounts. What would you like to explore?",
  "Hi {name}, {dayGreeting} \u{1F680} I'm here to dig into your opportunities, surface account insights, track campaign ROI, or create records on the fly. What's on your mind?",
  "Welcome back, {name}! {dayGreeting} \u{2728} Need to check your pipeline by stage, find accounts with stale activity, or analyze case trends? Just ask \u2014 I've got you.",
  "{dayGreeting}, {name}! \u{1F50D} I can run any query across your CRM \u2014 pipeline forecasts, lead conversion rates, campaign metrics, account health \u2014 you name it.",
  "Good to see you, {name}! {dayGreeting} \u{1F4CA} Whether it's deal velocity, account gaps, open cases, or creating new records, I'm ready to help. Fire away!",
  "Hey there, {name}! {dayGreeting} \u{26A1} Ask me about your top opportunities, campaign engagement, account activity, or let me crunch some numbers for you.",
  "Hi {name}! {dayGreeting} \u{1F3AF} I can analyze your pipeline, compare rep performance, surface at-risk deals, or create records. What do you need today?",
  "{dayGreeting}, {name}! \u{1F4AC} From opportunity stages to case resolution times, account trends to lead sources \u2014 I can pull insights from across your entire org.",
  "Welcome, {name}! {dayGreeting} \u{1F9E0} I'm your BI copilot \u2014 ask me to query records, find patterns in your data, or create new accounts and contacts.",
  "Hey {name}! {dayGreeting} \u{1F31F} Ready to explore your data? I can break down your pipeline, audit account engagement, track campaigns, and more."
];

const DAY_GREETINGS = {
  0: ["Happy Sunday", "Enjoy your Sunday", "Easy Sunday vibes"],
  1: ["Happy Monday", "Let's crush this Monday", "New week, new wins"],
  2: ["Happy Tuesday", "Tuesday's looking good", "Let's make Tuesday count"],
  3: ["Happy Wednesday", "Happy hump day", "Midweek momentum"],
  4: ["Happy Thursday", "Almost Friday", "Thursday \u2014 the finish line is close"],
  5: ["Happy Friday", "TGIF", "Friday energy activated"],
  6: ["Happy Saturday", "Weekend mode", "Saturday hustle"]
};

const CACHE_KEY = "agentforceChat_session";
const GREETING_INDEX_KEY = "agentforceChat_greetingIdx";

// Typewriter: delay between rendering each HTML block (ms)
const TYPEWRITER_BLOCK_DELAY = 100;

export default class AgentforceChat extends NavigationMixin(LightningElement) {
  @api initialMessage = "";
  @track messages = [];
  @track loadingText = LOADING_STAGES[0].text;
  @track suggestedReplies = [];
  @track selectedModelId = DEFAULT_MODEL;
  @track isModelPickerOpen = false;
  @track intermediateStatus = "";
  inputValue = "";
  isLoading = false;
  _initialMessageSent = false;
  _loadingTimerIds = [];
  _typewriterTimerIds = [];
  _cachedRecordTabs = [];

  agentIcon = AGENTFORCE_ICON;

  connectedCallback() {
    if (!this._restoreFromCache()) {
      this._setGreeting();
    }
  }

  disconnectedCallback() {
    this._stopLoadingRotation();
    this._clearTypewriterTimers();
  }

  async _setGreeting() {
    let firstName = "there";
    try {
      const name = await getUserFirstName();
      if (name) firstName = name;
    } catch (_e) {
      // fall back to "there"
    }
    const greeting = this._buildGreeting(firstName);
    this.messages = [this._makeMsg("agent", greeting)];
    this._saveToCache();
    this._maybeSendInitialMessage();
  }

  _maybeSendInitialMessage() {
    if (this._initialMessageSent || !this.initialMessage) return;
    this._initialMessageSent = true;
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    setTimeout(() => {
      this.inputValue = this.initialMessage;
      this.handleSend();
    }, 100);
  }

  _buildGreeting(firstName) {
    // Rotating index guarantees no repeats on consecutive loads/resets
    let idx = 0;
    try {
      const stored = localStorage.getItem(GREETING_INDEX_KEY);
      idx = stored !== null ? (parseInt(stored, 10) + 1) % GREETING_TEMPLATES.length : 0;
    } catch (_e) {
      idx = 0;
    }
    try {
      localStorage.setItem(GREETING_INDEX_KEY, String(idx));
    } catch (_e) {
      // storage full — continue with idx 0
    }

    const template = GREETING_TEMPLATES[idx];
    const dayOfWeek = new Date().getDay();
    const dayOptions = DAY_GREETINGS[dayOfWeek];
    const dayGreeting = dayOptions[Math.floor(Math.random() * dayOptions.length)];

    return template.replace("{name}", firstName).replace("{dayGreeting}", dayGreeting);
  }

  // ─── Cache ──────────────────────────────────────────

  _saveToCache() {
    try {
      const payload = {
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

  _restoreFromCache() {
    try {
      const raw = localStorage.getItem(CACHE_KEY);
      if (!raw) return false;
      const data = JSON.parse(raw);
      // Expire after 24 hours
      if (Date.now() - data.timestamp > 24 * 60 * 60 * 1000) {
        this._clearCache();
        return false;
      }
      this.messages = data.messages || [];
      this.selectedModelId = data.selectedModelId || DEFAULT_MODEL;
      this.suggestedReplies = data.suggestedReplies || [];
      this._cachedRecordTabs = data.recordTabs || [];
      // Restore record list after render
      if (this._cachedRecordTabs.length > 0) {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
          this.dispatchEvent(new CustomEvent('recordsupdate', {
            detail: { recordTabs: this._cachedRecordTabs, forceUpdate: true }
          }));
        }, 0);
      }
      return this.messages.length > 0;
    } catch (_e) {
      return false;
    }
  }

  _clearCache() {
    try {
      localStorage.removeItem(CACHE_KEY);
    } catch (_e) {
      // ignore
    }
  }

  // ─── Getters ────────────────────────────────────────

  get hasMessages() {
    return this.messages.length > 0;
  }

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

  get modelOptions() {
    return MODELS.map((m) => ({
      ...m,
      logo: LOGO_MAP[m.logoKey],
      isActive: m.id === this.selectedModelId,
      itemClass: "model-item" + (m.id === this.selectedModelId ? " model-item-active" : ""),
      logoClass: "model-logo" + (m.logoKey === "openai" ? " model-logo-openai" : "")
    }));
  }

  get modelBtnClass() {
    return "model-btn" + (this.isModelPickerOpen ? " model-btn-open" : "");
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

  // ─── Event Handlers ──────────────────────────────────────

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
    this.isModelPickerOpen = false;
    this._clearCache();
    // Reset chat with new model
    this.messages = [];
    this.suggestedReplies = [];
    this.intermediateStatus = "";
    this._cachedRecordTabs = [];
    this.dispatchEvent(new CustomEvent('recordsupdate', { detail: { recordTabs: [], forceUpdate: true } }));
    this.dispatchEvent(new CustomEvent('loadingchange', { detail: { isLoading: false } }));
    this.inputValue = "";
    this._clearInput();
    this.isLoading = false;
    this._stopLoadingRotation();
    this._setGreeting();
  }

  handleReset() {
    this._clearCache();
    this.messages = [];
    this.suggestedReplies = [];
    this.intermediateStatus = "";
    this._cachedRecordTabs = [];
    this.inputValue = "";
    this._clearInput();
    this.isLoading = false;
    this._stopLoadingRotation();
    this._clearTypewriterTimers();
    this.dispatchEvent(new CustomEvent('recordsupdate', { detail: { recordTabs: [], forceUpdate: true } }));
    this.dispatchEvent(new CustomEvent('loadingchange', { detail: { isLoading: false } }));
    this._setGreeting();
  }

  handleInput(event) {
    this.inputValue = event.target.value;
  }

  handleKeyDown(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      this.handleSend();
    }
  }

  async handleSend() {
    const text = this.inputValue.trim();
    if (!text || this.isLoading) return;

    this.suggestedReplies = [];
    this.intermediateStatus = "";
    this.messages = [...this.messages, this._makeMsg("user", text)];
    this.inputValue = "";
    this._clearInput();
    this.isLoading = true;
    this._startLoadingRotation();
    this._scrollToBottom();
    this._saveToCache();
    this.dispatchEvent(new CustomEvent('loadingchange', { detail: { isLoading: true } }));
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    setTimeout(() => {
      const input = this.template.querySelector(".chat-input");
      if (input) input.focus();
    }, 0);

    try {
      const history = this._buildHistory();

      // ── Stage 1: Build queries + get records ──
      const queryResult = await buildQueries({
        userMessage: text,
        conversationHistory: history,
        modelName: this.selectedModelId
      });

      // Show record tabs immediately (user sees records ~3-6s sooner)
      const recordTabs = queryResult?.recordTabs ?? [];
      if (recordTabs.length > 0) {
        this._cachedRecordTabs = recordTabs;
        this.dispatchEvent(new CustomEvent('recordsupdate', {
          detail: { recordTabs, forceUpdate: false }
        }));
      }

      // Show intermediate status
      const summary = queryResult?.querySummary ?? "";
      if (summary && queryResult?.hasResults) {
        this.intermediateStatus = summary + " \u2014 analyzing now...";
        this._scrollToBottom();
      }

      // Update loading stage text
      this._setLoadingStageText("Analyzing results");

      // ── Stage 2: Analyze results ──
      const executionDataJson = queryResult?.executionDataJson ?? "";
      if (!executionDataJson) {
        // No data to analyze — show summary as response
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
          this.isLoading = false;
          this._stopLoadingRotation();
          this._scrollToBottom();
          this.dispatchEvent(new CustomEvent('loadingchange', { detail: { isLoading: false } }));
          return;
        }

        // Apply typewriter effect
        this.intermediateStatus = "";
        await this._typewriterReveal(responseText);

        // Reconcile record list with analysis output
        this._reconcileRecordTabs(responseText);

        this.suggestedReplies = analysis?.suggestions ?? [];
        this._saveToCache();

        // If a record was created, dispatch the created record info
        if (analysis?.createdRecord) {
          this.dispatchEvent(new CustomEvent('recordcreated', {
            detail: { createdRecord: analysis.createdRecord }
          }));
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
      this.intermediateStatus = "";
      this._stopLoadingRotation();
      this._scrollToBottom();
      this.dispatchEvent(new CustomEvent('loadingchange', { detail: { isLoading: false } }));
    }
  }

  handleSuggestion(event) {
    const question = event.currentTarget.dataset.question;
    if (question) {
      this.suggestedReplies = [];
      this.inputValue = question;
      this.handleSend();
    }
  }

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
      // href format: /lightning/r/{ObjectType}/{RecordId}/view
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

  // ─── Conversation History ────────────────────────────────

  _buildHistory() {
    const turns = this.messages.slice(1); // skip greeting
    const recent = turns.slice(-MAX_HISTORY_TURNS * 2);
    return recent
      .map((m) => (m.role === "user" ? "USER: " : "ASSISTANT: ") + m.content)
      .join("\n");
  }

  // ─── Stage-Aware Loading ───────────────────────────────

  _startLoadingRotation() {
    this._stopLoadingRotation();
    this.loadingText = LOADING_STAGES[0].text;
    // Schedule each stage transition
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

  // ─── Typewriter Effect ──────────────────────────────────

  _clearTypewriterTimers() {
    for (const id of this._typewriterTimerIds) {
      clearTimeout(id);
    }
    this._typewriterTimerIds = [];
  }

  /**
   * Parse HTML into block-level chunks and reveal them progressively.
   * Each block fades up with a staggered delay.
   */
  _typewriterReveal(html) {
    this._clearTypewriterTimers();

    // Parse into block-level chunks
    const blocks = this._parseHtmlBlocks(html);
    if (blocks.length <= 1) {
      // Single block or empty — render immediately
      this.messages = [...this.messages, this._makeMsg("agent", html)];
      return Promise.resolve();
    }

    // Add message with first block immediately
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

    // Reveal remaining blocks with staggered delays
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

  /**
   * Split HTML into block-level chunks by top-level tags.
   * Handles <p>, <h1>-<h6>, <ul>, <ol>, <table>, <hr/>, <hr>.
   */
  _parseHtmlBlocks(html) {
    if (!html) return [];
    // Split on block-level tags while preserving them
    const blockPattern = /(<(?:p|h[1-6]|ul|ol|table|hr\s*\/?)[\s>][\s\S]*?<\/(?:p|h[1-6]|ul|ol|table)>|<hr\s*\/?>)/gi;
    const blocks = [];
    let lastIndex = 0;
    let match;
    // eslint-disable-next-line no-cond-assign
    while ((match = blockPattern.exec(html)) !== null) {
      // Capture any text between blocks
      if (match.index > lastIndex) {
        const between = html.substring(lastIndex, match.index).trim();
        if (between) blocks.push(between);
      }
      blocks.push(match[0]);
      lastIndex = blockPattern.lastIndex;
    }
    // Capture trailing content
    if (lastIndex < html.length) {
      const trailing = html.substring(lastIndex).trim();
      if (trailing) blocks.push(trailing);
    }
    return blocks.length > 0 ? blocks : [html];
  }

  // ─── Post-Analysis Record Reconciliation ───────────────────

  /**
   * After LLM analysis completes, reconcile the record list to only show
   * records actually referenced in the response. For pure aggregate analyses
   * (no individual record links), hide the record list entirely.
   */
  _reconcileRecordTabs(analysisHtml) {
    if (!this._cachedRecordTabs || this._cachedRecordTabs.length === 0) return;

    const referencedIds = this._extractLinkedRecordIds(analysisHtml);

    if (referencedIds.size === 0) {
      // Pure aggregate analysis — hide record list
      this._cachedRecordTabs = [];
      this.dispatchEvent(new CustomEvent('recordsupdate', {
        detail: { recordTabs: [], forceUpdate: true }
      }));
      return;
    }

    // Filter each tab's rows to only referenced records (within each tab's own object type)
    const filteredTabs = this._filterRecordTabs(referencedIds);

    if (filteredTabs.length > 0) {
      this._cachedRecordTabs = filteredTabs;
      this.dispatchEvent(new CustomEvent('recordsupdate', {
        detail: { recordTabs: filteredTabs, forceUpdate: true }
      }));
    } else {
      // No matching rows survived filtering — hide record list
      this._cachedRecordTabs = [];
      this.dispatchEvent(new CustomEvent('recordsupdate', {
        detail: { recordTabs: [], forceUpdate: true }
      }));
    }
  }

  /**
   * Extract Salesforce record IDs from <a href="/lightning/r/{ObjectType}/{RecordId}/view"> links
   */
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

  /**
   * Filter record tabs to only include rows whose _id is in the referenced set.
   * Returns tabs with non-empty rows; drops tabs with zero remaining rows.
   */
  _filterRecordTabs(referencedIds) {
    return this._cachedRecordTabs
      .map((tab) => {
        const filteredRows = (tab.rows || []).filter((row) => {
          // Row _id is the Salesforce record ID
          if (row._id && referencedIds.has(row._id)) return true;
          // Also check 15-char prefix match (IDs can be 15 or 18 char)
          if (row._id && row._id.length === 18) {
            return referencedIds.has(row._id.substring(0, 15));
          }
          if (row._id && row._id.length === 15) {
            for (const refId of referencedIds) {
              if (refId.startsWith(row._id)) return true;
            }
          }
          return false;
        });
        if (filteredRows.length === 0) return null;
        return { ...tab, rows: filteredRows, rowCount: filteredRows.length };
      })
      .filter(Boolean);
  }

  // ─── Markdown Normalizer ──────────────────────────────────
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

  // ─── DOM Helpers ─────────────────────────────────────────

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

  // ─── Initial Suggested Questions ──────────────────────────

  get showSuggestions() {
    return this.messages.length === 1 && !this.isLoading;
  }

  get suggestions() {
    return [
      { id: "s1", question: "What's my pipeline by stage?" },
      { id: "s2", question: "What's the average deal size for closed-won this year?" },
      { id: "s3", question: "Show me accounts with open opps but zero activities in the last 60 days" },
      { id: "s4", question: "How are my campaigns performing this quarter?" },
      { id: "s5", question: "Create a new account" }
    ];
  }
}