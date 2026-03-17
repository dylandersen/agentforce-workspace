/**
 * Prompt construction, Models API calls, and response parsing
 * for the Agentforce Workspace feature.
 */
public with sharing class AgentforceWorkspaceAnalysisService {

    public static final String DEFAULT_MODEL = 'sfdc_ai__DefaultVertexAIGemini30Flash';

    // ─── Pass 1 Prompt ────────────────────────────────────────

    public static String buildNLtoSOQLPrompt(String userMessage, String conversationHistory,
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
        parts.add('   IMPORTANT: Never GROUP BY long text or non-groupable fields (Subject, Description, Body, Comment, MessageBody, etc.). For activity analysis, GROUP BY ActivityType, Status, or TaskSubtype instead. Use ORDER BY for sorting by text fields.\n');
        parts.add('8. For questions requiring data from multiple objects, generate multiple queries.\n');
        parts.add('9. Always include relevant fields that help answer the question.\n');
        parts.add('10. Prefer ORDER BY on relevant fields (e.g., CloseDate, Amount, CreatedDate).\n');
        parts.add('11. Do NOT use SOQL reserved words as aliases.\n');
        parts.add('12. For Opportunity stages use the exact stage names from the schema.\n');
        parts.add('13. CRITICAL: NEVER use OR with subqueries. If you need records matching EITHER condition, generate TWO separate queries.\n');
        parts.add('14. ALWAYS PAIR detail queries with aggregate counts: for EVERY detail SELECT, also generate a matching COUNT() query with the same WHERE clause. Put the COUNT query FIRST. For grouped aggregates, a separate COUNT is not needed.\n');
        parts.add('15. If the user wants to CREATE, ADD, LOG, or MAKE a new record (including log a call, log a task, schedule an event/meeting), do NOT generate queries. Output a create action JSON instead.\n');
        parts.add('16. Record creation is supported for: Account, Task, Event. "Log a call" = Task with TaskSubtype=Call. "Log a task" = Task. "Schedule a meeting/event" = Event.\n');
        parts.add('17. For a NEW create request where not enough info is provided: {"action":"create","objectApiName":"Task","fields":{"Subject":"value"}} — include any fields the user already mentioned.\n');
        parts.add('18. When the user provides enough info to create the record (contact name, account name, subject, etc.) OR confirms a pending create: output {"action":"create_execute",...} directly. For Task/Event creates, if the user mentions a contact or account BY NAME, put the NAME in WhoId/WhatId — the system will resolve it to an ID automatically. Example: {"action":"create_execute","objectApiName":"Task","fields":{"Subject":"Call: Public Works Discussion","TaskSubtype":"Call","Status":"Completed","ActivityDate":"2026-03-16","WhoId":"David Kim","WhatId":"City of Irvine"}}.\n');
        parts.add('19. Account creatable fields: Name (required), Industry (picklist), Type (picklist: Prospect|Customer - Direct|Customer - Channel|Channel Partner / Reseller|Technology Partner|Other), Phone, Website, BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry, Description, NumberOfEmployees (integer), AnnualRevenue (currency number only, no $ sign).\n');
        parts.add('19b. Task creatable fields: Subject (required), Status (default "Completed" for logged calls/tasks, "Not Started" for future tasks), Priority (High|Normal|Low, default Normal), ActivityDate (date YYYY-MM-DD, default today for logged calls), Description, WhoId (Contact/Lead NAME or ID), WhatId (Account/Opportunity NAME or ID), TaskSubtype (set to "Call" for calls, "Task" for tasks, "Email" for emails). For logging calls/tasks, ALWAYS set Status="Completed" and ActivityDate to today. For future tasks, set Status="Not Started".\n');
        parts.add('19c. Event creatable fields: Subject (required), StartDateTime (ISO 8601), EndDateTime (ISO 8601), Location, Description, WhoId (Contact/Lead NAME or ID), WhatId (Account/Opportunity NAME or ID). Default meeting duration is 30 minutes if not specified.\n');
        parts.add('19d. CRITICAL: When the user says "log a call/task" or "schedule a meeting" and provides enough context (who, what account), output "create_execute" IMMEDIATELY — do NOT generate lookup queries. Put contact/account NAMES directly in WhoId/WhatId fields. The system resolves names to IDs automatically. Only use "create" (without _execute) if the user hasn\'t provided a subject or you need to ask what the call/meeting was about.\n');
        parts.add('20. MEETINGS/EVENTS → ACCOUNTS → CASES PATTERN: When the question involves meetings/events AND their related Accounts or Cases, you MUST generate separate Account and Case queries using SOQL subquery joins via Event.WhatId. SOQL supports this pattern:\n');
        parts.add('    - Accounts from meetings: SELECT Id, Name, Industry, Type, Phone FROM Account WHERE Id IN (SELECT WhatId FROM Event WHERE OwnerId = \'' + userId + '\' AND ActivityDate = THIS_WEEK) LIMIT 200\n');
        parts.add('    - Cases for meeting accounts: SELECT Id, CaseNumber, Subject, Status, Priority, AccountId FROM Case WHERE AccountId IN (SELECT WhatId FROM Event WHERE OwnerId = \'' + userId + '\' AND ActivityDate = THIS_WEEK) AND IsClosed = false ORDER BY CreatedDate DESC LIMIT 200\n');
        parts.add('    - For high-priority cases: add AND Priority = \'High\' to the Case WHERE clause.\n');
        parts.add('    - ALWAYS generate all three queries (Event, Account, Case) when the question asks about meetings + accounts + cases.\n');
        parts.add('21. CONTACT ROLES ON OPPORTUNITIES — When the user asks about decision makers, contact roles, stakeholders, or contacts on opportunities, you MUST generate an OpportunityContactRole query in addition to any Opportunity query. Example: SELECT Id, OpportunityId, ContactId, Role, IsPrimary, Contact.Name, Contact.Email, Opportunity.Name, Opportunity.Amount FROM OpportunityContactRole WHERE OpportunityId IN (SELECT Id FROM Opportunity WHERE OwnerId = \'' + userId + '\' AND Amount > 100000 AND IsClosed = false) [AND Role = \'Decision Maker\' when user asks for decision makers] LIMIT 200. Include the matching COUNT query. For activity with contacts (e.g., "had any activity with them in the last 30 days"), also query Task and Event WHERE WhoId IN (SELECT ContactId FROM OpportunityContactRole WHERE OpportunityId IN (...)).\n\n');

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
        parts.add('For log a call (enough context): {"action":"create_execute","objectApiName":"Task","fields":{"Subject":"Call: Public Works Discussion","TaskSubtype":"Call","Status":"Completed","ActivityDate":"' + String.valueOf(Date.today()) + '","WhoId":"David Kim","WhatId":"City of Irvine"}}\n');
        parts.add('For log a call (need more info): {"action":"create","objectApiName":"Task","fields":{"Subject":"Call with David Kim","TaskSubtype":"Call"}}\n');
        parts.add('For schedule event: {"action":"create_execute","objectApiName":"Event","fields":{"Subject":"Meeting with David Kim","WhoId":"David Kim","WhatId":"City of Irvine","StartDateTime":"2026-03-17T10:00:00","EndDateTime":"2026-03-17T10:30:00"}}\n');
        parts.add('Use SOQL (SELECT) for most queries. Use SOSL (FIND) only for Incident/Problem/Case when you need to search Description (long text).\n');

        return String.join(parts, '');
    }

    // ─── Pass 2 Prompt ────────────────────────────────────────

    /** Build analysis prompt from pre-formatted execution data. */
    public static String buildAnalysisPromptFromData(AgentforceWorkspaceModels.ExecutionData data,
                                                      String userMessage, String conversationHistory) {
        List<String> parts = new List<String>();

        parts.add('You are a senior business analyst working inside a Salesforce CRM. ');
        parts.add('A Sales and Marketing professional named ' + data.userName + ' asked a business intelligence question. ');
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
        parts.add('- **DRAFTED EMAILS:** When the user asks to draft an email, (1) add <p></p> before and after the email block to create extra line breaks and visual separation from surrounding content, (2) wrap the entire email in <blockquote>, and (3) use proper paragraphing: separate To, Subject, salutation, each body paragraph, and sign-off into their own <p> tags. (4) ALWAYS sign the email with the running user\'s full name: ' + fullName + '. NEVER use "[Your Name]" — always use ' + fullName + '. Example: <p></p><blockquote><p><b>To:</b> Catherine Powell, CEO</p><p><b>Subject:</b> Next Steps</p><p>Hi Catherine,</p><p>Thank you for the conversation...</p><p>Would you have 30 minutes this week?</p><p>Best,</p><p>' + fullName + '</p></blockquote><p></p>. Never run the entire email as one continuous block — use <p></p> between each logical paragraph.\n\n');

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

    public static AgentforceWorkspaceModels.ChatResult parseSuggestions(String raw) {
        AgentforceWorkspaceModels.ChatResult result = new AgentforceWorkspaceModels.ChatResult();
        if (String.isBlank(raw)) {
            result.response = '';
            return result;
        }

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
}
