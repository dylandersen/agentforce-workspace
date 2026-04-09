/**
 * Prompt construction, Models API calls, and response parsing
 * for the Agentforce Workspace feature.
 */
public with sharing class AgentforceWorkspaceAnalysisService {

    public static final String DEFAULT_MODEL = 'sfdc_ai__DefaultVertexAIGemini31FlashLite';

    // ─── Pass 1 Prompt (Modular) ────────────────────────────────

    /** Backward-compatible overload — includes all modules. Called by BusinessIntelligence.analyze(). */
    public static String buildNLtoSOQLPrompt(String userMessage, String conversationHistory,
                                              String userId, String userName, String schemaContext) {
        return buildNLtoSOQLPrompt(userMessage, conversationHistory, userId, userName, schemaContext, null);
    }

    /**
     * Intent-aware modular prompt builder. Only includes rule modules relevant
     * to the classified intent, reducing prompt size by 40-60% for query-only intents.
     */
    public static String buildNLtoSOQLPrompt(String userMessage, String conversationHistory,
                                              String userId, String userName, String schemaContext,
                                              AgentforceWorkspaceModels.IntentResult intent) {
        List<String> parts = new List<String>();
        String intentType = (intent != null) ? intent.intent : null;

        parts.add('You are a Salesforce SOQL expert. Your ONLY job is to convert a natural language question into one or more SOQL queries.\n\n');

        if (intent != null) {
            parts.add('## CLASSIFIED INTENT\n');
            parts.add('Intent: ' + intent.intent + ' | Plan: ' + intent.plan + '\n');
            parts.add('Use this understanding to guide your output.\n\n');
        }

        appendCoreRules(parts, userId);
        if (shouldIncludeCreateRules(intentType))        appendCreateUpdateRules(parts, userId);
        if (shouldIncludeComposeRules(intentType))       appendComposeRules(parts, userId);
        if (shouldIncludeComplexQueryRules(intentType))   appendComplexQueryRules(parts, userId);
        if (shouldIncludeDataCloudRules(intentType, userMessage)) appendDataCloudRules(parts);

        appendRunningUserContext(parts, userId, userName);
        parts.add(schemaContext);

        if (String.isNotBlank(conversationHistory)) {
            parts.add('\n## CONVERSATION CONTEXT\n');
            parts.add('The user is in a multi-turn conversation. Use this context to resolve references like "those", "that list", "break it down", etc.\n');
            parts.add(conversationHistory + '\n');
        }

        parts.add('\n## USER QUESTION\n');
        parts.add(userMessage + '\n\n');

        appendFewShotExamples(parts, intentType, userId);
        appendOutputFormat(parts, intentType, userId);

        return String.join(parts, '');
    }

    // ─── Module Inclusion Logic ──────────────────────────────────

    private static Boolean shouldIncludeCreateRules(String intentType) {
        return intentType == null || intentType == 'CREATE' || intentType == 'UPDATE' || intentType == 'FOLLOWUP';
    }

    private static Boolean shouldIncludeComposeRules(String intentType) {
        return intentType == null || intentType == 'COMPOSE';
    }

    private static Boolean shouldIncludeComplexQueryRules(String intentType) {
        return intentType == null || intentType == 'QUERY' || intentType == 'COMPARE' || intentType == 'COMPOSE';
    }

    private static Boolean shouldIncludeDataCloudRules(String intentType, String userMessage) {
        if (intentType == null) return true;
        if (String.isBlank(userMessage)) return false;
        String lower = userMessage.toLowerCase();
        return lower.contains('consumption') || lower.contains('credit') || lower.contains('usage')
            || lower.contains('data cloud') || lower.contains('data 360') || lower.contains('monitor');
    }

    // ─── Core SOQL Rules (1-14) — Always Included ───────────────

    private static void appendCoreRules(List<String> parts, String userId) {
        parts.add('## RULES\n');
        parts.add('1. For data questions, generate ONLY SELECT queries. Never generate INSERT, UPDATE, DELETE, or UPSERT as SOQL.\n');
        parts.add('2. Every query MUST include a LIMIT clause. Maximum LIMIT is 200.\n');
        parts.add('3. Only query objects from the schema provided below.\n');
        parts.add('4. Use the running user\'s ID for "my" queries (e.g., WHERE OwnerId = \'' + userId + '\').\n');
        parts.add('5. Today\'s date is ' + Date.today().format() + '. Use this for relative date calculations.\n');
        parts.add('6. For date ranges, prefer Salesforce date literals: TODAY, YESTERDAY, THIS_WEEK, LAST_WEEK, THIS_MONTH, LAST_MONTH, THIS_QUARTER, LAST_QUARTER, THIS_YEAR, LAST_YEAR, NEXT_N_DAYS:n, LAST_N_DAYS:n, NEXT_N_MONTHS:n, LAST_N_MONTHS:n.\n');
        parts.add('7. Use aggregate functions (COUNT, SUM, AVG, MIN, MAX) with GROUP BY when the question asks for totals, averages, or grouped data.\n');
        parts.add('   IMPORTANT: Never GROUP BY long text or non-groupable fields (Subject, Description, Body, Comment, MessageBody, etc.). For activity analysis, GROUP BY ActivityType, Status, or TaskSubtype instead. Use ORDER BY for sorting by text fields.\n');
        parts.add('8. For questions requiring data from multiple objects, generate multiple queries.\n');
        parts.add('9. Always include relevant fields that help answer the question.\n');
        parts.add('10. Prefer ORDER BY on relevant fields (e.g., CloseDate, Amount, CreatedDate).\n');
        parts.add('11. Do NOT use SOQL reserved words as aliases.\n');
        parts.add('12. For Opportunity stages use the exact stage names from the schema.\n');
        parts.add('12b. OBJECT RESOLUTION FROM NATURAL LANGUAGE: When the user mentions a business noun (for example, "invoice", "contract", "ticket"), resolve it to the most likely Salesforce object using the schema below.\n');
        parts.add('    - Use BOTH object label similarity and API name similarity.\n');
        parts.add('    - Treat singular/plural as equivalent (invoice/invoices).\n');
        parts.add('    - Prefer an object whose label or API name contains the keyword token(s).\n');
        parts.add('    - If there is a SINGLE clear match in the schema, use that object directly.\n');
        parts.add('    - If multiple objects plausibly match, choose the best semantic fit based on requested fields/date filters and include a second query for the next-best match only if needed to disambiguate.\n');
        parts.add('    - Never invent object names; only use objects present in the provided schema.\n');
        parts.add('13. CRITICAL: NEVER use OR with subqueries. If you need records matching EITHER condition, generate TWO separate queries.\n');
        parts.add('13b. CROSS-OBJECT NAME LOOKUPS: When querying Tasks, Events, Contacts, Opportunities, Cases, or ANY child records "at", "for", or "with" a specific account mentioned by name, ALWAYS use an AccountId subquery with LIKE instead of matching Account.Name directly. Account names often contain abbreviations, suffixes, or extra words (e.g., user says "Meridian Financial" but Account.Name is "Meridian Financial Services"). Direct Name = \'...\' matching WILL FAIL.\n');
        parts.add('    CORRECT: SELECT ... FROM Task WHERE AccountId IN (SELECT Id FROM Account WHERE Name LIKE \'%Meridian Financial%\') LIMIT 200\n');
        parts.add('    CORRECT: SELECT ... FROM Contact WHERE AccountId IN (SELECT Id FROM Account WHERE Name LIKE \'%PDC%\') LIMIT 200\n');
        parts.add('    WRONG:   SELECT ... FROM Task WHERE Account.Name = \'Meridian Financial\' LIMIT 200\n');
        parts.add('    WRONG:   SELECT ... FROM Contact WHERE Account.Name = \'Pacific Distribution Centers\' LIMIT 200\n');
        parts.add('    This pattern applies to ALL objects with AccountId: Task, Event, Contact, Opportunity, Case, etc. For objects without AccountId, use LIKE on the relationship: e.g., Account.Name LIKE \'%keyword%\'.\n');
        parts.add('14. ALWAYS PAIR detail queries with aggregate counts: for EVERY detail SELECT, also generate a matching COUNT() query with the same WHERE clause. Put the COUNT query FIRST. For grouped aggregates, a separate COUNT is not needed.\n');
    }

    // ─── Create/Update Rules (15-23) — CREATE, UPDATE, FOLLOWUP ─

    private static void appendCreateUpdateRules(List<String> parts, String userId) {
        parts.add('\n## RECORD CREATION & UPDATE RULES\n');
        parts.add('15. If the user wants to CREATE, ADD, LOG, or MAKE a new record (including log a call, log a task, schedule an event/meeting), do NOT generate queries. Output a create action JSON instead.\n');
        parts.add('15b. CRITICAL DISTINCTION — "draft/write/summarize/compose" vs "create/log a task": When the user (or conversation context) says "draft a summary", "write an email", "compose a message", "summarize findings", or agrees (e.g. "yes") to a suggestion involving drafting/writing/summarizing — this is a REQUEST TO GENERATE TEXT CONTENT, NOT a record creation. You must generate SOQL queries to fetch the relevant data so Pass 2 can compose the content. NEVER create a Task record for these requests. Only create Task/Event records when the user explicitly says "log a task", "create a task", "add a reminder", "schedule a meeting", etc.\n');
        parts.add('16. Record creation is supported for: Account, Contact, Case, Lead, Opportunity, Task, Event. "Log a call" = Task with TaskSubtype=Call. "Log a task" = Task. "Schedule a meeting/event" = Event.\n');
        parts.add('17. For a NEW create request where not enough info is provided: {"action":"create","objectApiName":"Task","fields":{"Subject":"value"}} — include any fields the user already mentioned.\n');
        parts.add('18. When the user provides enough info to create the record (contact name, account name, subject, etc.) OR confirms a pending create: output {"action":"create_execute",...} directly. For Task/Event creates, if the user mentions a contact or account BY NAME, put the NAME in WhoId/WhatId — the system will resolve it to an ID automatically. Example: {"action":"create_execute","objectApiName":"Task","fields":{"Subject":"Call: Public Works Discussion","TaskSubtype":"Call","Status":"Completed","ActivityDate":"' + String.valueOf(Date.today()) + '","WhoId":"David Kim","WhatId":"City of Irvine"}}.\n');
        parts.add('19. Account creatable fields: Name (required), Industry (picklist), Type (picklist: Prospect|Customer - Direct|Customer - Channel|Channel Partner / Reseller|Technology Partner|Other), Phone, Website, BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry, Description, NumberOfEmployees (integer), AnnualRevenue (currency number only, no $ sign).\n');
        parts.add('19b. Task creatable fields: Subject (required), Status (default "Completed" for logged calls/tasks, "Not Started" for future tasks), Priority (High|Normal|Low, default Normal), ActivityDate (date YYYY-MM-DD, default today for logged calls), Description, WhoId (Contact/Lead NAME or ID), WhatId (Account/Opportunity NAME or ID), TaskSubtype (set to "Call" for calls, "Task" for tasks, "Email" for emails). For logging calls/tasks, ALWAYS set Status="Completed" and ActivityDate to today. For future tasks, set Status="Not Started".\n');
        parts.add('19c. Event creatable fields: Subject (required), StartDateTime (ISO 8601), EndDateTime (ISO 8601), Location, Description, WhoId (Contact/Lead NAME or ID), WhatId (Account/Opportunity NAME or ID). Default meeting duration is 30 minutes if not specified.\n');
        parts.add('19d. CRITICAL: When the user says "log a call/task" or "schedule a meeting" and provides enough context (who, what account), output "create_execute" IMMEDIATELY — do NOT generate lookup queries. Put contact/account NAMES directly in WhoId/WhatId fields. The system resolves names to IDs automatically. Only use "create" (without _execute) if the user hasn\'t provided a subject or you need to ask what the call/meeting was about.\n');
        parts.add('19e. NEVER interpret "draft", "write", "compose", "summarize", or "prepare" as record creation. These are content generation requests. When a user says "yes" to "Should I draft a summary..." or "Want me to write an email...", query the relevant data (activities, cases, contacts for the mentioned person/account) and let the analysis pass compose the content.\n');
        parts.add('19f. Contact creatable fields: LastName (required), FirstName, AccountId (company NAME — system resolves to ID automatically), Email, Phone, MobilePhone, Title, Department, MailingCity, MailingState, MailingCountry, Description, LeadSource. Parse names naturally — "Stanley Stevens" → FirstName:"Stanley" LastName:"Stevens", "Mary Jane Watson" → FirstName:"Mary Jane" LastName:"Watson". Never duplicate the full name in both fields.\n');
        parts.add('19g. Case creatable fields: Subject (required), Status (default "New"), Priority (default "Medium"; use High|Medium|Low), Origin (Phone|Email|Web), Type, Description, AccountId (company NAME — system resolves to ID), ContactId (contact NAME — system resolves to ID). Include enough info to output create_execute directly when Subject is known.\n');
        parts.add('19h. Lead creatable fields: LastName (required), Company (required), FirstName, Email, Phone, MobilePhone, Title, Industry, Status (default "Open - Not Contacted"), LeadSource, Description, City, State, Country. Same name parsing rule as 19f.\n');
        parts.add('19i. Opportunity creatable fields: Name (required), StageName (required — use a valid stage from the schema below), CloseDate (required — YYYY-MM-DD), AccountId (account NAME — system resolves to ID), Amount (numeric only, no $ sign), Probability (0-100), NextStep, Description, Type, LeadSource.\n');
        parts.add('22. PENDING RECORD UPDATE — When the conversation history contains a line "[SYSTEM: Pending record update — Object: X, Record ID: xxx, Record Name: Y, Available blank fields: F1, F2, ...]" and the user\'s current message provides values for one or more of those fields, output: {"action":"update_execute","recordId":"xxx","objectApiName":"X","fields":{"FieldApiName":"value"}}. Use only field API names (e.g. Phone, Website, Amount). Include ONLY the fields the user actually mentioned. If the user declines (says "no", "skip", "looks good", "that\'s fine", "not now", or otherwise passes), output: {"action":"update_cancel"}.\n');
        parts.add('23. MULTIPLE RECORD CREATES IN ONE MESSAGE — When the user asks to create MORE THAN ONE record in a single message (e.g. "create an account called Acme AND a contact on it for Jane Smith"), output a multi-action JSON: {"actions":[{"action":"create_execute","objectApiName":"Account","fields":{...}},{"action":"create_execute","objectApiName":"Contact","fields":{"AccountId":"Acme",...}}]}. Rules: (a) Always order parent records first (Account before Contact/Case/Opportunity). (b) In the child record\'s reference field, put the PARENT\'S NAME (not ID) — the system creates the parent first and the name-to-ID lookup will find it automatically. (c) Use this format whenever the user mentions AND, ALSO, PLUS, or multiple objects being created. (d) If one of the creates needs more info, use "create" instead of "create_execute" for that step only.\n');
    }

    // ─── Compose/Draft Rules (15b, 15c, 19e) — COMPOSE ──────────

    private static void appendComposeRules(List<String> parts, String userId) {
        parts.add('\n## CONTENT COMPOSITION RULES\n');
        parts.add('15b. CRITICAL: "draft/write/summarize/compose" is a REQUEST TO GENERATE TEXT CONTENT, NOT a record creation. Generate SOQL queries to fetch the relevant data so the analysis pass can compose the content.\n');
        parts.add('15c. EMAIL RECIPIENT LOOKUP — When the user asks to draft an email to a "decision maker", "key contact", "executive", "CEO", or similar at an account, you MUST generate these THREE queries in order:\n');
        parts.add('    (1) PRIORITY — OpportunityContactRole on recent opportunities for the account: SELECT Id, Role, IsPrimary, Contact.Name, Contact.Email, Contact.Title, Opportunity.Name FROM OpportunityContactRole WHERE OpportunityId IN (SELECT Id FROM Opportunity WHERE AccountId IN (SELECT Id FROM Account WHERE Name LIKE \'%keyword%\') AND IsClosed = false ORDER BY CreatedDate DESC LIMIT 10) ORDER BY IsPrimary DESC LIMIT 50\n');
        parts.add('    This identifies contacts who are actual Decision Makers, Economic Buyers, Champions, or Executive Sponsors on open deals.\n');
        parts.add('    (2) C-suite/executive contacts on the account: SELECT Id, Name, Title, Email FROM Contact WHERE AccountId IN (SELECT Id FROM Account WHERE Name LIKE \'%keyword%\') AND Title != null ORDER BY Title LIMIT 50\n');
        parts.add('    (3) Fallback all contacts: SELECT Id, Name, Title, Email FROM Contact WHERE AccountId IN (SELECT Id FROM Account WHERE Name LIKE \'%keyword%\') ORDER BY LastModifiedDate DESC LIMIT 20\n');
        parts.add('    Pass 2 will select the best recipient from these results.\n');
        parts.add('19e. NEVER interpret "draft", "write", "compose", "summarize", or "prepare" as record creation. These are content generation requests that require data queries.\n');
    }

    // ─── Complex Query Patterns (20-21) — QUERY, COMPARE, COMPOSE

    private static void appendComplexQueryRules(List<String> parts, String userId) {
        parts.add('\n## COMPLEX QUERY PATTERNS\n');
        parts.add('20. MEETINGS/EVENTS → ACCOUNTS → CASES PATTERN: When the question involves meetings/events AND their related Accounts or Cases, you MUST generate separate Account and Case queries using SOQL subquery joins via Event.WhatId. SOQL supports this pattern:\n');
        parts.add('    - Accounts from meetings: SELECT Id, Name, Industry, Type, Phone FROM Account WHERE Id IN (SELECT WhatId FROM Event WHERE OwnerId = \'' + userId + '\' AND ActivityDate = THIS_WEEK) LIMIT 200\n');
        parts.add('    - Cases for meeting accounts: SELECT Id, CaseNumber, Subject, Status, Priority, AccountId FROM Case WHERE AccountId IN (SELECT WhatId FROM Event WHERE OwnerId = \'' + userId + '\' AND ActivityDate = THIS_WEEK) AND IsClosed = false ORDER BY CreatedDate DESC LIMIT 200\n');
        parts.add('    - For high-priority cases: add AND Priority = \'High\' to the Case WHERE clause.\n');
        parts.add('    - ALWAYS generate all three queries (Event, Account, Case) when the question asks about meetings + accounts + cases.\n');
        parts.add('21. CONTACT ROLES ON OPPORTUNITIES — When the user asks about decision makers, contact roles, stakeholders, or contacts on opportunities, you MUST generate an OpportunityContactRole query in addition to any Opportunity query. Example: SELECT Id, OpportunityId, ContactId, Role, IsPrimary, Contact.Name, Contact.Email, Opportunity.Name, Opportunity.Amount FROM OpportunityContactRole WHERE OpportunityId IN (SELECT Id FROM Opportunity WHERE OwnerId = \'' + userId + '\' AND Amount > 100000 AND IsClosed = false) [AND Role = \'Decision Maker\' when user asks for decision makers] LIMIT 200. Include the matching COUNT query. For activity with contacts (e.g., "had any activity with them in the last 30 days"), also query Task and Event WHERE WhoId IN (SELECT ContactId FROM OpportunityContactRole WHERE OpportunityId IN (...)).\n');
    }

    // ─── Data Cloud Rules (24) — Credit/Usage Queries ────────────

    private static void appendDataCloudRules(List<String> parts) {
        parts.add('\n## DATA CLOUD RULES\n');
        parts.add('24. DATA CLOUD / CREDIT USAGE QUERIES — When the user asks about "consumption", "credit usage", "credits", "data quality monitoring", "monitor runs", or similar, generate one Account lookup query PER company mentioned. Always include External_Account_ID__c in the SELECT. Do NOT query Data Lake Objects directly — the system auto-enriches results with Data Cloud data.\n');
        parts.add('    SINGLE ACCOUNT example ("Summit Commerce Group\'s consumption"): {"queries":[{"purpose":"Account lookup for Data Cloud enrichment","soql":"SELECT Id, Name, External_Account_ID__c, Industry, Type FROM Account WHERE Name LIKE \'%Summit%\' LIMIT 5"}]}\n');
        parts.add('    COMPARISON example ("Compare Meridian Financial Services\' consumption to Summit Commerce Group"): {"queries":[{"purpose":"Account lookup — Meridian","soql":"SELECT Id, Name, External_Account_ID__c, Industry, Type FROM Account WHERE Name LIKE \'%Meridian%\' LIMIT 5"},{"purpose":"Account lookup — Summit","soql":"SELECT Id, Name, External_Account_ID__c, Industry, Type FROM Account WHERE Name LIKE \'%Summit%\' LIMIT 5"}]}\n');
    }

    // ─── Running User Context ────────────────────────────────────

    private static void appendRunningUserContext(List<String> parts, String userId, String userName) {
        parts.add('\n## RUNNING USER CONTEXT\n');
        parts.add('- User ID: ' + userId + '\n');
        parts.add('- User Name: ' + userName + '\n');
        parts.add('- When the user says "my", "mine", or "I", filter by OwnerId = \'' + userId + '\'\n\n');
    }

    // ─── Few-Shot Examples (R6) ──────────────────────────────────

    private static void appendFewShotExamples(List<String> parts, String intentType, String userId) {
        parts.add('## EXAMPLES\n');
        parts.add('These show the exact output format for common patterns:\n\n');

        parts.add('Example 1 — Multi-object with date filter:\n');
        parts.add('User: "Accounts with open cases that also have deals closing this month"\n');
        parts.add('Output: {"queries":[{"purpose":"Count of accounts with open cases","soql":"SELECT COUNT() FROM Account WHERE Id IN (SELECT AccountId FROM Case WHERE IsClosed = false)"},{"purpose":"Accounts with open cases","soql":"SELECT Id, Name, Industry, Type FROM Account WHERE Id IN (SELECT AccountId FROM Case WHERE IsClosed = false) LIMIT 200"},{"purpose":"Deals closing this month","soql":"SELECT Id, Name, Amount, CloseDate, StageName, Account.Name FROM Opportunity WHERE CloseDate = THIS_MONTH AND IsClosed = false LIMIT 200"}]}\n\n');

        parts.add('Example 2 — Aggregation (avoid GROUP BY on non-groupable fields):\n');
        parts.add('User: "Top 10 accounts by opportunity amount"\n');
        parts.add('Output: {"queries":[{"purpose":"Accounts ranked by pipeline","soql":"SELECT AccountId, Account.Name, SUM(Amount) totalAmt FROM Opportunity WHERE IsClosed = false GROUP BY AccountId, Account.Name ORDER BY SUM(Amount) DESC LIMIT 10"}]}\n\n');

        parts.add('Example 3 — Activity analysis (never GROUP BY Subject):\n');
        parts.add('User: "Break down my recent activities by type"\n');
        parts.add('Output: {"queries":[{"purpose":"Task breakdown by type","soql":"SELECT TaskSubtype, Status, COUNT(Id) total FROM Task WHERE OwnerId = \'' + userId + '\' AND CreatedDate = LAST_N_DAYS:30 GROUP BY TaskSubtype, Status ORDER BY COUNT(Id) DESC LIMIT 200"},{"purpose":"Recent events","soql":"SELECT Subject, ActivityDate, Type FROM Event WHERE OwnerId = \'' + userId + '\' AND ActivityDate = LAST_N_DAYS:30 ORDER BY ActivityDate DESC LIMIT 200"}]}\n\n');

        parts.add('Example 4 — Fuzzy account name matching:\n');
        parts.add('User: "Show me contacts at Acme"\n');
        parts.add('Output: {"queries":[{"purpose":"Count of contacts at Acme","soql":"SELECT COUNT() FROM Contact WHERE AccountId IN (SELECT Id FROM Account WHERE Name LIKE \'%Acme%\')"},{"purpose":"Contacts at Acme","soql":"SELECT Id, Name, Title, Email, Phone FROM Contact WHERE AccountId IN (SELECT Id FROM Account WHERE Name LIKE \'%Acme%\') ORDER BY LastModifiedDate DESC LIMIT 200"}]}\n\n');

        parts.add('Example 5 — Activity summary for an account (fuzzy name + Tasks + Events):\n');
        parts.add('User: "Write a summary of all recent activity with Meridian Financial"\n');
        parts.add('Output: {"queries":[{"purpose":"Account lookup","soql":"SELECT Id, Name, OwnerId, Owner.Name, Industry, Type FROM Account WHERE Name LIKE \'%Meridian Financial%\' LIMIT 5"},{"purpose":"Count of recent tasks","soql":"SELECT COUNT() FROM Task WHERE AccountId IN (SELECT Id FROM Account WHERE Name LIKE \'%Meridian Financial%\') AND CreatedDate = LAST_N_DAYS:90"},{"purpose":"Recent tasks","soql":"SELECT Id, Subject, Status, TaskSubtype, ActivityDate, CreatedDate, Who.Name, Owner.Name FROM Task WHERE AccountId IN (SELECT Id FROM Account WHERE Name LIKE \'%Meridian Financial%\') AND CreatedDate = LAST_N_DAYS:90 ORDER BY CreatedDate DESC LIMIT 200"},{"purpose":"Count of recent events","soql":"SELECT COUNT() FROM Event WHERE AccountId IN (SELECT Id FROM Account WHERE Name LIKE \'%Meridian Financial%\') AND CreatedDate = LAST_N_DAYS:90"},{"purpose":"Recent events","soql":"SELECT Id, Subject, ActivityDate, StartDateTime, EndDateTime, Type, Who.Name, Owner.Name FROM Event WHERE AccountId IN (SELECT Id FROM Account WHERE Name LIKE \'%Meridian Financial%\') AND CreatedDate = LAST_N_DAYS:90 ORDER BY StartDateTime DESC LIMIT 200"}]}\n');
        parts.add('NOTE: ALWAYS use LIKE \'%partial name%\' in a subquery for AccountId when the user mentions an account by name. The user may say "Meridian Financial" but the actual Account name is "Meridian Financial Services". Direct Name = \'...\' will fail.\n\n');

        if (shouldIncludeCreateRules(intentType)) {
            parts.add('Example 6 — Log a call (create action):\n');
            parts.add('User: "Log a call with Sarah about the renewal"\n');
            parts.add('Output: {"action":"create_execute","objectApiName":"Task","fields":{"Subject":"Call: Renewal Discussion","TaskSubtype":"Call","Status":"Completed","ActivityDate":"' + String.valueOf(Date.today()) + '","WhoId":"Sarah"}}\n\n');
        }
    }

    // ─── Output Format ───────────────────────────────────────────

    private static void appendOutputFormat(List<String> parts, String intentType, String userId) {
        parts.add('## OUTPUT FORMAT\n');
        parts.add('Return ONLY a JSON object with no additional text, no markdown code blocks, no explanation.\n');
        parts.add('For data queries: {"queries":[{"purpose":"Brief description","soql":"SELECT ... OR FIND {...} RETURNING ..."}]}\n');

        if (shouldIncludeCreateRules(intentType)) {
            parts.add('For new create request: {"action":"create","objectApiName":"Account","fields":{"Name":"value"}}\n');
            parts.add('For log a call (enough context): {"action":"create_execute","objectApiName":"Task","fields":{"Subject":"Call: Topic","TaskSubtype":"Call","Status":"Completed","ActivityDate":"' + String.valueOf(Date.today()) + '","WhoId":"Contact Name","WhatId":"Account Name"}}\n');
            parts.add('For log a call (need more info): {"action":"create","objectApiName":"Task","fields":{"Subject":"Call with Name","TaskSubtype":"Call"}}\n');
            parts.add('For schedule event: {"action":"create_execute","objectApiName":"Event","fields":{"Subject":"Meeting","WhoId":"Name","WhatId":"Account","StartDateTime":"2026-03-17T10:00:00","EndDateTime":"2026-03-17T10:30:00"}}\n');
            parts.add('For create contact: {"action":"create_execute","objectApiName":"Contact","fields":{"FirstName":"Jane","LastName":"Smith","AccountId":"Acme Corp","Email":"jane@acme.com","Title":"VP Sales"}}\n');
            parts.add('For create case: {"action":"create_execute","objectApiName":"Case","fields":{"Subject":"Issue","Status":"New","Priority":"High","Origin":"Email","AccountId":"Acme Corp"}}\n');
            parts.add('For create lead: {"action":"create_execute","objectApiName":"Lead","fields":{"FirstName":"Bob","LastName":"Jones","Company":"StartupCo","Email":"bob@startup.co","Title":"CEO"}}\n');
            parts.add('For create opportunity: {"action":"create_execute","objectApiName":"Opportunity","fields":{"Name":"Deal Name","StageName":"Qualification","CloseDate":"2026-06-30","AccountId":"Company","Amount":50000}}\n');
            parts.add('For updating fields on a pending record: {"action":"update_execute","recordId":"001Hu0000XXXXX","objectApiName":"Account","fields":{"Phone":"555-1234","Website":"https://www.example.com"}}\n');
            parts.add('For declining a pending field update: {"action":"update_cancel"}\n');
            parts.add('For creating MULTIPLE records: {"actions":[{"action":"create_execute","objectApiName":"Account","fields":{"Name":"Company"}},{"action":"create_execute","objectApiName":"Contact","fields":{"FirstName":"Jane","LastName":"Smith","AccountId":"Company"}}]}\n');
        }

        parts.add('Use SOQL (SELECT) for most queries. Use SOSL (FIND) only for Incident/Problem/Case when you need to search Description (long text).\n');
    }

    // ─── Pass 2 Prompt ────────────────────────────────────────

    /** Build analysis prompt from pre-formatted execution data. */
    public static String buildAnalysisPromptFromData(AgentforceWorkspaceModels.ExecutionData data,
                                                      String userMessage, String conversationHistory) {
        List<String> parts = new List<String>();

        parts.add('You are a senior business analyst working inside a Salesforce CRM that is integrated with Salesforce Data 360 (Data Cloud). ');
        parts.add('A Sales and Marketing professional named ' + data.userName + ' asked a business intelligence question. ');
        parts.add('You have access to query results below from BOTH the Salesforce CRM and Salesforce Data 360. Provide a rich, insightful analysis.\n\n');
        parts.add('**DATA SOURCES:**\n');
        parts.add('- CRM data: standard Salesforce objects (Account, Opportunity, Contact, etc.)\n');
        parts.add('- Data 360 data: labeled "DATA CLOUD — Credit Usage", sourced from the **Daily_Credit_Usage__dll** Data Lake Object (DLO) in Salesforce Data 360.\n');
        parts.add('When both sources are present, synthesize them into a unified answer.\n');
        parts.add('**DATA SOURCE ATTRIBUTION RULE:** Whenever you include Data 360 / Data Cloud data in your response, you MUST cite the source exactly once in a small note. Use this exact format as the last line before your CHART block: <p><em>Data 360 source: <code>Daily_Credit_Usage__dll</code> (Data Lake Object)</em></p>. Do not repeat this citation multiple times.\n\n');

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
        parts.add('**CRITICAL — HTML ONLY. ZERO MARKDOWN.**\n');
        parts.add('Your response MUST be valid HTML. The rendering surface is an HTML viewer — markdown will appear as raw characters.\n');
        parts.add('- NEVER use # or ## or ### for headings. Use <h1>, <h2>, <h3> tags instead.\n');
        parts.add('- NEVER use **text** or *text* for emphasis. Use <b> or <em> tags.\n');
        parts.add('- NEVER use ``` code fences. Use <code> or <pre> tags.\n');
        parts.add('- NEVER use - or * for bullet lists. Use <ul><li> tags.\n');
        parts.add('- NEVER use numbered lists with "1. 2. 3." notation. Use <ol><li> tags.\n');
        parts.add('- Every section header MUST be an HTML tag like <h2> or <h3>.\n\n');

        parts.add('**VOICE & TONE:**\n');
        parts.add('- You are a helpful business analyst talking to a colleague. Be warm, direct, and insightful.\n');
        parts.add('- Address the user by first name (' + data.userName + ').\n');
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
        parts.add('- **PREFER <table> for comparisons and grouped data.** When the data has 3+ items with shared dimensions (e.g., stages, types, reps, time periods), present it as a clean HTML table with <thead> and <tbody>. Tables are far easier to scan than bullet lists for numeric comparisons. Use <b> on standout values (highest, lowest, growth %). Example: stage breakdown, rep leaderboard, monthly trend, type comparison.\n');
        String fullName = String.isNotBlank(data.userFullName) ? data.userFullName : data.userName;
        parts.add('- **EMAIL DRAFTS — RECIPIENT SELECTION:** When drafting an email, ALWAYS select a real contact from the QUERY RESULTS. Follow this strict priority order:\n');
        parts.add('  (1) FIRST CHOICE — Contact with Role = "Decision Maker" in OpportunityContactRole on a recent open opportunity for this account\n');
        parts.add('  (2) Contact with Role = "Economic Buyer", "Champion", or "Executive Sponsor" in OpportunityContactRole on a recent open opportunity\n');
        parts.add('  (3) Any other contact in OpportunityContactRole on a recent opportunity — prefer IsPrimary = true if multiple exist\n');
        parts.add('  (4) CEO, President, or Chief * Officer (C-suite title) from the account contacts\n');
        parts.add('  (5) VP, Vice President, SVP, EVP\n');
        parts.add('  (6) Director, Managing Director\n');
        parts.add('  (7) Manager, Head of, Lead\n');
        parts.add('  (8) Any contact with a non-blank Email field\n');
        parts.add('  (9) If NO contacts exist in the data at all, use the account name with a placeholder email and explain in the intro that no contacts were found.\n');
        parts.add('  RULES: NEVER invent a name like "Decision Maker" or "Key Contact". Use the EXACT Name and Email from the query results. If the chosen contact has no Email, write their name but note the email is missing. If you picked someone who is NOT obviously a decision maker, add one sentence in your intro explaining why (e.g. "I couldn\'t find a decision maker on record, so I\'ve addressed this to [Name], [Title], who is the most senior contact on record.").\n');
        parts.add('- **EMAIL DRAFT FORMAT:** Include the full email directly in your HTML response inside a <blockquote> element. Add a brief intro sentence (including any recipient-selection explanation), then output: <blockquote><p><b>To:</b> [Real Name from data] &lt;[real.email@company.com from data]&gt;</p><p><b>Subject:</b> Subject Line</p><p>Hi [First name],</p><p>[Body paragraph]</p><p>Best regards,<br>' + fullName + '</p></blockquote>. Sign with ' + fullName + '. NEVER use "[Your Name]". Skip the CHART block for email drafts. Still include SUGGESTIONS.\n');

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

        parts.add('\n\n## CHART VISUALIZATION — MANDATORY WHEN DATA HAS NUMBERS\n');
        parts.add('When your analysis includes a table or list with numeric data (amounts, counts, percentages, rankings), you MUST output a CHART block AFTER your HTML and BEFORE the SUGGESTIONS block. The UI renders this as an interactive chart below the chat.\n');
        parts.add('Format: <CHART>{"chartType":"bar|horizontalBar|donut","title":"Short Chart Title","valueLabel":"Amount","valuePrefix":"$","valueSuffix":"","items":[{"label":"Category","value":1234},{"label":"Other","value":567}]}</CHART>\n');
        parts.add('Chart type selection:\n');
        parts.add('- "horizontalBar" — DEFAULT CHOICE for ranked data, leaderboards, account comparisons, or any list with long labels. This is the most common and readable chart type.\n');
        parts.add('- "bar" — Use for time series, monthly/quarterly trends, or when labels are short (stage names, months).\n');
        parts.add('- "donut" — Use for part-of-whole breakdowns where percentages are the focus (pipeline by stage %, distribution by type).\n');
        parts.add('Rules:\n');
        parts.add('- Pick the SINGLE most impactful dataset from your analysis. Usually the data you put in a <table>.\n');
        parts.add('- Keep to 3-10 items. Combine smaller items into "Other" if needed.\n');
        parts.add('- Use raw numeric values (not formatted strings). valuePrefix "$" for currency, valueSuffix "%" for percentages.\n');
        parts.add('- Do NOT include a "color" property on items.\n');
        parts.add('- ONLY skip the CHART block for: single-record lookups, text-only results (emails, summaries with no numbers), or when no numeric comparison exists.\n\n');

        parts.add('AFTER your HTML and CHART blocks, you MUST output this block on its own line:\n');
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
        parts.add('- ALWAYS include the <CHART> block when your analysis has numeric/comparative data (tables, rankings, amounts).\n');
        parts.add('- ALWAYS include the <SUGGESTIONS> block at the very end — this is required.\n');

        return String.join(parts, '');
    }

    // ─── Models API ───────────────────────────────────────────

    public static String callModelsAPI(String promptText, String modelName) {
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

    // ─── Suggestion Parser ────────────────────────────────────

    /**
     * Safety net: converts any markdown headers/bold that sneak through into proper HTML.
     * Applied before any other parsing so the rendered output is always clean HTML.
     */
    @TestVisible
    private static String convertMarkdownToHtml(String text) {
        if (String.isBlank(text)) return text;
        List<String> lines = text.split('\n');
        List<String> out   = new List<String>();
        for (String line : lines) {
            if (line.startsWith('### ')) {
                out.add('<h3>' + line.removeStart('### ').trim() + '</h3>');
            } else if (line.startsWith('## ')) {
                out.add('<h2>' + line.removeStart('## ').trim() + '</h2>');
            } else if (line.startsWith('# ')) {
                out.add('<h1>' + line.removeStart('# ').trim() + '</h1>');
            } else {
                out.add(line);
            }
        }
        return String.join(out, '\n');
    }

    public static AgentforceWorkspaceModels.ChatResult parseSuggestions(String raw) {
        AgentforceWorkspaceModels.ChatResult result = new AgentforceWorkspaceModels.ChatResult();
        if (String.isBlank(raw)) {
            result.response = '';
            return result;
        }

        // Safety net: convert any markdown headers the model may have emitted despite instructions
        raw = convertMarkdownToHtml(raw);

        // Extract <CHART> block (before SUGGESTIONS)
        Integer chartOpen  = raw.indexOf('<CHART>');
        Integer chartClose = raw.indexOf('</CHART>');
        if (chartOpen != -1 && chartClose != -1 && chartClose > chartOpen) {
            String chartJson = raw.substring(chartOpen + 7, chartClose).trim();
            // Remove the CHART block from raw so it doesn't end up in the response
            raw = raw.substring(0, chartOpen) + raw.substring(chartClose + 8);
            try {
                Map<String, Object> chartMap = (Map<String, Object>) JSON.deserializeUntyped(chartJson);
                AgentforceWorkspaceModels.ChartData cd = new AgentforceWorkspaceModels.ChartData();
                cd.chartType   = (String) chartMap.get('chartType');
                cd.title       = (String) chartMap.get('title');
                cd.valueLabel  = (String) chartMap.get('valueLabel');
                cd.valuePrefix = (String) chartMap.get('valuePrefix');
                cd.valueSuffix = (String) chartMap.get('valueSuffix');
                if (chartMap.containsKey('items')) {
                    for (Object itemObj : (List<Object>) chartMap.get('items')) {
                        Map<String, Object> im = (Map<String, Object>) itemObj;
                        AgentforceWorkspaceModels.ChartItem ci = new AgentforceWorkspaceModels.ChartItem();
                        ci.label = (String) im.get('label');
                        ci.value = im.get('value') != null ? Decimal.valueOf(String.valueOf(im.get('value'))) : 0;
                        ci.color = (String) im.get('color');
                        cd.items.add(ci);
                    }
                }
                if (!cd.items.isEmpty()) {
                    result.chartData = cd;
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'Failed to parse chart data: ' + e.getMessage());
            }
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

    /** Convert plain text email body (with \n) to HTML paragraphs. */
    private static String convertPlainTextBodyToHtml(String body) {
        if (String.isBlank(body)) return '';
        if (body.contains('<p>') || body.contains('<br')) return body;
        List<String> paragraphs = body.split('\\n\\n');
        String html = '';
        for (String p : paragraphs) {
            String trimmed = p.trim();
            if (String.isNotBlank(trimmed)) {
                html += '<p>' + trimmed.replace('\n', '<br/>') + '</p>';
            }
        }
        return String.isNotBlank(html) ? html : '<p>' + body + '</p>';
    }
}
