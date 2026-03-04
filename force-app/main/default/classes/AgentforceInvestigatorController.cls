/**
 * Controller for the Agentforce Investigator chat interface.
 * Provides a conversational BI experience by translating natural language
 * questions into SOQL queries (via BusinessIntelligence helpers), executing
 * them as the running user, and returning AI-powered analysis with
 * suggested follow-up questions.
 */
public with sharing class AgentforceInvestigatorController {

    private static final String DEFAULT_MODEL = 'sfdc_ai__DefaultVertexAIGemini30Flash';

    // Core CRM objects that get record list views below the chat
    private static final Set<String> LIST_VIEW_OBJECTS = new Set<String>{
        'Account', 'Opportunity', 'Contact', 'Case', 'Lead', 'Campaign',
        'Task', 'Event'
    };

    private static final Map<String, String> OBJECT_ICONS = new Map<String, String>{
        'Account' => 'standard:account',
        'Opportunity' => 'standard:opportunity',
        'Contact' => 'standard:contact',
        'Case' => 'standard:case',
        'Lead' => 'standard:lead',
        'Campaign' => 'standard:campaign',
        'Task' => 'standard:task',
        'Event' => 'standard:event'
    };

    private static final Map<String, String> OBJECT_NAME_FIELDS = new Map<String, String>{
        'Account' => 'Name',
        'Opportunity' => 'Name',
        'Contact' => 'Name',
        'Case' => 'CaseNumber',
        'Lead' => 'Name',
        'Campaign' => 'Name',
        'Task' => 'Subject',
        'Event' => 'Subject'
    };

    private static final List<String> TAB_ORDER = new List<String>{
        'Opportunity', 'Account', 'Contact', 'Lead', 'Case', 'Campaign',
        'Task', 'Event'
    };

    // Default sort field per object type (raw values stored in _sortKey)
    private static final Map<String, String> DEFAULT_SORT_FIELD = new Map<String, String>{
        'Opportunity' => 'CloseDate',
        'Case' => 'CreatedDate',
        'Lead' => 'CreatedDate',
        'Account' => 'Name',
        'Contact' => 'Name',
        'Campaign' => 'StartDate',
        'Task' => 'ActivityDate',
        'Event' => 'StartDateTime'
    };

    private static final Set<String> SORT_DESCENDING = new Set<String>{
        'Opportunity', 'Case', 'Lead', 'Campaign', 'Task', 'Event'
    };

    // Default fields for supplementary detail queries when only aggregates were returned
    private static final Map<String, String> DEFAULT_LIST_FIELDS = new Map<String, String>{
        'Opportunity' => 'Id, Name, Account.Name, StageName, Amount, CloseDate',
        'Account' => 'Id, Name, Industry, Type, Phone',
        'Contact' => 'Id, Name, Account.Name, Email, Phone, Title',
        'Case' => 'Id, CaseNumber, Subject, Status, Priority, CreatedDate',
        'Lead' => 'Id, Name, Company, Status, Email, CreatedDate',
        'Campaign' => 'Id, Name, Status, Type, StartDate',
        'Task' => 'Id, Subject, Who.Name, What.Name, Status, ActivityDate, TaskSubtype',
        'Event' => 'Id, Subject, Who.Name, What.Name, StartDateTime, EndDateTime, Location'
    };

    /** Wire-friendly result wrapper returned to the LWC. */
    public class ChatResult {
        @AuraEnabled public String response;
        @AuraEnabled public List<String> suggestions;
        @AuraEnabled public List<RecordTab> recordTabs;
        @AuraEnabled public Boolean forceRecordUpdate;
        @AuraEnabled public CreatedRecordInfo createdRecord;
        public ChatResult() {
            this.suggestions = new List<String>();
            this.recordTabs = new List<RecordTab>();
            this.forceRecordUpdate = false;
        }
    }

    /** Structured info about a newly created record for the frontend card. */
    public class CreatedRecordInfo {
        @AuraEnabled public String objectApiName;
        @AuraEnabled public String objectLabel;
        @AuraEnabled public String iconName;
        @AuraEnabled public String recordId;
        @AuraEnabled public String recordName;
        @AuraEnabled public String recordUrl;
        @AuraEnabled public List<RecordField> fields;
        public CreatedRecordInfo() {
            this.fields = new List<RecordField>();
        }
    }

    /** A single field label + value pair for the created record card. */
    public class RecordField {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        @AuraEnabled public String type;
    }

    /** Result from buildQueries() — enables two-stage frontend flow. */
    public class QueryResult {
        @AuraEnabled public List<RecordTab> recordTabs;
        @AuraEnabled public String executionDataJson;
        @AuraEnabled public String querySummary;
        @AuraEnabled public Boolean hasResults;
        public QueryResult() {
            this.recordTabs = new List<RecordTab>();
            this.hasResults = false;
        }
    }

    /** Tab of records for a single object type in the list view. */
    public class RecordTab {
        @AuraEnabled public String objectApiName;
        @AuraEnabled public String objectLabel;
        @AuraEnabled public String iconName;
        @AuraEnabled public Integer recordCount;
        @AuraEnabled public Integer totalCount;  // from COUNT() query — null if not available
        @AuraEnabled public List<ColumnDef> columns;
        @AuraEnabled public List<Map<String, String>> rows;
        public RecordTab() {
            this.columns = new List<ColumnDef>();
            this.rows = new List<Map<String, String>>();
        }
    }

    /** Column definition for the record list view. */
    public class ColumnDef {
        @AuraEnabled public String label;
        @AuraEnabled public String fieldName;
        @AuraEnabled public String type;
        @AuraEnabled public Boolean isNameField;
        @AuraEnabled public String linkObjectApiName;  // if set, cell links to this object
        @AuraEnabled public String linkIdField;         // row key holding the linked record's ID
    }

    /** Row sort wrapper for ordering list view records. */
    private class RowSorter implements Comparable {
        public Map<String, String> row;
        private String sortKey;
        private Boolean descending;

        public RowSorter(Map<String, String> r, String sortField, Boolean isDescending) {
            this.row = r;
            this.sortKey = r.containsKey(sortField) ? r.get(sortField) : '';
            if (this.sortKey == null) this.sortKey = '';
            this.descending = isDescending;
        }

        public Integer compareTo(Object other) {
            RowSorter o = (RowSorter) other;
            Integer result;
            // Use numeric comparison when both values are numbers (Amount, etc.)
            if (String.isNotBlank(this.sortKey) && String.isNotBlank(o.sortKey)) {
                try {
                    Decimal d1 = Decimal.valueOf(this.sortKey);
                    Decimal d2 = Decimal.valueOf(o.sortKey);
                    if (d1 > d2) result = 1;
                    else if (d1 < d2) result = -1;
                    else result = 0;
                } catch (Exception e) {
                    result = this.sortKey.compareTo(o.sortKey);
                }
            } else {
                result = this.sortKey.compareTo(o.sortKey);
            }
            return descending ? -result : result;
        }
    }

    /** Sort strings by length descending for record link injection. */
    private class NameLengthSorter implements Comparable {
        public String name;
        public NameLengthSorter(String n) { this.name = n; }
        public Integer compareTo(Object other) {
            return ((NameLengthSorter) other).name.length() - this.name.length();
        }
    }

    /** Serializable wrapper for passing execution data between buildQueries and analyzeResults. */
    private class ExecutionData {
        public String queryResultsText;
        public Map<String, List<String>> recordLinks;
        public String userName;
        public Boolean hasAnyResults;
    }

    @AuraEnabled
    public static ChatResult chat(String userMessage, String conversationHistory, String modelName) {
        ChatResult error = new ChatResult();
        if (String.isBlank(userMessage)) {
            error.response = '<p>Please provide a question.</p>';
            return error;
        }

        String resolvedModel = String.isNotBlank(modelName) ? modelName : DEFAULT_MODEL;

        try {
            String userId = UserInfo.getUserId();
            String userName = UserInfo.getName();

            // --- Pass 1: NL to SOQL ---
            String schemaContext = BusinessIntelligence.buildSchemaContext();
            String nlToSoqlPrompt = buildNLtoSOQLPrompt(userMessage, conversationHistory, userId, userName, schemaContext);
            String soqlResponse = callModelsAPI(nlToSoqlPrompt, resolvedModel);

            // ── Check for record creation action before SOQL parsing ──
            Map<String, Object> createAction = parseCreateAction(soqlResponse);
            if (createAction != null) {
                String action = (String) createAction.get('action');
                if (action == 'create') {
                    return handleCreateConfirm(createAction, userName, resolvedModel);
                } else if (action == 'create_execute') {
                    return handleCreateExecute(createAction, userName, resolvedModel);
                }
            }

            List<BusinessIntelligence.QueryPlan> plans = BusinessIntelligence.parseAndValidateSOQL(soqlResponse);

            if (plans.isEmpty()) {
                error.response = '<p>I couldn\'t generate a valid query for that question. Could you try rephrasing it?</p>';
                return error;
            }

            // --- Execute validated queries as running user ---
            List<BusinessIntelligence.QueryExecution> executions = BusinessIntelligence.executeQueries(plans);

            // --- Consolidated data collection ---
            Set<Id> allOppIds = collectAllOppIds(executions);
            Set<String> objectsWithRecords = findObjectsWithRecords(executions);
            Map<String, List<SObject>> supplementaryRecords = runSupplementaryQueries(executions, objectsWithRecords);

            // Collect supplementary Opportunity IDs for account lookup
            if (supplementaryRecords.containsKey('Opportunity')) {
                for (SObject rec : supplementaryRecords.get('Opportunity')) {
                    if (rec.Id != null) allOppIds.add(rec.Id);
                }
            }

            Map<Id, Opportunity> oppAccountMap = lookupOppAccounts(allOppIds);
            Map<String, List<String>> recordLinks = collectRecordLinks(executions, oppAccountMap, supplementaryRecords);

            // --- Pass 2: Results to Analysis ---
            String analysisPrompt = buildAnalysisPrompt(userMessage, conversationHistory, userName, executions, recordLinks);
            String rawResponse = callModelsAPI(analysisPrompt, resolvedModel);

            // Fallback: inject links for any names the LLM missed
            rawResponse = injectRecordLinks(rawResponse, recordLinks);

            // Build record tabs for the list view (core CRM objects only)
            List<RecordTab> recordTabs = buildRecordTabs(executions, oppAccountMap, supplementaryRecords);

            ChatResult result = parseSuggestions(rawResponse);
            result.recordTabs = recordTabs;
            return result;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'AgentforceInvestigator error: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, 'Stack: ' + e.getStackTraceString());
            error.response = '<p>Something went wrong while analyzing your question. Please try again.</p>';
            return error;
        }
    }

    // ─── Pass 1 Prompt ────────────────────────────────────────

    private static String buildNLtoSOQLPrompt(String userMessage, String conversationHistory,
                                               String userId, String userName, String schemaContext) {
        List<String> parts = new List<String>();

        parts.add('You are a Salesforce SOQL expert. Your ONLY job is to convert a natural language question into one or more SOQL queries.\n\n');

        parts.add('## RULES\n');
        parts.add('1. For data questions, generate ONLY SELECT queries. Never generate INSERT, UPDATE, DELETE, or UPSERT as SOQL.\n');
        parts.add('2. Every query MUST include a LIMIT clause. Maximum LIMIT is 200.\n');
        parts.add('3. Only query objects from the schema provided below.\n');
        parts.add('4. Use the running user\'s ID for "my" queries (e.g., WHERE OwnerId = \'' + userId + '\').\n');
        parts.add('5. Today\'s date is ' + Date.today().format() + '. Use this for relative date calculations.\n');
        parts.add('6. For date ranges, prefer Salesforce date literals: TODAY, YESTERDAY, THIS_WEEK, LAST_WEEK, THIS_MONTH, LAST_MONTH, THIS_QUARTER, LAST_QUARTER, THIS_YEAR, LAST_YEAR, NEXT_N_DAYS:n, LAST_N_DAYS:n, NEXT_N_MONTHS:n, LAST_N_MONTHS:n.\n');
        parts.add('7. Use aggregate functions (COUNT, SUM, AVG, MIN, MAX) with GROUP BY when the question asks for totals, averages, or grouped data.\n');
        parts.add('8. For questions requiring data from multiple objects, generate multiple queries.\n');
        parts.add('9. Always include relevant fields that help answer the question.\n');
        parts.add('10. Prefer ORDER BY on relevant fields (e.g., CloseDate, Amount, CreatedDate).\n');
        parts.add('11. Do NOT use SOQL reserved words as aliases.\n');
        parts.add('12. For Opportunity stages use the exact stage names from the schema.\n');
        parts.add('13. CRITICAL: NEVER use OR with subqueries. If you need records matching EITHER condition, generate TWO separate queries.\n');
        parts.add('14. ALWAYS PAIR detail queries with aggregate counts: for EVERY detail SELECT, also generate a matching COUNT() query with the same WHERE clause. Put the COUNT query FIRST. For grouped aggregates, a separate COUNT is not needed.\n');
        parts.add('15. If the user wants to CREATE, ADD, or MAKE a new record, do NOT generate queries. Output a create action JSON instead.\n');
        parts.add('16. Record creation is currently supported for: Account only. If asked to create other types, still output a normal query response.\n');
        parts.add('17. For a NEW create request: {"action":"create","objectApiName":"Account","fields":{"Name":"value from user"}} — include any fields the user already mentioned.\n');
        parts.add('18. When conversation history shows a pending create and user provides more fields or confirms (e.g. "create it", "go ahead", "yes", "that\'s it"): {"action":"create_execute","objectApiName":"Account","fields":{"Name":"...","Industry":"...", ...}} — merge ALL fields from the full conversation.\n');
        parts.add('19. Account creatable fields: Name (required), Industry (picklist), Type (picklist: Prospect|Customer - Direct|Customer - Channel|Channel Partner / Reseller|Technology Partner|Other), Phone, Website, BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry, Description, NumberOfEmployees (integer), AnnualRevenue (currency number only, no $ sign).\n');
        parts.add('20. MEETINGS/EVENTS → ACCOUNTS → CASES PATTERN: When the question involves meetings/events AND their related Accounts or Cases, you MUST generate separate Account and Case queries using SOQL subquery joins via Event.WhatId. SOQL supports this pattern:\n');
        parts.add('    - Accounts from meetings: SELECT Id, Name, Industry, Type, Phone FROM Account WHERE Id IN (SELECT WhatId FROM Event WHERE OwnerId = \'' + userId + '\' AND ActivityDate = THIS_WEEK) LIMIT 200\n');
        parts.add('    - Cases for meeting accounts: SELECT Id, CaseNumber, Subject, Status, Priority, AccountId FROM Case WHERE AccountId IN (SELECT WhatId FROM Event WHERE OwnerId = \'' + userId + '\' AND ActivityDate = THIS_WEEK) AND IsClosed = false ORDER BY CreatedDate DESC LIMIT 200\n');
        parts.add('    - For high-priority cases: add AND Priority = \'High\' to the Case WHERE clause.\n');
        parts.add('    - ALWAYS generate all three queries (Event, Account, Case) when the question asks about meetings + accounts + cases.\n\n');

        parts.add('## RUNNING USER CONTEXT\n');
        parts.add('- User ID: ' + userId + '\n');
        parts.add('- User Name: ' + userName + '\n');
        parts.add('- When the user says "my", "mine", or "I", filter by OwnerId = \'' + userId + '\'\n\n');

        parts.add(schemaContext);

        if (String.isNotBlank(conversationHistory)) {
            parts.add('\n## CONVERSATION CONTEXT\n');
            parts.add('The user is in a multi-turn conversation. Use this context to resolve references like "those", "that list", "break it down", etc.\n');
            parts.add(conversationHistory + '\n');
        }

        parts.add('\n## USER QUESTION\n');
        parts.add(userMessage + '\n\n');

        parts.add('## OUTPUT FORMAT\n');
        parts.add('Return ONLY a JSON object with no additional text, no markdown code blocks, no explanation.\n');
        parts.add('For data queries: {"queries":[{"purpose":"Brief description","soql":"SELECT ... OR FIND {...} RETURNING ..."}]}\n');
        parts.add('For new create request: {"action":"create","objectApiName":"Account","fields":{"Name":"value"}}\n');
        parts.add('For create execution: {"action":"create_execute","objectApiName":"Account","fields":{"Name":"val","Industry":"val",...}}\n');
        parts.add('Use SOQL (SELECT) for most queries. Use SOSL (FIND) only for Incident/Problem/Case when you need to search Description (long text).\n');

        return String.join(parts, '');
    }

    // ─── Pass 2 Prompt ────────────────────────────────────────

    /** Build analysis prompt (thin wrapper — delegates to buildAnalysisPromptFromData). */
    private static String buildAnalysisPrompt(String userMessage, String conversationHistory,
                                               String userName, List<BusinessIntelligence.QueryExecution> executions,
                                               Map<String, List<String>> recordLinks) {
        ExecutionData data = new ExecutionData();
        data.queryResultsText = formatQueryResults(executions);
        data.recordLinks = recordLinks;
        data.userName = userName;
        data.hasAnyResults = checkHasAnyResults(executions);
        return buildAnalysisPromptFromData(data, userMessage, conversationHistory);
    }

    /** Build analysis prompt from pre-formatted execution data (used by both chat() and analyzeResults()). */
    private static String buildAnalysisPromptFromData(ExecutionData data, String userMessage, String conversationHistory) {
        List<String> parts = new List<String>();

        parts.add('You are a senior business analyst working inside a Salesforce CRM. ');
        parts.add('A professional named ' + data.userName + ' asked a business intelligence question. ');
        parts.add('You have access to the query results below. Provide a rich, insightful analysis.\n\n');

        parts.add('**Today\'s date:** ' + Datetime.now().format('MMMM d, yyyy') + '\n\n');

        if (String.isNotBlank(conversationHistory)) {
            parts.add('## CONVERSATION SO FAR\n');
            parts.add(conversationHistory + '\n\n');
        }

        parts.add('## CURRENT QUESTION\n');
        parts.add(userMessage + '\n\n');

        parts.add('## QUERY RESULTS\n\n');
        parts.add(data.queryResultsText);

        // Output format instructions
        parts.add('## OUTPUT FORMAT\n\n');
        parts.add('**CRITICAL:** Return clean, compact HTML. No markdown. No code blocks.\n\n');

        parts.add('**VOICE & TONE:**\n');
        parts.add('- You are a helpful business analyst talking to a colleague. Be warm, direct, and insightful.\n');
        parts.add('- Address the user by first name (' + data.userName.split(' ')[0] + ').\n');
        parts.add('- Write in plain business English. Sound like a smart coworker, not a database.\n');
        parts.add('- Focus on WHAT the data means and WHY it matters.\n\n');

        parts.add('**ABSOLUTELY DO NOT INCLUDE:**\n');
        parts.add('- Salesforce record IDs (e.g., 005Hu00000...)\n');
        parts.add('- Field API names (e.g., TaskSubtype, OwnerId, StageName) — use plain English\n');
        parts.add('- SOQL date literals (e.g., LAST_MONTH) — use real dates and natural language\n');
        parts.add('- Query methodology explanations\n');
        parts.add('- Any mention of SOQL, queries, the Task object, record types, or filtering logic\n');
        parts.add('- Self-referential commentary about how the analysis was performed\n');
        parts.add('- The word "record" when referring to deals, cases, calls — say "deal", "case", "call" instead\n\n');

        parts.add('**FORMATTING RULES:**\n');
        parts.add('- Use <b>bold</b> for important numbers, dollar amounts, dates, and statuses\n');
        parts.add('- Keep HTML tight — no newlines between tags\n');
        parts.add('- Use <hr/> sparingly — only between major sections\n');
        parts.add('- Keep bullet points concise — 1 line each\n');
        parts.add('- **PREFER <table> for comparisons and grouped data.** When the data has 3+ items with shared dimensions (e.g., stages, types, reps, time periods), present it as a clean HTML table with <thead> and <tbody>. Tables are far easier to scan than bullet lists for numeric comparisons. Use <b> on standout values (highest, lowest, growth %). Example: stage breakdown, rep leaderboard, monthly trend, type comparison.\n\n');

        // Inject record link table so the LLM can embed clickable links
        if (data.recordLinks != null && !data.recordLinks.isEmpty()) {
            parts.add('**RECORD LINKING — MANDATORY:**\n');
            parts.add('Every time you mention an Account, Opportunity, Case, Contact, Lead, or Campaign from the data, you MUST wrap it in a bold link using the exact URL from the table below. '
                + 'Use <a href="..."><b>Name</b></a> — the <b> goes INSIDE the <a>. Examples: '
                + '<a href="/lightning/r/Account/001xxx/view"><b>The City of Irvine</b></a>, '
                + '<a href="/lightning/r/Case/500xxx/view"><b>Case 00001114</b></a>.\n');
            parts.add('Use the EXACT record name/key from this table (do not abbreviate or paraphrase the linked text). '
                + 'For Cases, use the format "Case 00001114" from the table. You may add context OUTSIDE the link.\n\n');
            parts.add('RECORD LINK TABLE:\n');
            for (String name : data.recordLinks.keySet()) {
                List<String> ref = data.recordLinks.get(name);
                parts.add('- "' + name + '" → <a href="/lightning/r/' + ref[1] + '/' + ref[0] + '/view"><b>' + name + '</b></a>\n');
            }
            parts.add('\n');
        }

        parts.add('**REQUIRED STRUCTURE:**\n\n');

        if (!data.hasAnyResults) {
            parts.add('<h1>Title</h1>');
            parts.add('<p>[Explain that no matching data was found. Suggest alternative questions.]</p>');
        } else {
            parts.add('<h1>[Short title summarizing the answer]</h1>');
            parts.add('<p>[1-2 sentence summary directly answering the question with key numbers bolded]</p>');
            parts.add('<hr/>');
            parts.add('<h2>Key Findings</h2>');
            parts.add('<ul><li>[Insight with specific numbers bolded]</li><li>[Another insight]</li></ul>');
            parts.add('<hr/>');
            parts.add('<h2>Detailed Breakdown</h2>');
            parts.add('[Use a <table> to present grouped/comparative data. For 3+ items with numeric dimensions, a table is ALWAYS better than a list. Include computed columns like growth %, averages, or totals where insightful.]');
            parts.add('<hr/>');
            parts.add('<h2>Recommendations</h2>');
            parts.add('<ul><li>[Specific action based on the data]</li></ul>');
            parts.add('<hr/>');
            parts.add('<p><b>[Conversational follow-up]</b> — End with a brief, natural question inviting the user to go deeper into the data. Reference specific records or patterns from your analysis. Examples: "Want me to dig into City of Irvine\'s meeting history?" or "I noticed Omega appears across multiple segments — should I compare their deals side by side?" Keep it to 1-2 sentences.</p>');
        }

        parts.add('\n\nAFTER your HTML response (not inside it), you MUST output this block on its own line:\n');
        parts.add('<SUGGESTIONS>["Short follow-up 1?", "Short follow-up 2?", "Short follow-up 3?"]</SUGGESTIONS>\n');
        parts.add('Rules for suggestions:\n');
        parts.add('- MANDATORY — you must ALWAYS include the SUGGESTIONS block, no exceptions.\n');
        parts.add('- Each suggestion must be under 10 words.\n');
        parts.add('- Make them context-specific to the data and analysis you just provided.\n');
        parts.add('- They should be the most logical next things the user would want to explore.\n');
        parts.add('- Do NOT place the SUGGESTIONS block inside any HTML tag.\n');

        parts.add('\nFINAL REMINDERS:\n');
        parts.add('- HTML only. No markdown. No code blocks.\n');
        parts.add('- No inline CSS, no <div> tags, no class attributes.\n');
        parts.add('- No fabricated data — only reference what is in the query results.\n');
        parts.add('- Replace ALL [placeholder] text with real analysis.\n');
        parts.add('- NEVER expose technical details (IDs, field names, query logic).\n');
        parts.add('- Be specific with real numbers, names, and dates from the data.\n');
        parts.add('- ALWAYS include the <SUGGESTIONS> block at the very end — this is required.\n');

        return String.join(parts, '');
    }

    /** Format execution results as text for the analysis prompt. */
    private static String formatQueryResults(List<BusinessIntelligence.QueryExecution> executions) {
        List<String> parts = new List<String>();
        for (BusinessIntelligence.QueryExecution exec : executions) {
            parts.add('### ' + exec.purpose + '\n');
            parts.add('**Query:** `' + exec.soql + '`\n');
            if (String.isNotBlank(exec.error)) {
                parts.add('**Error:** ' + exec.error + '\n\n');
                continue;
            }
            if (exec.countResult != null) {
                parts.add('**Total Count:** ' + exec.countResult + '\n\n');
                continue;
            }
            if (exec.results == null || exec.results.isEmpty()) {
                parts.add('**Results:** No records found.\n\n');
                continue;
            }
            if (exec.limitReached) {
                parts.add('**Results:** ' + exec.results.size() + ' record(s) shown (display cap reached — use the COUNT query above for the accurate total)\n');
            } else {
                parts.add('**Results:** ' + exec.results.size() + ' record(s)\n');
            }
            for (Integer i = 0; i < Math.min(exec.results.size(), 200); i++) {
                Map<String, Object> fields = exec.results[i].getPopulatedFieldsAsMap();
                List<String> fieldParts = new List<String>();
                for (String fieldName : fields.keySet()) {
                    Object val = fields.get(fieldName);
                    if (val instanceof SObject) {
                        Map<String, Object> relFields = ((SObject) val).getPopulatedFieldsAsMap();
                        for (String relField : relFields.keySet()) {
                            fieldParts.add(fieldName + '.' + relField + ': ' + String.valueOf(relFields.get(relField)));
                        }
                    } else {
                        fieldParts.add(fieldName + ': ' + String.valueOf(val));
                    }
                }
                parts.add((i + 1) + '. ' + String.join(fieldParts, ' | ') + '\n');
            }
            parts.add('\n');
        }
        return String.join(parts, '');
    }

    /** Check if any execution has real results (not just errors). */
    private static Boolean checkHasAnyResults(List<BusinessIntelligence.QueryExecution> executions) {
        for (BusinessIntelligence.QueryExecution exec : executions) {
            if (exec.error != null) continue;
            if (exec.countResult != null) return true;
            if (exec.results != null && !exec.results.isEmpty()) return true;
        }
        return false;
    }

    // ─── Shared Helpers ──────────────────────────────────────────

    /** Collect all Opportunity IDs from execution results. */
    private static Set<Id> collectAllOppIds(List<BusinessIntelligence.QueryExecution> executions) {
        Set<Id> oppIds = new Set<Id>();
        for (BusinessIntelligence.QueryExecution exec : executions) {
            if (exec.error != null || exec.results == null || exec.results.isEmpty()) continue;
            if (exec.countResult != null) continue;
            for (SObject record : exec.results) {
                if (String.valueOf(record.getSObjectType()) == 'Opportunity' && record.Id != null) {
                    oppIds.add(record.Id);
                }
            }
        }
        return oppIds;
    }

    /** Lookup Account info for a set of Opportunity IDs (single consolidated query). */
    private static Map<Id, Opportunity> lookupOppAccounts(Set<Id> oppIds) {
        if (oppIds.isEmpty()) return new Map<Id, Opportunity>();
        return new Map<Id, Opportunity>(
            [SELECT Id, AccountId, Account.Name FROM Opportunity
             WHERE Id IN :oppIds AND AccountId != null
             WITH USER_MODE]
        );
    }

    /** Find which LIST_VIEW_OBJECTS have individual (non-aggregate, non-count) records. */
    private static Set<String> findObjectsWithRecords(List<BusinessIntelligence.QueryExecution> executions) {
        Set<String> objects = new Set<String>();
        for (BusinessIntelligence.QueryExecution exec : executions) {
            if (exec.error != null || exec.results == null || exec.results.isEmpty()) continue;
            if (exec.countResult != null) continue;
            for (SObject record : exec.results) {
                String objType = String.valueOf(record.getSObjectType());
                if (LIST_VIEW_OBJECTS.contains(objType)) objects.add(objType);
            }
        }
        return objects;
    }

    /** Run supplementary detail queries for objects that only appeared in aggregates/counts. */
    private static Map<String, List<SObject>> runSupplementaryQueries(
            List<BusinessIntelligence.QueryExecution> executions, Set<String> objectsWithRecords) {
        Map<String, List<SObject>> results = new Map<String, List<SObject>>();
        Set<String> queriedObjects = new Set<String>();
        Set<Id> eventWhatAccountIds = new Set<Id>();

        for (BusinessIntelligence.QueryExecution exec : executions) {
            if (exec.error != null) continue;
            String objName = parseObjectFromSOQL(exec.soql);
            if (objName != null && LIST_VIEW_OBJECTS.contains(objName)) {
                queriedObjects.add(objName);
            }
            // Collect Account IDs from Event.WhatId to drive supplementary Account/Case tabs
            if (objName == 'Event' && exec.results != null) {
                for (SObject rec : exec.results) {
                    Object whatId = rec.get('WhatId');
                    if (whatId != null) {
                        String whatIdStr = String.valueOf(whatId);
                        if (whatIdStr.startsWith('001')) {
                            eventWhatAccountIds.add((Id) whatIdStr);
                        }
                    }
                }
            }
        }

        // If events returned Account WhatIds, and Account/Case tabs aren't already populated,
        // run supplementary Account and Case queries scoped to those accounts
        if (!eventWhatAccountIds.isEmpty()) {
            if (!objectsWithRecords.contains('Account')) {
                try {
                    List<SObject> accResults = Database.query(
                        'SELECT ' + DEFAULT_LIST_FIELDS.get('Account') + ' FROM Account WHERE Id IN :eventWhatAccountIds WITH USER_MODE LIMIT 200'
                    );
                    if (!accResults.isEmpty()) {
                        results.put('Account', accResults);
                        objectsWithRecords.add('Account');
                    }
                } catch (Exception e) {
                    System.debug(LoggingLevel.WARN, 'Event supplementary Account query failed: ' + e.getMessage());
                }
            }
            if (!objectsWithRecords.contains('Case')) {
                try {
                    List<SObject> caseResults = Database.query(
                        'SELECT ' + DEFAULT_LIST_FIELDS.get('Case') + ' FROM Case WHERE AccountId IN :eventWhatAccountIds AND IsClosed = false WITH USER_MODE ORDER BY Priority ASC, CreatedDate DESC NULLS LAST LIMIT 200'
                    );
                    if (!caseResults.isEmpty()) {
                        results.put('Case', caseResults);
                        objectsWithRecords.add('Case');
                    }
                } catch (Exception e) {
                    System.debug(LoggingLevel.WARN, 'Event supplementary Case query failed: ' + e.getMessage());
                }
            }
        }

        for (String objType : queriedObjects) {
            if (objectsWithRecords.contains(objType)) continue;
            try {
                String fields = DEFAULT_LIST_FIELDS.get(objType);
                if (fields == null) continue;
                String whereClause = extractBestWhereClause(executions, objType);
                String soql = 'SELECT ' + fields + ' FROM ' + objType;
                if (String.isNotBlank(whereClause)) soql += ' WHERE ' + whereClause;
                String supSort = DEFAULT_SORT_FIELD.get(objType);
                if (supSort != null) {
                    soql += ' ORDER BY ' + supSort;
                    if (SORT_DESCENDING.contains(objType)) soql += ' DESC';
                    soql += ' NULLS LAST';
                }
                soql += ' LIMIT 200';
                List<SObject> supResults = Database.query(soql);
                if (!supResults.isEmpty()) {
                    results.put(objType, supResults);
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'Supplementary query failed for ' + objType + ': ' + e.getMessage());
            }
        }
        return results;
    }

    // ─── Two-Stage Flow ─────────────────────────────────────────

    /**
     * Stage 1: Translate NL→SOQL, execute queries, collect record links, build record tabs.
     * Returns immediately-displayable record tabs plus serialized execution data for Stage 2.
     */
    @AuraEnabled
    public static QueryResult buildQueries(String userMessage, String conversationHistory, String modelName) {
        QueryResult result = new QueryResult();
        if (String.isBlank(userMessage)) {
            result.querySummary = 'Please provide a question.';
            return result;
        }

        String resolvedModel = String.isNotBlank(modelName) ? modelName : DEFAULT_MODEL;

        try {
            String userId = UserInfo.getUserId();
            String userName = UserInfo.getName();

            // --- Pass 1: NL to SOQL ---
            String schemaContext = BusinessIntelligence.buildSchemaContext();
            String nlToSoqlPrompt = buildNLtoSOQLPrompt(userMessage, conversationHistory, userId, userName, schemaContext);
            String soqlResponse = callModelsAPI(nlToSoqlPrompt, resolvedModel);

            // Detect AI model errors returned as HTML
            if (String.isBlank(soqlResponse) || soqlResponse.trim().startsWith('<p>Error') || soqlResponse.trim().startsWith('<p>Unexpected') || soqlResponse.trim().startsWith('<p>No response')) {
                result.querySummary = 'The AI model couldn\'t process this request. Try rephrasing your question or switching models.';
                ExecutionData ed = new ExecutionData();
                ed.queryResultsText = '';
                ed.recordLinks = new Map<String, List<String>>();
                ed.userName = userName;
                ed.hasAnyResults = false;
                result.executionDataJson = JSON.serialize(new Map<String, Object>{ 'executionData' => ed });
                return result;
            }

            // Check for record creation action
            Map<String, Object> createAction = parseCreateAction(soqlResponse);
            if (createAction != null) {
                String action = (String) createAction.get('action');
                if (action == 'create') {
                    ChatResult cr = handleCreateConfirm(createAction, userName, resolvedModel);
                    result.executionDataJson = JSON.serialize(new Map<String, Object>{
                        'isCreateResult' => true,
                        'chatResult' => cr
                    });
                    result.querySummary = 'Processing your request...';
                    return result;
                } else if (action == 'create_execute') {
                    ChatResult cr = handleCreateExecute(createAction, userName, resolvedModel);
                    result.executionDataJson = JSON.serialize(new Map<String, Object>{
                        'isCreateResult' => true,
                        'chatResult' => cr
                    });
                    result.querySummary = 'Creating record...';
                    result.hasResults = true;
                    return result;
                }
            }

            List<BusinessIntelligence.QueryPlan> plans = BusinessIntelligence.parseAndValidateSOQL(soqlResponse);

            if (plans.isEmpty()) {
                result.querySummary = 'I couldn\'t generate a valid query for that question.';
                // Provide a fallback so analyzeResults can return a user-friendly message
                ExecutionData ed = new ExecutionData();
                ed.queryResultsText = '';
                ed.recordLinks = new Map<String, List<String>>();
                ed.userName = userName;
                ed.hasAnyResults = false;
                result.executionDataJson = JSON.serialize(new Map<String, Object>{ 'executionData' => ed });
                return result;
            }

            // --- Execute validated queries ---
            List<BusinessIntelligence.QueryExecution> executions = BusinessIntelligence.executeQueries(plans);

            // --- Retry if ALL queries failed (e.g., invalid GROUP BY, bad field) ---
            Boolean allFailed = true;
            List<String> errorMessages = new List<String>();
            for (BusinessIntelligence.QueryExecution exec : executions) {
                if (exec.error == null) {
                    allFailed = false;
                    break;
                }
                errorMessages.add(exec.error + ' | SOQL: ' + exec.soql);
            }
            if (allFailed && !errorMessages.isEmpty()) {
                System.debug(LoggingLevel.WARN, 'All queries failed, attempting retry with error feedback');
                String retryPrompt = nlToSoqlPrompt
                    + '\n\nIMPORTANT: Your previous queries ALL failed with these errors:\n'
                    + String.join(errorMessages, '\n')
                    + '\n\nFix the SOQL errors and try again. Common fixes:'
                    + '\n- Do not use GROUP BY on non-groupable fields (AnnualRevenue, Description, etc.)'
                    + '\n- Use aggregate functions (SUM, AVG, MAX) only with GROUP BY on groupable fields'
                    + '\n- For ranking/sorting, use ORDER BY instead of GROUP BY'
                    + '\n- Ensure field names exist on the queried object'
                    + '\nGenerate corrected SOQL now.';
                String retryResponse = callModelsAPI(retryPrompt, resolvedModel);
                if (String.isNotBlank(retryResponse) && !retryResponse.trim().startsWith('<p>Error')) {
                    List<BusinessIntelligence.QueryPlan> retryPlans = BusinessIntelligence.parseAndValidateSOQL(retryResponse);
                    if (!retryPlans.isEmpty()) {
                        executions = BusinessIntelligence.executeQueries(retryPlans);
                    }
                }
            }

            // --- Consolidated data collection ---
            Set<Id> allOppIds = collectAllOppIds(executions);
            Set<String> objectsWithRecords = findObjectsWithRecords(executions);
            Map<String, List<SObject>> supplementaryRecords = runSupplementaryQueries(executions, objectsWithRecords);

            // Collect supplementary Opportunity IDs for account lookup
            if (supplementaryRecords.containsKey('Opportunity')) {
                for (SObject rec : supplementaryRecords.get('Opportunity')) {
                    if (rec.Id != null) allOppIds.add(rec.Id);
                }
            }

            Map<Id, Opportunity> oppAccountMap = lookupOppAccounts(allOppIds);
            Map<String, List<String>> recordLinks = collectRecordLinks(executions, oppAccountMap, supplementaryRecords);
            List<RecordTab> recordTabs = buildRecordTabs(executions, oppAccountMap, supplementaryRecords);

            // Build query summary — use object labels without raw counts
            // (supplementary queries inflate counts beyond what the analysis focuses on)
            Set<String> queriedLabels = new Set<String>();
            for (RecordTab tab : recordTabs) {
                queriedLabels.add(tab.objectLabel.toLowerCase());
            }

            // Pre-format query results for analyzeResults
            ExecutionData ed = new ExecutionData();
            ed.queryResultsText = formatQueryResults(executions);
            ed.recordLinks = recordLinks;
            ed.userName = userName;
            ed.hasAnyResults = checkHasAnyResults(executions);

            result.executionDataJson = JSON.serialize(new Map<String, Object>{ 'executionData' => ed });
            result.recordTabs = recordTabs;
            result.hasResults = ed.hasAnyResults || !recordTabs.isEmpty();
            result.querySummary = !queriedLabels.isEmpty()
                ? 'Queried ' + String.join(new List<String>(queriedLabels), ' and ')
                : 'Running analysis...';

            return result;

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'buildQueries error: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, 'Stack: ' + e.getStackTraceString());
            String errorDetail = e.getMessage();
            if (errorDetail != null && errorDetail.length() > 200) {
                errorDetail = errorDetail.substring(0, 200);
            }
            // Surface a user-friendly message with enough context to help
            if (errorDetail != null && (errorDetail.containsIgnoreCase('Models API') || errorDetail.containsIgnoreCase('generation'))) {
                result.querySummary = 'The AI service is temporarily unavailable. Please try again in a moment or switch to a different model.';
            } else if (errorDetail != null && errorDetail.containsIgnoreCase('SOQL')) {
                result.querySummary = 'I had trouble building a query for that question. Try rephrasing it more specifically.';
            } else {
                result.querySummary = 'Something went wrong while processing your request. Please try rephrasing or try again.';
            }
            return result;
        }
    }

    /**
     * Stage 2: Analyze pre-fetched query results via AI, inject record links, parse suggestions.
     */
    @AuraEnabled
    public static ChatResult analyzeResults(String executionDataJson, String userMessage, String conversationHistory, String modelName) {
        ChatResult error = new ChatResult();
        if (String.isBlank(executionDataJson)) {
            error.response = '<p>No query data available to analyze.</p>';
            return error;
        }

        String resolvedModel = String.isNotBlank(modelName) ? modelName : DEFAULT_MODEL;

        try {
            Map<String, Object> wrapper = (Map<String, Object>) JSON.deserializeUntyped(executionDataJson);

            // Handle create action results (already processed in buildQueries)
            if (wrapper.containsKey('isCreateResult') && (Boolean) wrapper.get('isCreateResult')) {
                Map<String, Object> crMap = (Map<String, Object>) wrapper.get('chatResult');
                ChatResult cr = new ChatResult();
                cr.response = (String) crMap.get('response');
                cr.forceRecordUpdate = crMap.containsKey('forceRecordUpdate') ? (Boolean) crMap.get('forceRecordUpdate') : false;
                if (crMap.containsKey('suggestions')) {
                    List<Object> sugs = (List<Object>) crMap.get('suggestions');
                    for (Object s : sugs) cr.suggestions.add(String.valueOf(s));
                }
                // Deserialize createdRecord info for the frontend card
                if (crMap.containsKey('createdRecord') && crMap.get('createdRecord') != null) {
                    Map<String, Object> recMap = (Map<String, Object>) crMap.get('createdRecord');
                    CreatedRecordInfo info = new CreatedRecordInfo();
                    info.objectApiName = (String) recMap.get('objectApiName');
                    info.objectLabel = (String) recMap.get('objectLabel');
                    info.iconName = (String) recMap.get('iconName');
                    info.recordId = (String) recMap.get('recordId');
                    info.recordName = (String) recMap.get('recordName');
                    info.recordUrl = (String) recMap.get('recordUrl');
                    if (recMap.containsKey('fields') && recMap.get('fields') != null) {
                        for (Object fObj : (List<Object>) recMap.get('fields')) {
                            Map<String, Object> fMap = (Map<String, Object>) fObj;
                            RecordField rf = new RecordField();
                            rf.label = (String) fMap.get('label');
                            rf.value = (String) fMap.get('value');
                            rf.type = (String) fMap.get('type');
                            info.fields.add(rf);
                        }
                    }
                    cr.createdRecord = info;
                }
                return cr;
            }

            // Deserialize execution data
            Map<String, Object> edMap = (Map<String, Object>) wrapper.get('executionData');
            ExecutionData data = new ExecutionData();
            data.queryResultsText = (String) edMap.get('queryResultsText');
            data.userName = (String) edMap.get('userName');
            data.hasAnyResults = edMap.containsKey('hasAnyResults') ? (Boolean) edMap.get('hasAnyResults') : false;

            // Deserialize record links
            data.recordLinks = new Map<String, List<String>>();
            if (edMap.containsKey('recordLinks') && edMap.get('recordLinks') != null) {
                Map<String, Object> rlMap = (Map<String, Object>) edMap.get('recordLinks');
                for (String name : rlMap.keySet()) {
                    List<Object> refList = (List<Object>) rlMap.get(name);
                    List<String> ref = new List<String>();
                    for (Object r : refList) ref.add(String.valueOf(r));
                    data.recordLinks.put(name, ref);
                }
            }

            // Build analysis prompt from pre-formatted data
            String analysisPrompt = buildAnalysisPromptFromData(data, userMessage, conversationHistory);
            String rawResponse = callModelsAPI(analysisPrompt, resolvedModel);

            // Inject links for any names the LLM missed
            rawResponse = injectRecordLinks(rawResponse, data.recordLinks);

            return parseSuggestions(rawResponse);

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'analyzeResults error: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, 'Stack: ' + e.getStackTraceString());
            error.response = '<p>Something went wrong while analyzing. Please try again.</p>';
            return error;
        }
    }

    // ─── Record Link Injection ─────────────────────────────────

    /**
     * Collect record names → IDs from query results for all core CRM objects
     * so we can hyperlink every record mention in the LLM's HTML response.
     * Uses pre-fetched oppAccountMap and supplementaryRecords to avoid duplicate queries.
     */
    private static Map<String, List<String>> collectRecordLinks(
            List<BusinessIntelligence.QueryExecution> executions,
            Map<Id, Opportunity> oppAccountMap,
            Map<String, List<SObject>> supplementaryRecords) {
        Map<String, List<String>> links = new Map<String, List<String>>();

        // Phase 1: Collect from individual record results
        Set<Id> eventWhatAccountIds = new Set<Id>();
        for (BusinessIntelligence.QueryExecution exec : executions) {
            if (exec.error != null || exec.results == null || exec.results.isEmpty()) continue;
            if (exec.countResult != null) continue;

            for (SObject record : exec.results) {
                String objType = String.valueOf(record.getSObjectType());

                // For LIST_VIEW_OBJECTS: add primary link + traverse relationship fields
                if (LIST_VIEW_OBJECTS.contains(objType)) {
                    addLink(links, record, objType);

                    // Harvest names from relationship fields (e.g., Account.Name on Opportunity)
                    Map<String, Object> fields = record.getPopulatedFieldsAsMap();
                    for (String fieldName : fields.keySet()) {
                        Object val = fields.get(fieldName);
                        if (val instanceof SObject) {
                            SObject rel = (SObject) val;
                            String relType = String.valueOf(rel.getSObjectType());
                            if (LIST_VIEW_OBJECTS.contains(relType)) {
                                addLink(links, rel, relType);
                            }
                        }
                    }
                }

                // For Event records: extract WhatId values that are Account IDs (prefix '001')
                // so we can look up account names for linking even when Account wasn't queried directly
                if (objType == 'Event') {
                    Map<String, Object> eventFields = record.getPopulatedFieldsAsMap();
                    Object whatId = eventFields.get('WhatId');
                    if (whatId != null) {
                        String whatIdStr = String.valueOf(whatId);
                        if (whatIdStr.startsWith('001')) {
                            eventWhatAccountIds.add((Id) whatIdStr);
                        }
                    }
                }
            }
        }

        // Phase 1b: Look up Account names from Event.WhatId Account IDs
        if (!eventWhatAccountIds.isEmpty()) {
            try {
                for (Account acc : [SELECT Id, Name FROM Account WHERE Id IN :eventWhatAccountIds WITH USER_MODE LIMIT 200]) {
                    if (String.isNotBlank(acc.Name) && acc.Name.length() >= 4) {
                        links.put(acc.Name, new List<String>{ acc.Id, 'Account' });
                    }
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'Event account link lookup failed: ' + e.getMessage());
            }
        }

        // Phase 2: Use pre-fetched Account names for Opportunities
        for (Opportunity opp : oppAccountMap.values()) {
            if (opp.Account != null && String.isNotBlank(opp.Account.Name) && opp.Account.Name.length() >= 4) {
                links.put(opp.Account.Name, new List<String>{ opp.AccountId, 'Account' });
            }
        }

        // Phase 3: Use pre-fetched supplementary records for aggregate-only objects
        for (String objType : supplementaryRecords.keySet()) {
            for (SObject rec : supplementaryRecords.get(objType)) {
                addLink(links, rec, objType);
            }
        }

        return links;
    }

    private static void addLink(Map<String, List<String>> links, SObject record, String objType) {
        Map<String, Object> fields = record.getPopulatedFieldsAsMap();
        // Use the configured name field for the object type, falling back to 'Name'
        String nameField = OBJECT_NAME_FIELDS.containsKey(objType) ? OBJECT_NAME_FIELDS.get(objType) : 'Name';
        String name = (String) fields.get(nameField);
        if (String.isBlank(name)) name = (String) fields.get('Name');
        String recordId = record.Id;
        if (String.isBlank(name) || String.isBlank(recordId) || name.length() < 4) return;

        List<String> ref = new List<String>{ recordId, objType };
        links.put(name, ref);

        // Add alternate keys so injectRecordLinks matches common LLM phrasings
        if (objType == 'Case') {
            links.put('Case ' + name, ref);
        }
    }

    /**
     * Fallback: replace any record names the LLM missed with <a> tags.
     * Skips names that are already inside an <a> tag (i.e., the LLM linked them).
     * Uses a two-phase placeholder approach to avoid double-linking.
     */
    private static String injectRecordLinks(String html, Map<String, List<String>> links) {
        if (links.isEmpty() || String.isBlank(html)) return html;

        // Sort names by length descending so longer names match first
        List<NameLengthSorter> sorters = new List<NameLengthSorter>();
        for (String n : links.keySet()) {
            sorters.add(new NameLengthSorter(n));
        }
        sorters.sort();
        List<String> names = new List<String>();
        for (NameLengthSorter s : sorters) {
            names.add(s.name);
        }

        // Phase 1: Replace unlinked names with unique placeholders
        Map<String, String> placeholders = new Map<String, String>();
        for (Integer i = 0; i < names.size(); i++) {
            String name = names[i];
            if (!html.contains(name)) continue;

            // Skip if every occurrence of this name is already inside an <a> tag
            String alreadyLinked = '>' + name + '</a>';
            String alreadyLinkedBold = '><b>' + name + '</b></a>';
            String plainOccurrence = name;
            // Only inject if there's at least one occurrence NOT already inside an <a> tag
            String testHtml = html.replace(alreadyLinked, '');
            if (!testHtml.contains(plainOccurrence)) continue;

            String placeholder = '\u00AB' + i + '\u00BB';
            // Only replace occurrences that are NOT already linked
            // Replace already-linked versions with safe tokens first
            String safeToken = '\u00AC' + i + '\u00AE';
            String safeToken2 = '\u00AC' + i + 'b\u00AE';
            html = html.replace(alreadyLinkedBold, safeToken2);
            html = html.replace(alreadyLinked, safeToken);
            // Now replace remaining (unlinked) occurrences
            html = html.replace(name, placeholder);
            // Restore the already-linked versions
            html = html.replace(safeToken2, alreadyLinkedBold);
            html = html.replace(safeToken, alreadyLinked);
            placeholders.put(placeholder, name);
        }

        // Phase 2: Replace placeholders with <a> tags
        for (String placeholder : placeholders.keySet()) {
            String name = placeholders.get(placeholder);
            List<String> ref = links.get(name);
            String url = '/lightning/r/' + ref[1] + '/' + ref[0] + '/view';
            html = html.replace(placeholder, '<a href="' + url + '"><b>' + name + '</b></a>');
        }

        return html;
    }

    // ─── Suggestion Parser ────────────────────────────────────

    private static ChatResult parseSuggestions(String raw) {
        ChatResult result = new ChatResult();
        if (String.isBlank(raw)) {
            result.response = '';
            return result;
        }

        Integer openTag  = raw.indexOf('<SUGGESTIONS>');
        Integer closeTag = raw.indexOf('</SUGGESTIONS>');

        if (openTag != -1 && closeTag != -1 && closeTag > openTag) {
            result.response = raw.substring(0, openTag).trim();
            String jsonBlock = raw.substring(openTag + 13, closeTag).trim();
            try {
                List<Object> parsed = (List<Object>) JSON.deserializeUntyped(jsonBlock);
                for (Object s : parsed) {
                    String suggestion = String.valueOf(s).trim();
                    if (String.isNotBlank(suggestion)) {
                        result.suggestions.add(suggestion);
                    }
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'Failed to parse suggestions: ' + e.getMessage());
            }
        } else {
            result.response = raw;
        }

        // Fallback: if no suggestions were parsed, generate context-aware defaults
        if (result.suggestions.isEmpty()) {
            result.suggestions = buildFallbackSuggestions(result.response);
        }

        return result;
    }

    /**
     * Generate context-aware fallback suggestions by scanning the response HTML
     * for object types and record names mentioned.
     */
    private static List<String> buildFallbackSuggestions(String responseHtml) {
        List<String> suggestions = new List<String>();
        if (String.isBlank(responseHtml)) {
            suggestions.add('Show my top accounts');
            suggestions.add('Summarize my open pipeline');
            suggestions.add('Any overdue tasks?');
            return suggestions;
        }

        String lower = responseHtml.toLowerCase();

        // Detect object types in the response to make suggestions contextual
        Boolean hasAccounts = lower.contains('account');
        Boolean hasOpps = lower.contains('opportunit') || lower.contains('pipeline') || lower.contains('deal');
        Boolean hasCases = lower.contains('case');
        Boolean hasCampaigns = lower.contains('campaign');
        Boolean hasTasks = lower.contains('task') || lower.contains('activit') || lower.contains('meeting');
        Boolean hasLeads = lower.contains('lead');

        if (hasAccounts) {
            suggestions.add('Which accounts have stale activity?');
            suggestions.add('Break these down by industry');
        }
        if (hasOpps) {
            suggestions.add('Show deals closing this quarter');
            suggestions.add('Which reps own the most pipeline?');
        }
        if (hasCases) {
            suggestions.add('Show high-priority open cases');
            suggestions.add('Average resolution time by type?');
        }
        if (hasCampaigns) {
            suggestions.add('Compare campaign ROI');
            suggestions.add('Which campaigns drove the most leads?');
        }
        if (hasTasks) {
            suggestions.add('Show overdue tasks by owner');
            suggestions.add('Compare activity across top accounts');
        }
        if (hasLeads) {
            suggestions.add('Show leads by source');
            suggestions.add('Lead conversion rate this quarter?');
        }

        // Always offer a pivot if we have fewer than 3
        if (suggestions.size() < 3 && !hasOpps) {
            suggestions.add('Summarize my open pipeline');
        }
        if (suggestions.size() < 3 && !hasAccounts) {
            suggestions.add('Show my top accounts by revenue');
        }
        if (suggestions.size() < 3) {
            suggestions.add('Any overdue tasks this week?');
        }

        // Cap at 3
        while (suggestions.size() > 3) {
            suggestions.remove(suggestions.size() - 1);
        }

        return suggestions;
    }

    // ─── Models API ───────────────────────────────────────────

    private static String callModelsAPI(String promptText, String modelName) {
        try {
            aiplatform.ModelsAPI.createGenerations_Request request =
                new aiplatform.ModelsAPI.createGenerations_Request();
            request.modelName = modelName;

            aiplatform.ModelsAPI_GenerationRequest requestBody =
                new aiplatform.ModelsAPI_GenerationRequest();
            request.body = requestBody;
            requestBody.prompt = promptText;

            aiplatform.ModelsAPI modelsAPI = new aiplatform.ModelsAPI();
            aiplatform.ModelsAPI.createGenerations_Response response =
                modelsAPI.createGenerations(request);

            if (response.Code200 != null && response.Code200.generation != null) {
                return response.Code200.generation.generatedText;
            }
            return '<p>No response received from AI. Please verify Agentforce Generative AI is enabled in your org.</p>';
        } catch (aiplatform.ModelsAPI.createGenerations_ResponseException e) {
            System.debug(LoggingLevel.ERROR, 'Models API Response Exception: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, 'Response code: ' + e.responseCode);
            return '<p>Error during AI analysis: ' + e.getMessage()
                + '</p><p>Please ensure Agentforce AI Models are enabled in Setup.</p>';
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Models API Error: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, 'Stack Trace: ' + e.getStackTraceString());
            return '<p>Unexpected error: ' + e.getMessage() + '</p>';
        }
    }

    // ─── Record List View Builder ─────────────────────────────

    /**
     * Build record tabs from query results for the list view.
     * Groups records by core CRM object type, deduplicates by Id,
     * and determines columns from the SOQL-selected fields.
     * Uses pre-fetched oppAccountMap and supplementaryRecords to avoid duplicate queries.
     */
    private static List<RecordTab> buildRecordTabs(
            List<BusinessIntelligence.QueryExecution> executions,
            Map<Id, Opportunity> oppAccountMap,
            Map<String, List<SObject>> supplementaryRecords) {
        // Collect COUNT() results per object type (take the max if multiple counts)
        Map<String, Integer> countsByObject = new Map<String, Integer>();
        for (BusinessIntelligence.QueryExecution exec : executions) {
            if (exec.countResult == null) continue;
            String objName = parseObjectFromSOQL(exec.soql);
            if (objName != null && LIST_VIEW_OBJECTS.contains(objName)) {
                Integer existing = countsByObject.get(objName);
                if (existing == null || exec.countResult > existing) {
                    countsByObject.put(objName, exec.countResult);
                }
            }
        }

        // Group records by object type, deduplicating by Id
        Map<String, Map<Id, SObject>> recordsByObject = new Map<String, Map<Id, SObject>>();

        for (BusinessIntelligence.QueryExecution exec : executions) {
            if (exec.error != null || exec.results == null || exec.results.isEmpty()) continue;
            if (exec.countResult != null) continue;

            for (SObject record : exec.results) {
                String objType = String.valueOf(record.getSObjectType());
                if (!LIST_VIEW_OBJECTS.contains(objType)) continue;
                if (record.Id == null) continue;

                if (!recordsByObject.containsKey(objType)) {
                    recordsByObject.put(objType, new Map<Id, SObject>());
                }
                recordsByObject.get(objType).put(record.Id, record);
            }
        }

        // Use pre-fetched supplementary records for aggregate-only objects
        for (String supObjType : supplementaryRecords.keySet()) {
            if (recordsByObject.containsKey(supObjType)) continue;
            Map<Id, SObject> recMap = new Map<Id, SObject>();
            for (SObject rec : supplementaryRecords.get(supObjType)) {
                if (rec.Id != null) recMap.put(rec.Id, rec);
            }
            if (!recMap.isEmpty()) {
                recordsByObject.put(supObjType, recMap);
            }
        }

        if (recordsByObject.isEmpty()) return new List<RecordTab>();

        // Detect ORDER BY from original non-aggregate queries to override default sort
        Map<String, String> querySortField = new Map<String, String>();
        Map<String, Boolean> querySortDesc = new Map<String, Boolean>();
        for (BusinessIntelligence.QueryExecution exec : executions) {
            if (exec.error != null || String.isBlank(exec.soql)) continue;
            if (exec.countResult != null) continue;
            // Skip aggregate queries — their ORDER BY doesn't apply to individual records
            if (exec.soql.toUpperCase().contains(' GROUP BY ')) continue;
            String objName = parseObjectFromSOQL(exec.soql);
            if (objName == null || !LIST_VIEW_OBJECTS.contains(objName)) continue;
            String orderField = parseOrderByField(exec.soql);
            if (orderField != null && !querySortField.containsKey(objName)) {
                querySortField.put(objName, orderField);
                querySortDesc.put(objName, isOrderByDescending(exec.soql));
            }
        }

        List<RecordTab> tabs = new List<RecordTab>();
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();

        // Iterate in defined tab order
        for (String objType : TAB_ORDER) {
            if (!recordsByObject.containsKey(objType)) continue;

            Map<Id, SObject> records = recordsByObject.get(objType);
            RecordTab tab = new RecordTab();
            tab.objectApiName = objType;
            tab.objectLabel = globalDescribe.get(objType).getDescribe().getLabelPlural();
            tab.iconName = OBJECT_ICONS.containsKey(objType) ? OBJECT_ICONS.get(objType) : 'standard:record';
            tab.recordCount = records.size();
            tab.totalCount = countsByObject.containsKey(objType) ? countsByObject.get(objType) : null;

            String nameField = OBJECT_NAME_FIELDS.containsKey(objType) ? OBJECT_NAME_FIELDS.get(objType) : 'Name';
            Map<String, Schema.SObjectField> fieldMap = globalDescribe.get(objType).getDescribe().fields.getMap();

            // Collect all field names from the records (union across all records)
            Set<String> allFieldNames = new Set<String>();
            for (SObject rec : records.values()) {
                Map<String, Object> populated = rec.getPopulatedFieldsAsMap();
                for (String fn : populated.keySet()) {
                    Object val = populated.get(fn);
                    if (val instanceof SObject) {
                        // Relationship field — flatten (e.g., Account → Account.Name)
                        SObject rel = (SObject) val;
                        Map<String, Object> relFields = rel.getPopulatedFieldsAsMap();
                        for (String rf : relFields.keySet()) {
                            if (rf != 'Id') {
                                allFieldNames.add(fn + '.' + rf);
                            }
                        }
                    } else if (fn != 'Id') {
                        // Skip reference/lookup fields (raw IDs aren't useful in the table)
                        if (fieldMap.containsKey(fn.toLowerCase())) {
                            Schema.DisplayType dt = fieldMap.get(fn.toLowerCase()).getDescribe().getType();
                            if (dt == Schema.DisplayType.REFERENCE) {
                                continue;
                            }
                        }
                        allFieldNames.add(fn);
                    }
                }
            }

            // Build ordered field list — name field first, then remaining sorted
            List<String> orderedFields = new List<String>();
            if (allFieldNames.contains(nameField)) {
                orderedFields.add(nameField);
                allFieldNames.remove(nameField);
            }
            List<String> remaining = new List<String>(allFieldNames);
            remaining.sort();
            orderedFields.addAll(remaining);

            // Build column definitions
            for (String fn : orderedFields) {
                ColumnDef col = new ColumnDef();
                col.fieldName = fn;
                col.isNameField = (fn == nameField);

                if (fn.contains('.')) {
                    col.label = fn.replace('.', ' ');
                    col.type = 'TEXT';
                    // Opportunity: make Account.Name a clickable link to the Account
                    if (fn == 'Account.Name' && objType == 'Opportunity') {
                        col.label = 'Account';
                        col.linkObjectApiName = 'Account';
                        col.linkIdField = '_accountId';
                    }
                } else if (fieldMap.containsKey(fn.toLowerCase())) {
                    Schema.DescribeFieldResult dfr = fieldMap.get(fn.toLowerCase()).getDescribe();
                    col.label = dfr.getLabel();
                    col.type = dfr.getType().name();
                } else {
                    col.label = fn;
                    col.type = 'TEXT';
                }

                tab.columns.add(col);
            }

            // Build rows
            for (SObject rec : records.values()) {
                Map<String, String> row = new Map<String, String>();
                row.put('_id', rec.Id);

                Map<String, Object> populated = rec.getPopulatedFieldsAsMap();

                // Store sort key — use query ORDER BY if present, else default
                String sortFieldName = querySortField.containsKey(objType) ? querySortField.get(objType) : DEFAULT_SORT_FIELD.get(objType);
                if (sortFieldName != null) {
                    Object rawSortVal = populated.get(sortFieldName);
                    row.put('_sortKey', rawSortVal != null ? String.valueOf(rawSortVal) : '');
                }

                // Opportunity: always capture Account ID for linking
                if (objType == 'Opportunity') {
                    Object acctRel = populated.get('Account');
                    if (acctRel instanceof SObject) {
                        Map<String, Object> acctFields = ((SObject) acctRel).getPopulatedFieldsAsMap();
                        if (acctFields.containsKey('Id')) {
                            row.put('_accountId', String.valueOf(acctFields.get('Id')));
                        }
                    }
                    if (!row.containsKey('_accountId')) {
                        Object acctId = populated.get('AccountId');
                        if (acctId != null) {
                            row.put('_accountId', String.valueOf(acctId));
                        }
                    }
                }

                for (String fn : orderedFields) {
                    if (fn.contains('.')) {
                        // Relationship field (e.g., Account.Name)
                        String[] parts = fn.split('\\.');
                        Object relObj = populated.get(parts[0]);
                        if (relObj instanceof SObject) {
                            Map<String, Object> relFields = ((SObject) relObj).getPopulatedFieldsAsMap();
                            Object val = relFields.get(parts[1]);
                            row.put(fn, val != null ? String.valueOf(val) : '');
                        } else {
                            row.put(fn, '');
                        }
                    } else {
                        Object val = populated.get(fn);
                        String fieldType = 'STRING';
                        if (fieldMap.containsKey(fn.toLowerCase())) {
                            fieldType = fieldMap.get(fn.toLowerCase()).getDescribe().getType().name();
                        }
                        row.put(fn, val != null ? formatFieldValue(val, fieldType) : '');
                    }
                }

                tab.rows.add(row);
            }

            // ── Opportunity: ensure Account column always exists ──
            if (objType == 'Opportunity') {
                Boolean hasAccountCol = false;
                for (ColumnDef col : tab.columns) {
                    if (col.fieldName == 'Account.Name') {
                        hasAccountCol = true;
                        break;
                    }
                }

                if (!hasAccountCol && !oppAccountMap.isEmpty()) {
                    for (Map<String, String> row : tab.rows) {
                        String oppId = row.get('_id');
                        if (String.isNotBlank(oppId)) {
                            try {
                                Opportunity opp = oppAccountMap.get(Id.valueOf(oppId));
                                if (opp != null) {
                                    row.put('_accountId', String.valueOf(opp.AccountId));
                                    row.put('_accountName', opp.Account != null ? opp.Account.Name : '');
                                } else {
                                    row.put('_accountName', '');
                                }
                            } catch (Exception e) {
                                row.put('_accountName', '');
                            }
                        }
                    }

                    ColumnDef acctCol = new ColumnDef();
                    acctCol.fieldName = '_accountName';
                    acctCol.label = 'Account';
                    acctCol.type = 'TEXT';
                    acctCol.isNameField = false;
                    acctCol.linkObjectApiName = 'Account';
                    acctCol.linkIdField = '_accountId';

                    Integer insertIdx = 1;
                    for (Integer i = 0; i < tab.columns.size(); i++) {
                        if (tab.columns[i].isNameField) {
                            insertIdx = i + 1;
                            break;
                        }
                    }
                    tab.columns.add(insertIdx, acctCol);
                }
            }

            // ── Sort rows ──
            String sortField = querySortField.containsKey(objType) ? querySortField.get(objType) : DEFAULT_SORT_FIELD.get(objType);
            Boolean sortDesc = querySortDesc.containsKey(objType) ? querySortDesc.get(objType) : SORT_DESCENDING.contains(objType);
            if (sortField != null && !tab.rows.isEmpty()) {
                sortRows(tab.rows, '_sortKey', sortDesc);
            }

            tabs.add(tab);
        }

        return tabs;
    }

    /** Sort a list of row maps by a given field key. */
    private static void sortRows(List<Map<String, String>> rows, String sortField, Boolean descending) {
        if (rows.size() <= 1) return;
        List<RowSorter> sorters = new List<RowSorter>();
        for (Map<String, String> row : rows) {
            sorters.add(new RowSorter(row, sortField, descending));
        }
        sorters.sort();
        rows.clear();
        for (RowSorter s : sorters) {
            rows.add(s.row);
        }
    }

    /** Extract the object name from a SOQL query (the word after FROM). */
    private static String parseObjectFromSOQL(String soql) {
        if (String.isBlank(soql)) return null;
        String upper = soql.toUpperCase().trim();
        Integer fromIdx = upper.indexOf(' FROM ');
        if (fromIdx == -1) return null;
        String afterFrom = soql.substring(fromIdx + 6).trim();
        Integer spaceIdx = afterFrom.indexOf(' ');
        String objName = spaceIdx > 0 ? afterFrom.substring(0, spaceIdx) : afterFrom;
        return objName.trim();
    }

    /** Find the best (longest) WHERE clause targeting a specific object across all executions. */
    private static String extractBestWhereClause(List<BusinessIntelligence.QueryExecution> executions, String objType) {
        String bestWhere = null;
        for (BusinessIntelligence.QueryExecution exec : executions) {
            if (exec.error != null || String.isBlank(exec.soql)) continue;
            String parsedObj = parseObjectFromSOQL(exec.soql);
            if (parsedObj != objType) continue;
            String upper = exec.soql.toUpperCase();
            Integer whereIdx = upper.indexOf(' WHERE ');
            if (whereIdx == -1) continue;
            String afterWhere = exec.soql.substring(whereIdx + 7);
            for (String kw : new List<String>{' GROUP BY ', ' ORDER BY ', ' HAVING ', ' LIMIT ', ' WITH '}) {
                Integer kwIdx = afterWhere.toUpperCase().indexOf(kw);
                if (kwIdx != -1) {
                    afterWhere = afterWhere.substring(0, kwIdx);
                }
            }
            afterWhere = afterWhere.trim();
            if (String.isNotBlank(afterWhere) && (bestWhere == null || afterWhere.length() > bestWhere.length())) {
                bestWhere = afterWhere;
            }
        }
        return bestWhere;
    }

    /** Extract the primary ORDER BY field name from a SOQL query. */
    private static String parseOrderByField(String soql) {
        if (String.isBlank(soql)) return null;
        String upper = soql.toUpperCase();
        Integer idx = upper.indexOf(' ORDER BY ');
        if (idx == -1) return null;
        String afterOB = soql.substring(idx + 10).trim();
        String firstToken = afterOB.split('\\s+')[0];
        if (firstToken.contains(',')) firstToken = firstToken.split(',')[0];
        // Unwrap aggregate functions like SUM(Amount)
        if (firstToken.contains('(') && firstToken.contains(')')) {
            firstToken = firstToken.substring(firstToken.indexOf('(') + 1, firstToken.indexOf(')'));
        }
        return String.isNotBlank(firstToken) ? firstToken : null;
    }

    /** Check if the ORDER BY clause specifies descending order. */
    private static Boolean isOrderByDescending(String soql) {
        if (String.isBlank(soql)) return false;
        String upper = soql.toUpperCase();
        Integer idx = upper.indexOf(' ORDER BY ');
        if (idx == -1) return false;
        String afterOB = upper.substring(idx + 10);
        Integer limitIdx = afterOB.indexOf(' LIMIT ');
        String orderClause = limitIdx > 0 ? afterOB.substring(0, limitIdx) : afterOB;
        Integer commaIdx = orderClause.indexOf(',');
        if (commaIdx > 0) orderClause = orderClause.substring(0, commaIdx);
        return orderClause.contains(' DESC');
    }

    /** Format a field value for display in the record list view. */
    private static String formatFieldValue(Object val, String fieldType) {
        if (val == null) return '';

        if (val instanceof Decimal) {
            Decimal d = (Decimal) val;
            if (fieldType == 'CURRENCY') {
                return '$' + d.setScale(0).format();
            }
            if (fieldType == 'PERCENT') {
                return d.setScale(1) + '%';
            }
            return d.format();
        }

        if (val instanceof Date) {
            return ((Date) val).format();
        }

        if (val instanceof Datetime) {
            return ((Datetime) val).format('MMM d, yyyy');
        }

        if (val instanceof Boolean) {
            return (Boolean) val ? 'Yes' : 'No';
        }

        return String.valueOf(val);
    }

    // ═══════════════════════════════════════════════════════════
    //  RECORD CREATION
    // ═══════════════════════════════════════════════════════════

    /** Try to parse the LLM response as a create action JSON. Returns null if not a create action. */
    private static Map<String, Object> parseCreateAction(String response) {
        if (String.isBlank(response)) return null;
        String cleaned = response.trim();
        // Strip markdown code blocks
        if (cleaned.startsWith('```')) {
            Integer endBlock = cleaned.lastIndexOf('```');
            if (endBlock > 3) {
                cleaned = cleaned.substring(cleaned.indexOf('\n') + 1, endBlock).trim();
            }
        }
        try {
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(cleaned);
            if (parsed.containsKey('action')) {
                return parsed;
            }
        } catch (Exception e) {
            // Not a create action — fall through to normal SOQL parsing
        }
        return null;
    }

    /** Handle a create confirmation: the user wants to create a record but we ask for more details first. */
    private static ChatResult handleCreateConfirm(Map<String, Object> actionResult, String userName, String modelName) {
        String objectApiName = (String) actionResult.get('objectApiName');
        Map<String, Object> fields = actionResult.containsKey('fields')
            ? (Map<String, Object>) actionResult.get('fields')
            : new Map<String, Object>();

        String prompt = buildCreateConfirmPrompt(objectApiName, fields, userName);
        String response = callModelsAPI(prompt, modelName);

        return parseSuggestions(response);
    }

    /** Build the Pass 2 prompt for create confirmation — asks the user for additional fields. */
    private static String buildCreateConfirmPrompt(String objectApiName, Map<String, Object> fields, String userName) {
        String firstName = userName.split(' ')[0];
        List<String> parts = new List<String>();

        parts.add('You are a helpful Salesforce assistant. ');
        parts.add(firstName + ' wants to create a new ' + objectApiName + ' record.\n\n');

        parts.add('## FIELDS PROVIDED SO FAR\n');
        if (fields.isEmpty()) {
            parts.add('- None yet\n');
        } else {
            for (String fieldName : fields.keySet()) {
                parts.add('- ' + fieldName + ': ' + String.valueOf(fields.get(fieldName)) + '\n');
            }
        }

        parts.add('\n## ADDITIONAL RECOMMENDED FIELDS\n');
        parts.add('These are optional but commonly used on Accounts:\n');
        List<String> recommended = new List<String>{
            'Industry', 'Type', 'Phone', 'Website',
            'BillingCity', 'BillingState',
            'Description', 'NumberOfEmployees', 'AnnualRevenue'
        };
        for (String rec : recommended) {
            if (!fields.containsKey(rec)) {
                parts.add('- ' + rec + '\n');
            }
        }

        parts.add('\n## INSTRUCTIONS\n');
        parts.add('Generate a conversational HTML response that:\n');
        parts.add('1. Acknowledges the create request warmly\n');
        parts.add('2. Confirms the fields already provided (bold the values)\n');
        parts.add('3. Asks for additional details — pick the 4-5 most useful missing fields and briefly explain each\n');
        parts.add('4. Make it clear these are optional and the user can say "create it" whenever ready\n\n');

        parts.add('## OUTPUT FORMAT\n');
        parts.add('Clean HTML only. No markdown. No code blocks. No inline CSS or class attributes.\n');
        parts.add('Use <b>bold</b> for the record name and field values.\n');
        parts.add('Keep it concise and friendly. Address user as ' + firstName + '.\n');
        parts.add('Use <ul><li> for listing the requested fields.\n\n');

        parts.add('After your HTML response, output:\n');
        parts.add('<SUGGESTIONS>["Create it now", "Let me add more details"]</SUGGESTIONS>\n');

        return String.join(parts, '');
    }

    /** Handle create execution: the user confirmed, so create the record and return results. */
    private static ChatResult handleCreateExecute(Map<String, Object> actionResult, String userName, String modelName) {
        ChatResult errorResult = new ChatResult();
        String objectApiName = (String) actionResult.get('objectApiName');
        Map<String, Object> fields = actionResult.containsKey('fields')
            ? (Map<String, Object>) actionResult.get('fields')
            : new Map<String, Object>();

        if (String.isBlank(objectApiName) || fields.isEmpty()) {
            errorResult.response = '<p>I need at least a name to create the record. Could you provide more details?</p>';
            return errorResult;
        }

        // Only Account is supported for now
        Set<String> creatableObjects = new Set<String>{ 'Account' };
        if (!creatableObjects.contains(objectApiName)) {
            errorResult.response = '<p>I can only create Account records right now. Would you like me to create an Account instead?</p>';
            return errorResult;
        }

        try {
            Schema.SObjectType sObjType = Schema.getGlobalDescribe().get(objectApiName);
            if (sObjType == null) {
                errorResult.response = '<p>Unknown object type: ' + objectApiName + '</p>';
                return errorResult;
            }

            // CRUD check
            if (!sObjType.getDescribe().isCreateable()) {
                errorResult.response = '<p>You don\'t have permission to create ' + objectApiName + ' records.</p>';
                return errorResult;
            }

            SObject newRecord = sObjType.newSObject();
            Map<String, Schema.SObjectField> fieldMap = sObjType.getDescribe().fields.getMap();

            for (String fieldName : fields.keySet()) {
                setTypedFieldValue(newRecord, fieldName, String.valueOf(fields.get(fieldName)), fieldMap);
            }

            insert newRecord;

            // Query the created record back for display
            Set<String> queryFieldSet = new Set<String>{ 'Id' };
            String defaultFields = DEFAULT_LIST_FIELDS.get(objectApiName);
            if (defaultFields != null) {
                for (String f : defaultFields.split(',')) {
                    queryFieldSet.add(f.trim());
                }
            }
            for (String f : fields.keySet()) {
                if (fieldMap.containsKey(f.toLowerCase()) &&
                    fieldMap.get(f.toLowerCase()).getDescribe().getType() != Schema.DisplayType.REFERENCE) {
                    queryFieldSet.add(f);
                }
            }

            String queryStr = 'SELECT ' + String.join(new List<String>(queryFieldSet), ', ') +
                              ' FROM ' + objectApiName +
                              ' WHERE Id = \'' + String.escapeSingleQuotes(String.valueOf(newRecord.Id)) + '\'';
            List<SObject> results = Database.query(queryStr);

            if (results.isEmpty()) {
                errorResult.response = '<p>Record was created but could not be retrieved. Record ID: ' + newRecord.Id + '</p>';
                return errorResult;
            }

            SObject created = results[0];

            // Build success response directly (no callout — can't mix DML + callout)
            String response = buildCreateSuccessHtml(objectApiName, created, userName, fieldMap);

            // Build structured record info for the frontend card
            CreatedRecordInfo info = buildCreatedRecordInfo(objectApiName, created, fieldMap);

            ChatResult result = new ChatResult();
            result.response = response;
            result.suggestions = new List<String>{ 'Show me all my accounts', 'Create another account' };
            result.createdRecord = info;
            return result;

        } catch (DmlException e) {
            errorResult.response = '<p>I wasn\'t able to create the record: ' + e.getDmlMessage(0) + '</p><p>Please check the field values and try again.</p>';
            return errorResult;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Create execution error: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, 'Stack: ' + e.getStackTraceString());
            errorResult.response = '<p>Something went wrong while creating the record: ' + e.getMessage() + '</p>';
            return errorResult;
        }
    }

    /** Set a field value on an SObject with proper type conversion. */
    private static void setTypedFieldValue(SObject record, String fieldName, String value,
                                            Map<String, Schema.SObjectField> fieldMap) {
        if (String.isBlank(value) || value == 'null') return;

        Schema.SObjectField field = fieldMap.get(fieldName.toLowerCase());
        if (field == null) return;

        Schema.DisplayType fieldType = field.getDescribe().getType();

        try {
            if (fieldType == Schema.DisplayType.STRING ||
                fieldType == Schema.DisplayType.TEXTAREA ||
                fieldType == Schema.DisplayType.URL ||
                fieldType == Schema.DisplayType.EMAIL ||
                fieldType == Schema.DisplayType.PHONE ||
                fieldType == Schema.DisplayType.PICKLIST) {
                record.put(fieldName, value);
            } else if (fieldType == Schema.DisplayType.CURRENCY ||
                       fieldType == Schema.DisplayType.DOUBLE ||
                       fieldType == Schema.DisplayType.PERCENT) {
                record.put(fieldName, Decimal.valueOf(value.replaceAll('[^0-9.\\-]', '')));
            } else if (fieldType == Schema.DisplayType.INTEGER) {
                record.put(fieldName, Integer.valueOf(value.replaceAll('[^0-9\\-]', '')));
            } else if (fieldType == Schema.DisplayType.DATE) {
                record.put(fieldName, Date.valueOf(value));
            } else if (fieldType == Schema.DisplayType.BOOLEAN) {
                record.put(fieldName, Boolean.valueOf(value));
            } else {
                record.put(fieldName, value);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Could not set field ' + fieldName + ' = ' + value + ': ' + e.getMessage());
        }
    }

    /** Build success HTML directly — avoids a callout after DML. */
    private static String buildCreateSuccessHtml(String objectApiName, SObject created,
                                                  String userName, Map<String, Schema.SObjectField> fieldMap) {
        String firstName = userName.split(' ')[0];
        Map<String, Object> populated = created.getPopulatedFieldsAsMap();
        String recordName = String.valueOf(populated.get('Name'));
        String recordUrl = '/lightning/r/' + objectApiName + '/' + created.Id + '/view';

        List<String> html = new List<String>();
        html.add('<h1>Account Created</h1>');
        html.add('<p>' + firstName + ', I\'ve created <a href="' + recordUrl + '"><b>' + recordName + '</b></a> successfully.</p>');

        // List the fields that were set (skip Id and empty values)
        List<String> fieldItems = new List<String>();
        for (String fn : populated.keySet()) {
            if (fn == 'Id' || fn == 'Name') continue;
            Object val = populated.get(fn);
            if (val == null || val instanceof SObject) continue;
            String displayVal = String.valueOf(val);
            if (String.isBlank(displayVal)) continue;

            // Get friendly label
            String label = fn;
            if (fieldMap.containsKey(fn.toLowerCase())) {
                label = fieldMap.get(fn.toLowerCase()).getDescribe().getLabel();
            }
            fieldItems.add('<li><b>' + label + ':</b> ' + displayVal + '</li>');
        }

        if (!fieldItems.isEmpty()) {
            html.add('<hr/><h2>Details</h2><ul>');
            html.addAll(fieldItems);
            html.add('</ul>');
        }

        return String.join(html, '');
    }

    /** Build structured record info for the frontend created-record card. */
    private static CreatedRecordInfo buildCreatedRecordInfo(String objectApiName, SObject created,
                                                             Map<String, Schema.SObjectField> fieldMap) {
        Schema.SObjectType sObjType = Schema.getGlobalDescribe().get(objectApiName);
        Map<String, Object> populated = created.getPopulatedFieldsAsMap();
        String recordName = String.valueOf(populated.get('Name'));

        CreatedRecordInfo info = new CreatedRecordInfo();
        info.objectApiName = objectApiName;
        info.objectLabel = sObjType.getDescribe().getLabel();
        info.iconName = OBJECT_ICONS.containsKey(objectApiName) ? OBJECT_ICONS.get(objectApiName) : 'standard:record';
        info.recordId = created.Id;
        info.recordName = recordName;
        info.recordUrl = '/lightning/r/' + objectApiName + '/' + created.Id + '/view';

        for (String fn : populated.keySet()) {
            if (fn == 'Id' || fn == 'Name') continue;
            Object val = populated.get(fn);
            if (val == null || val instanceof SObject) continue;

            // Skip reference/lookup IDs
            if (fieldMap.containsKey(fn.toLowerCase())) {
                Schema.DescribeFieldResult dfr = fieldMap.get(fn.toLowerCase()).getDescribe();
                if (dfr.getType() == Schema.DisplayType.REFERENCE) continue;

                RecordField rf = new RecordField();
                rf.label = dfr.getLabel();
                rf.value = formatFieldValue(val, dfr.getType().name());
                rf.type = dfr.getType().name();
                info.fields.add(rf);
            }
        }

        return info;
    }

    @AuraEnabled(cacheable=true)
    public static String getUserFirstName() {
        String firstName = UserInfo.getFirstName();
        if (String.isBlank(firstName)) {
            firstName = UserInfo.getName();
            if (firstName.contains(' ')) {
                firstName = firstName.substring(0, firstName.indexOf(' '));
            }
        }
        return firstName;
    }

    @AuraEnabled(cacheable=true)
    public static String getUserPhotoUrl() {
        List<User> users = [SELECT SmallPhotoUrl FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
        return users.isEmpty() ? null : users[0].SmallPhotoUrl;
    }
}