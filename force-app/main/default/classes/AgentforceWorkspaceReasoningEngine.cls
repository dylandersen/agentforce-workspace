/**
 * Reasoning engine for the Agentforce Workspace.
 * Replaces the rigid single-shot + single-retry pipeline with:
 *   Pass 0 — Lightweight intent classification (always uses cheapest model)
 *   Pass 1–3 — LLM-driven reasoning loop with progressive simplification
 *
 * The engine classifies what the user wants, then generates SOQL (or action JSON),
 * executes queries, and retries with error diagnosis if any step fails. After
 * MAX_ATTEMPTS it returns a structured failure explanation the UI can render.
 */
public with sharing class AgentforceWorkspaceReasoningEngine {

    private static final Integer MAX_ATTEMPTS = 3;

    // Intent classification always uses the cheapest/fastest model regardless of user selection
    private static final String CLASSIFIER_MODEL = 'sfdc_ai__DefaultVertexAIGemini31FlashLite';

    // ═══════════════════════════════════════════════════════════════
    //  PUBLIC API
    // ═══════════════════════════════════════════════════════════════

    /**
     * Main entry point. Classifies user intent, runs a reasoning loop to produce
     * valid SOQL or a create/update action, and returns a structured result.
     */
    public static AgentforceWorkspaceModels.ReasoningResult reason(
            String userMessage, String conversationHistory,
            String userId, String userName, String modelName) {

        AgentforceWorkspaceModels.ReasoningResult result = new AgentforceWorkspaceModels.ReasoningResult();
        result.attemptsUsed = 0;
        result.executions = new List<BusinessIntelligence.QueryExecution>();

        // ── Pass 0: Intent Classification ──
        AgentforceWorkspaceModels.IntentResult intent = classifyIntent(
            userMessage, conversationHistory);
        result.classifiedIntent = intent;

        // Route: CLARIFY → ask the user to rephrase
        if (intent.intent == 'CLARIFY') {
            result.success = false;
            result.failureExplanation = intent.clarification;
            result.alternativeSuggestions = buildClarificationSuggestions();
            return result;
        }

        // Build schema context once — shared across all attempts
        String schemaContext = BusinessIntelligence.buildSchemaContext(userMessage);
        String resolvedModel = String.isNotBlank(modelName)
            ? modelName : AgentforceWorkspaceAnalysisService.DEFAULT_MODEL;

        // ── Reasoning Loop ──
        List<String> attemptErrors = new List<String>();

        for (Integer attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
            result.attemptsUsed = attempt;

            String prompt = buildAttemptPrompt(
                attempt, userMessage, conversationHistory,
                userId, userName, schemaContext, intent, attemptErrors);

            String llmResponse = AgentforceWorkspaceAnalysisService.callModelsAPI(prompt, resolvedModel);

            // Check for API-level errors
            if (isAIErrorResponse(llmResponse)) {
                attemptErrors.add('Attempt ' + attempt + ': AI model returned an error response.');
                continue;
            }

            // Check for create/update action
            Map<String, Object> createAction = parseCreateActionForgiving(llmResponse);
            if (createAction != null) {
                result.success = true;
                result.createAction = createAction;
                return result;
            }

            // Parse SOQL
            List<BusinessIntelligence.QueryPlan> plans =
                BusinessIntelligence.parseAndValidateSOQL(llmResponse);

            if (plans.isEmpty()) {
                String snippet = (llmResponse != null)
                    ? llmResponse.abbreviate(200) : 'null';
                attemptErrors.add('Attempt ' + attempt
                    + ': No valid SOQL parsed. Raw (truncated): ' + snippet);
                continue;
            }

            // Execute
            List<BusinessIntelligence.QueryExecution> executions =
                BusinessIntelligence.executeQueries(plans);

            Boolean anySuccess = false;
            for (BusinessIntelligence.QueryExecution exec : executions) {
                if (exec.error == null) {
                    anySuccess = true;
                } else {
                    attemptErrors.add('Attempt ' + attempt
                        + ': ' + exec.error + ' | SOQL: ' + exec.soql);
                }
            }

            if (anySuccess) {
                result.success = true;
                result.executions = executions;
                return result;
            }
            // All queries failed this attempt — loop continues
        }

        // ── All attempts exhausted ──
        result.success = false;
        result.failureExplanation = buildFailureExplanation(intent, attemptErrors);
        result.alternativeSuggestions = buildAlternativeSuggestions(intent);
        return result;
    }

    // ═══════════════════════════════════════════════════════════════
    //  INTENT CLASSIFICATION (Pass 0)
    // ═══════════════════════════════════════════════════════════════

    @TestVisible
    private static AgentforceWorkspaceModels.IntentResult classifyIntent(
            String userMessage, String conversationHistory) {

        String prompt = buildIntentPrompt(userMessage, conversationHistory);
        String response;
        try {
            response = AgentforceWorkspaceAnalysisService.callModelsAPI(prompt, CLASSIFIER_MODEL);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Intent classification call failed: ' + e.getMessage());
            return fallbackClassify(userMessage);
        }
        return parseIntentResponse(response, userMessage);
    }

    private static String buildIntentPrompt(String userMessage, String conversationHistory) {
        List<String> p = new List<String>();
        p.add('Classify this Salesforce CRM user message. Return ONLY JSON, no markdown.\n\n');

        p.add('Intents:\n');
        p.add('QUERY — find/show/list/analyze/report on CRM data\n');
        p.add('CREATE — create/add/log/schedule a new record\n');
        p.add('UPDATE — update/change/modify an existing record\n');
        p.add('COMPARE — compare two or more accounts/deals/metrics side by side\n');
        p.add('COMPOSE — draft/write/summarize/compose text content\n');
        p.add('CLARIFY — message is too vague to act on; specify what to ask the user\n');
        p.add('FOLLOWUP — user is confirming, declining, or continuing a previous action\n\n');

        // Include recent conversation tail (keeps prompt cheap — last 3 turns max)
        if (String.isNotBlank(conversationHistory)) {
            List<String> lines = conversationHistory.split('\n');
            Integer start = Math.max(0, lines.size() - 6);
            p.add('Recent conversation:\n');
            for (Integer i = start; i < lines.size(); i++) {
                if (String.isNotBlank(lines[i])) {
                    p.add(lines[i] + '\n');
                }
            }
            p.add('\n');
        }

        p.add('User message: ' + userMessage + '\n\n');
        p.add('Respond with ONLY this JSON (no markdown fences):\n');
        p.add('{"intent":"...","plan":"one sentence plan","confidence":0.0,"clarification":null}\n');

        return String.join(p, '');
    }

    @TestVisible
    private static AgentforceWorkspaceModels.IntentResult parseIntentResponse(
            String response, String userMessage) {

        AgentforceWorkspaceModels.IntentResult result = new AgentforceWorkspaceModels.IntentResult();
        result.intent = 'QUERY';
        result.plan = 'Query Salesforce data';
        result.confidence = 0.5;

        if (String.isBlank(response)) return result;

        try {
            String cleaned = extractJsonObject(response);
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(cleaned);

            if (parsed.containsKey('intent')) {
                result.intent = ((String) parsed.get('intent')).toUpperCase();
            }
            if (parsed.containsKey('plan')) {
                result.plan = (String) parsed.get('plan');
            }
            if (parsed.containsKey('confidence')) {
                result.confidence = Decimal.valueOf(String.valueOf(parsed.get('confidence')));
            }
            if (parsed.containsKey('clarification') && parsed.get('clarification') != null) {
                result.clarification = (String) parsed.get('clarification');
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Intent parse failed, using keyword fallback: ' + e.getMessage());
            result = fallbackClassify(userMessage);
        }

        return result;
    }

    /** Keyword-based fallback when the LLM intent call fails. */
    @TestVisible
    private static AgentforceWorkspaceModels.IntentResult fallbackClassify(String userMessage) {
        AgentforceWorkspaceModels.IntentResult result = new AgentforceWorkspaceModels.IntentResult();
        result.confidence = 0.6;

        String lower = (userMessage != null) ? userMessage.toLowerCase() : '';

        if (matchesAny(lower, new List<String>{
                'create ', 'add a ', 'add an ', 'log a call', 'log a task',
                'schedule ', 'make a', 'new account', 'new contact',
                'new case', 'new lead', 'new opportunity'})) {
            result.intent = 'CREATE';
            result.plan = 'Create a new Salesforce record';
        } else if (matchesAny(lower, new List<String>{
                'update ', 'change ', 'set the', 'modify '})) {
            result.intent = 'UPDATE';
            result.plan = 'Update an existing record';
        } else if (matchesAny(lower, new List<String>{
                'compare', 'versus', ' vs ', 'difference between', 'side by side'})) {
            result.intent = 'COMPARE';
            result.plan = 'Compare CRM data';
        } else if (matchesAny(lower, new List<String>{
                'draft ', 'write ', 'compose ', 'email ', 'summarize', 'summary'})) {
            result.intent = 'COMPOSE';
            result.plan = 'Compose or draft content from CRM data';
        } else if (matchesAny(lower, new List<String>{
                'yes', 'no', 'skip', 'looks good', 'that\'s fine',
                'go ahead', 'do it', 'confirm', 'not now'})) {
            result.intent = 'FOLLOWUP';
            result.plan = 'Continue from previous action';
        } else {
            result.intent = 'QUERY';
            result.plan = 'Query Salesforce data';
        }

        return result;
    }

    // ═══════════════════════════════════════════════════════════════
    //  PROMPT BUILDING (per attempt)
    // ═══════════════════════════════════════════════════════════════

    private static String buildAttemptPrompt(
            Integer attempt, String userMessage, String conversationHistory,
            String userId, String userName, String schemaContext,
            AgentforceWorkspaceModels.IntentResult intent, List<String> previousErrors) {

        if (attempt == 1) {
            return buildIntentEnhancedPrompt(
                userMessage, conversationHistory, userId, userName, schemaContext, intent);
        } else if (attempt == 2) {
            return buildDiagnosticPrompt(
                userMessage, conversationHistory, userId, userName, schemaContext, intent, previousErrors);
        } else {
            return buildSimplifiedPrompt(
                userMessage, userId, userName, schemaContext, intent);
        }
    }

    /**
     * Attempt 1: Modular NL→SOQL prompt gated by intent.
     * Only includes rule modules relevant to the classified intent,
     * reducing prompt size by 40-60% for query-only intents.
     */
    private static String buildIntentEnhancedPrompt(
            String userMessage, String conversationHistory,
            String userId, String userName, String schemaContext,
            AgentforceWorkspaceModels.IntentResult intent) {

        return AgentforceWorkspaceAnalysisService.buildNLtoSOQLPrompt(
            userMessage, conversationHistory, userId, userName, schemaContext, intent);
    }

    /**
     * Attempt 2: LLM-driven error diagnosis and correction (R5).
     * Sends the actual errors with their SOQL for the LLM to reason about,
     * rather than relying on hardcoded hint patterns.
     */
    private static String buildDiagnosticPrompt(
            String userMessage, String conversationHistory,
            String userId, String userName, String schemaContext,
            AgentforceWorkspaceModels.IntentResult intent, List<String> previousErrors) {

        List<String> p = new List<String>();
        p.add('You are a Salesforce SOQL expert. A previous attempt to answer a user question FAILED.\n');
        p.add('Your job: diagnose each error, understand the root cause, and produce CORRECTED SOQL.\n\n');

        p.add('## USER QUESTION\n');
        p.add(userMessage + '\n\n');

        p.add('## INTENT\n');
        p.add(intent.intent + ': ' + intent.plan + '\n\n');

        // R5: Structured error analysis — send actual errors for LLM reasoning
        p.add('## ERROR ANALYSIS\n');
        p.add('Diagnose each error below. Identify the root cause and generate a fix.\n\n');
        for (Integer i = 0; i < previousErrors.size(); i++) {
            p.add('Error ' + (i + 1) + ': ' + previousErrors[i] + '\n');
        }
        p.add('\nCommon root causes and fixes:\n');
        p.add('- "not groupable" → that field cannot be used in GROUP BY; use ORDER BY instead, or group by a picklist/lookup field\n');
        p.add('- "No such column" or "No such field" → field does not exist on that object; check the schema and remove or replace the field\n');
        p.add('- "sObject type X is not supported" → object not enabled in this org; use the closest standard object from the schema\n');
        p.add('- "Didn\'t understand relationship" → wrong relationship name; use the correct one (e.g., Account.Name, Contact.Email)\n');
        p.add('- "Malformed SOQL" → syntax error; simplify the query structure\n');
        p.add('- "Implementation restriction: subquery not supported" → rewrite as a separate query or use a different approach\n');
        p.add('Apply the relevant fix pattern. If no pattern matches, reason about the error text to determine the correct fix.\n\n');

        p.add('## KEY RULES\n');
        p.add('- Every query MUST include LIMIT (max 200)\n');
        p.add('- User ID for "my" queries: OwnerId = \'' + userId + '\'\n');
        p.add('- Today: ' + Date.today().format() + '\n');
        p.add('- Only use objects and fields from the schema below\n');
        p.add('- Prefer simpler queries — a working simple query beats a broken complex one\n');
        p.add('- If a field caused the error, omit it rather than guessing a replacement\n\n');

        p.add(schemaContext);

        if (String.isNotBlank(conversationHistory)) {
            List<String> lines = conversationHistory.split('\n');
            Integer start = Math.max(0, lines.size() - 6);
            p.add('\n## RECENT CONVERSATION\n');
            for (Integer i = start; i < lines.size(); i++) {
                if (String.isNotBlank(lines[i])) p.add(lines[i] + '\n');
            }
        }

        p.add('\n## OUTPUT FORMAT\n');
        p.add('Return ONLY JSON. No markdown, no explanation, no code blocks.\n');
        p.add('For queries: {"queries":[{"purpose":"...","soql":"SELECT ..."}]}\n');
        p.add('For record creation: {"action":"create_execute","objectApiName":"...","fields":{...}}\n');

        return String.join(p, '');
    }

    /**
     * Attempt 3: Stripped-down, simplified approach. No complex patterns,
     * no GROUP BY, no subqueries. Just get SOMETHING that works.
     */
    private static String buildSimplifiedPrompt(
            String userMessage, String userId, String userName,
            String schemaContext, AgentforceWorkspaceModels.IntentResult intent) {

        List<String> p = new List<String>();
        p.add('Generate the SIMPLEST possible SOQL query to answer this question.\n');
        p.add('Previous attempts failed. Use the most basic query pattern possible.\n\n');

        p.add('Question: ' + userMessage + '\n');
        p.add('Intent: ' + intent.plan + '\n');
        p.add('User ID (for "my" queries): ' + userId + '\n');
        p.add('Today: ' + Date.today().format() + '\n\n');

        p.add('STRICT RULES:\n');
        p.add('- Use basic SELECT with WHERE. Include LIMIT 200.\n');
        p.add('- NO GROUP BY. NO subqueries. NO aggregate functions.\n');
        p.add('- Pick the single most relevant object and return its key fields.\n');
        p.add('- Only use objects and fields from the schema below.\n');
        p.add('- If this is a create request, output action JSON.\n\n');

        p.add(schemaContext);

        p.add('\nReturn ONLY: {"queries":[{"purpose":"...","soql":"SELECT ..."}]}\n');
        p.add('Or for creates: {"action":"create_execute","objectApiName":"...","fields":{...}}\n');

        return String.join(p, '');
    }

    // ═══════════════════════════════════════════════════════════════
    //  FAILURE EXPLANATION
    // ═══════════════════════════════════════════════════════════════

    private static String buildFailureExplanation(
            AgentforceWorkspaceModels.IntentResult intent, List<String> errors) {

        List<String> p = new List<String>();
        p.add('<h2>I wasn\'t able to answer that</h2>');
        p.add('<p>Here\'s what I understood:</p>');
        p.add('<ul>');
        p.add('<li><b>What you wanted:</b> ' + humanizeIntent(intent.intent) + '</li>');
        p.add('<li><b>My plan:</b> ' + String.valueOf(intent.plan).escapeHtml4() + '</li>');
        p.add('</ul>');
        p.add('<p>I tried <b>' + errors.size() + ' different approaches</b> but ran into issues each time. ');
        p.add('This usually happens when the question involves fields or objects that aren\'t available in your org, ');
        p.add('or when the data structure doesn\'t support the exact analysis you\'re looking for.</p>');
        p.add('<p>Try one of the suggestions below, or rephrase your question using standard CRM objects like Accounts, Opportunities, Cases, or Contacts.</p>');

        return String.join(p, '');
    }

    private static String humanizeIntent(String intent) {
        if (intent == 'QUERY') return 'Finding and analyzing data';
        if (intent == 'CREATE') return 'Creating a new record';
        if (intent == 'UPDATE') return 'Updating an existing record';
        if (intent == 'COMPARE') return 'Comparing data side by side';
        if (intent == 'COMPOSE') return 'Composing content from CRM data';
        if (intent == 'FOLLOWUP') return 'Continuing the previous action';
        return 'Processing your request';
    }

    private static List<String> buildAlternativeSuggestions(
            AgentforceWorkspaceModels.IntentResult intent) {

        List<String> suggestions = new List<String>();
        if (intent.intent == 'QUERY' || intent.intent == 'COMPARE') {
            suggestions.add('Show my open opportunities');
            suggestions.add('List my accounts');
            suggestions.add('What cases are open?');
        } else if (intent.intent == 'CREATE') {
            suggestions.add('Create a new account');
            suggestions.add('Log a call');
            suggestions.add('Schedule a meeting');
        } else if (intent.intent == 'COMPOSE') {
            suggestions.add('Draft an email to my top account');
            suggestions.add('Summarize my pipeline');
            suggestions.add('Write a meeting recap');
        } else {
            suggestions.add('Show my pipeline');
            suggestions.add('List my accounts');
            suggestions.add('Show open cases');
        }
        return suggestions;
    }

    private static List<String> buildClarificationSuggestions() {
        return new List<String>{
            'Show my open pipeline',
            'List my top accounts',
            'What cases need attention?'
        };
    }

    // ═══════════════════════════════════════════════════════════════
    //  UTILITIES
    // ═══════════════════════════════════════════════════════════════

    /** Extract a JSON object from potentially messy LLM output. */
    @TestVisible
    private static String extractJsonObject(String response) {
        if (String.isBlank(response)) return '{}';
        String cleaned = response.trim();

        // Strip markdown code fences
        if (cleaned.startsWith('```')) {
            Integer firstNewline = cleaned.indexOf('\n');
            if (firstNewline > 0) cleaned = cleaned.substring(firstNewline + 1);
            Integer lastFence = cleaned.lastIndexOf('```');
            if (lastFence > 0) cleaned = cleaned.substring(0, lastFence);
            cleaned = cleaned.trim();
        }

        // Find outermost { ... }
        Integer braceStart = cleaned.indexOf('{');
        Integer braceEnd = cleaned.lastIndexOf('}');
        if (braceStart >= 0 && braceEnd > braceStart) {
            cleaned = cleaned.substring(braceStart, braceEnd + 1);
        }

        return cleaned;
    }

    /**
     * More forgiving create/update action parser — tries to extract action JSON
     * from responses that may have leading/trailing text or markdown fences.
     */
    private static Map<String, Object> parseCreateActionForgiving(String response) {
        // Standard parser first
        Map<String, Object> result = AgentforceWorkspaceRecordCreator.parseCreateAction(response);
        if (result != null) return result;

        // If standard parser failed, try harder with JSON extraction
        if (String.isBlank(response)) return null;
        try {
            String extracted = extractJsonObject(response);
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(extracted);
            if (parsed.containsKey('action') || parsed.containsKey('actions')) {
                return parsed;
            }
        } catch (Exception e) {
            // Not parseable as action JSON
        }
        return null;
    }

    /** Detect HTML error responses returned by the Models API wrapper. */
    private static Boolean isAIErrorResponse(String response) {
        if (String.isBlank(response)) return true;
        String trimmed = response.trim();
        return trimmed.startsWith('<p>Error')
            || trimmed.startsWith('<p>Unexpected')
            || trimmed.startsWith('<p>No response');
    }

    private static Boolean matchesAny(String text, List<String> keywords) {
        for (String kw : keywords) {
            if (text.contains(kw)) return true;
        }
        return false;
    }
}
