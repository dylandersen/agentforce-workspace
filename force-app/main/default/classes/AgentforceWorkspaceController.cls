/**
 * Controller for the Agentforce Workspace chat interface.
 * Thin orchestrator that delegates to focused service classes:
 *   - AgentforceWorkspaceModels          (DTOs)
 *   - AgentforceWorkspaceQueryService    (query execution, record tabs)
 *   - AgentforceWorkspaceLinkService     (record link injection)
 *   - AgentforceWorkspaceAnalysisService (prompts, Models API, parsing)
 *   - AgentforceWorkspaceRecordCreator   (record creation flow)
 */
public with sharing class AgentforceWorkspaceController {

    @AuraEnabled
    public static AgentforceWorkspaceModels.ChatResult chat(String userMessage, String conversationHistory, String modelName) {
        AgentforceWorkspaceModels.ChatResult error = new AgentforceWorkspaceModels.ChatResult();
        if (String.isBlank(userMessage)) {
            error.response = '<p>Please provide a question.</p>';
            return error;
        }

        String resolvedModel = String.isNotBlank(modelName)
            ? modelName : AgentforceWorkspaceAnalysisService.DEFAULT_MODEL;

        try {
            String userId = UserInfo.getUserId();
            String userName = UserInfo.getFirstName();
            if (String.isBlank(userName)) {
                userName = UserInfo.getName().split(' ')[0];
            }

            // --- Pass 1: NL to SOQL ---
            String schemaContext = BusinessIntelligence.buildSchemaContext(userMessage);
            String nlToSoqlPrompt = AgentforceWorkspaceAnalysisService.buildNLtoSOQLPrompt(
                userMessage, conversationHistory, userId, userName, schemaContext);
            String soqlResponse = AgentforceWorkspaceAnalysisService.callModelsAPI(nlToSoqlPrompt, resolvedModel);

            // Check for record creation/update action before SOQL parsing
            Map<String, Object> createAction = AgentforceWorkspaceRecordCreator.parseCreateAction(soqlResponse);
            if (createAction != null) {
                // Multi-record create (e.g. "create an account AND a contact on it")
                if (createAction.containsKey('actions')) {
                    return AgentforceWorkspaceRecordCreator.handleMultiCreateExecute(createAction, userName, resolvedModel);
                }
                String action = (String) createAction.get('action');
                if (action == 'create') {
                    return AgentforceWorkspaceRecordCreator.handleCreateConfirm(createAction, userName, resolvedModel);
                } else if (action == 'create_execute') {
                    return AgentforceWorkspaceRecordCreator.handleCreateExecute(createAction, userName, resolvedModel);
                } else if (action == 'update_execute') {
                    return AgentforceWorkspaceRecordCreator.handleUpdateExecute(createAction, userName);
                } else if (action == 'update_cancel') {
                    return AgentforceWorkspaceRecordCreator.handleUpdateCancel(userName);
                }
            }

            List<BusinessIntelligence.QueryPlan> plans = BusinessIntelligence.parseAndValidateSOQL(soqlResponse);

            if (plans.isEmpty()) {
                error.response = '<p>I couldn\'t generate a valid query for that question. Could you try rephrasing it?</p>';
                return error;
            }

            // --- Execute validated queries as running user ---
            List<BusinessIntelligence.QueryExecution> executions = BusinessIntelligence.executeQueries(plans);

            // --- Retry if ALL queries failed ---
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
                    + '\n- Do not use GROUP BY on non-groupable fields (Subject, Description, AnnualRevenue, etc.)'
                    + '\n- Use aggregate functions (SUM, AVG, MAX) only with GROUP BY on groupable fields'
                    + '\n- For ranking/sorting, use ORDER BY instead of GROUP BY'
                    + '\n- For activity analysis, GROUP BY ActivityType, Status, or TaskSubtype — not Subject'
                    + '\n- Ensure field names exist on the queried object'
                    + '\nGenerate corrected SOQL now.';
                String retryResponse = AgentforceWorkspaceAnalysisService.callModelsAPI(retryPrompt, resolvedModel);
                if (String.isNotBlank(retryResponse) && !retryResponse.trim().startsWith('<p>Error')) {
                    List<BusinessIntelligence.QueryPlan> retryPlans = BusinessIntelligence.parseAndValidateSOQL(retryResponse);
                    if (!retryPlans.isEmpty()) {
                        executions = BusinessIntelligence.executeQueries(retryPlans);
                    }
                }
            }

            // --- Consolidated data collection ---
            Set<Id> allOppIds = AgentforceWorkspaceQueryService.collectAllOppIds(executions);
            Set<String> objectsWithRecords = AgentforceWorkspaceQueryService.findObjectsWithRecords(executions);
            Map<String, List<SObject>> supplementaryRecords =
                AgentforceWorkspaceQueryService.runSupplementaryQueries(executions, objectsWithRecords);

            // Collect supplementary Opportunity IDs for account lookup
            if (supplementaryRecords.containsKey('Opportunity')) {
                for (SObject rec : supplementaryRecords.get('Opportunity')) {
                    if (rec.Id != null) allOppIds.add(rec.Id);
                }
            }

            Map<Id, Opportunity> oppAccountMap = AgentforceWorkspaceQueryService.lookupOppAccounts(allOppIds);
            Map<String, List<String>> recordLinks =
                AgentforceWorkspaceLinkService.collectRecordLinks(executions, oppAccountMap, supplementaryRecords);

            // --- Pass 2: Results to Analysis ---
            AgentforceWorkspaceModels.ExecutionData data = new AgentforceWorkspaceModels.ExecutionData();
            data.queryResultsText = AgentforceWorkspaceQueryService.formatQueryResults(executions);
            data.recordLinks = recordLinks;
            data.userName = userName;
            data.userFullName = UserInfo.getName();
            data.hasAnyResults = AgentforceWorkspaceQueryService.checkHasAnyResults(executions);

            String analysisPrompt = AgentforceWorkspaceAnalysisService.buildAnalysisPromptFromData(
                data, userMessage, conversationHistory);
            String rawResponse = AgentforceWorkspaceAnalysisService.callModelsAPI(analysisPrompt, resolvedModel);

            // Protect EMAIL_DRAFT block from link injection (JSON would break)
            String emailDraftBlock = '';
            Integer edStart = rawResponse.indexOf('<EMAIL_DRAFT>');
            Integer edEnd = rawResponse.indexOf('</EMAIL_DRAFT>');
            if (edStart != -1 && edEnd != -1 && edEnd > edStart) {
                emailDraftBlock = rawResponse.substring(edStart, edEnd + 14);
                rawResponse = rawResponse.substring(0, edStart)
                    + '___EMAIL_DRAFT_PLACEHOLDER___'
                    + rawResponse.substring(edEnd + 14);
            }
            rawResponse = AgentforceWorkspaceLinkService.safeInjectRecordLinks(rawResponse, recordLinks);
            if (String.isNotBlank(emailDraftBlock)) {
                rawResponse = rawResponse.replace('___EMAIL_DRAFT_PLACEHOLDER___', emailDraftBlock);
            }

            // Build record tabs for the list view (core CRM objects only)
            List<AgentforceWorkspaceModels.RecordTab> recordTabs =
                AgentforceWorkspaceQueryService.buildRecordTabs(executions, oppAccountMap, supplementaryRecords);

            AgentforceWorkspaceModels.ChatResult result =
                AgentforceWorkspaceAnalysisService.parseSuggestions(rawResponse);
            result.recordTabs = recordTabs;
            return result;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'AgentforceWorkspace error: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, 'Stack: ' + e.getStackTraceString());
            error.response = '<p>Something went wrong while analyzing your question. Please try again.</p>';
            return error;
        }
    }

    /**
     * Stage 1: Translate NL→SOQL, execute queries, collect record links, build record tabs.
     * Returns immediately-displayable record tabs plus serialized execution data for Stage 2.
     */
    @AuraEnabled
    public static AgentforceWorkspaceModels.QueryResult buildQueries(String userMessage, String conversationHistory, String modelName) {
        AgentforceWorkspaceModels.QueryResult result = new AgentforceWorkspaceModels.QueryResult();
        if (String.isBlank(userMessage)) {
            result.querySummary = 'Please provide a question.';
            return result;
        }

        String resolvedModel = String.isNotBlank(modelName)
            ? modelName : AgentforceWorkspaceAnalysisService.DEFAULT_MODEL;

        try {
            String userId = UserInfo.getUserId();
            String userName = UserInfo.getFirstName();
            if (String.isBlank(userName)) {
                userName = UserInfo.getName().split(' ')[0];
            }
            String userFullName = UserInfo.getName();

            // --- Reasoning Engine: Intent Classification + SOQL Generation Loop ---
            AgentforceWorkspaceModels.ReasoningResult reasoning =
                AgentforceWorkspaceReasoningEngine.reason(
                    userMessage, conversationHistory, userId, userName, resolvedModel);

            // Surface intent understanding for the frontend
            if (reasoning.classifiedIntent != null) {
                result.intentLabel = reasoning.classifiedIntent.plan;
            }
            result.reasoningAttempts = reasoning.attemptsUsed;

            // ── Handle: Clarification needed ──
            if (!reasoning.success && reasoning.createAction == null
                    && reasoning.classifiedIntent != null
                    && reasoning.classifiedIntent.intent == 'CLARIFY') {
                result.querySummary = reasoning.classifiedIntent.clarification;
                result.executionDataJson = JSON.serialize(new Map<String, Object>{
                    'isFailureExplanation' => true,
                    'html' => reasoning.failureExplanation != null
                        ? reasoning.failureExplanation : reasoning.classifiedIntent.clarification,
                    'suggestions' => reasoning.alternativeSuggestions != null
                        ? reasoning.alternativeSuggestions : new List<String>()
                });
                return result;
            }

            // ── Handle: Create/Update action detected ──
            if (reasoning.createAction != null) {
                Map<String, Object> createAction = reasoning.createAction;
                // Multi-record create
                if (createAction.containsKey('actions')) {
                    AgentforceWorkspaceModels.ChatResult cr =
                        AgentforceWorkspaceRecordCreator.handleMultiCreateExecute(createAction, userName, resolvedModel);
                    result.executionDataJson = JSON.serialize(new Map<String, Object>{
                        'isCreateResult' => true,
                        'chatResult' => cr
                    });
                    result.querySummary = 'Creating records...';
                    result.hasResults = true;
                    return result;
                }
                String action = (String) createAction.get('action');
                if (action == 'create') {
                    AgentforceWorkspaceModels.ChatResult cr =
                        AgentforceWorkspaceRecordCreator.handleCreateConfirm(createAction, userName, resolvedModel);
                    result.executionDataJson = JSON.serialize(new Map<String, Object>{
                        'isCreateResult' => true,
                        'chatResult' => cr
                    });
                    result.querySummary = 'Processing your request...';
                    return result;
                } else if (action == 'create_execute') {
                    AgentforceWorkspaceModels.ChatResult cr =
                        AgentforceWorkspaceRecordCreator.handleCreateExecute(createAction, userName, resolvedModel);
                    result.executionDataJson = JSON.serialize(new Map<String, Object>{
                        'isCreateResult' => true,
                        'chatResult' => cr
                    });
                    result.querySummary = 'Creating record...';
                    result.hasResults = true;
                    return result;
                } else if (action == 'update_execute') {
                    AgentforceWorkspaceModels.ChatResult cr =
                        AgentforceWorkspaceRecordCreator.handleUpdateExecute(createAction, userName);
                    result.executionDataJson = JSON.serialize(new Map<String, Object>{
                        'isCreateResult' => true,
                        'chatResult' => cr
                    });
                    result.querySummary = 'Updating record...';
                    result.hasResults = true;
                    return result;
                } else if (action == 'update_cancel') {
                    AgentforceWorkspaceModels.ChatResult cr =
                        AgentforceWorkspaceRecordCreator.handleUpdateCancel(userName);
                    result.executionDataJson = JSON.serialize(new Map<String, Object>{
                        'isCreateResult' => true,
                        'chatResult' => cr
                    });
                    result.querySummary = 'Got it!';
                    return result;
                }
            }

            // ── Handle: Reasoning failed after all attempts ──
            if (!reasoning.success || reasoning.executions == null || reasoning.executions.isEmpty()) {
                result.querySummary = 'I had trouble processing that question.';
                result.executionDataJson = JSON.serialize(new Map<String, Object>{
                    'isFailureExplanation' => true,
                    'html' => reasoning.failureExplanation != null
                        ? reasoning.failureExplanation
                        : '<p>I couldn\'t process that question. Try rephrasing.</p>',
                    'suggestions' => reasoning.alternativeSuggestions != null
                        ? reasoning.alternativeSuggestions
                        : new List<String>{ 'Show my pipeline', 'List my accounts' }
                });
                return result;
            }

            // ── Success: use the reasoning engine's query executions ──
            List<BusinessIntelligence.QueryExecution> executions = reasoning.executions;

            // --- Consolidated data collection ---
            Set<Id> allOppIds = AgentforceWorkspaceQueryService.collectAllOppIds(executions);
            Set<String> objectsWithRecords = AgentforceWorkspaceQueryService.findObjectsWithRecords(executions);
            Map<String, List<SObject>> supplementaryRecords =
                AgentforceWorkspaceQueryService.runSupplementaryQueries(executions, objectsWithRecords);

            // Collect supplementary Opportunity IDs for account lookup
            if (supplementaryRecords.containsKey('Opportunity')) {
                for (SObject rec : supplementaryRecords.get('Opportunity')) {
                    if (rec.Id != null) allOppIds.add(rec.Id);
                }
            }

            Map<Id, Opportunity> oppAccountMap = AgentforceWorkspaceQueryService.lookupOppAccounts(allOppIds);
            Map<String, List<String>> recordLinks =
                AgentforceWorkspaceLinkService.collectRecordLinks(executions, oppAccountMap, supplementaryRecords);
            List<AgentforceWorkspaceModels.RecordTab> recordTabs =
                AgentforceWorkspaceQueryService.buildRecordTabs(executions, oppAccountMap, supplementaryRecords);

            // Build query summary
            Set<String> queriedLabels = new Set<String>();
            for (AgentforceWorkspaceModels.RecordTab tab : recordTabs) {
                queriedLabels.add(tab.objectLabel.toLowerCase());
            }

            // Pre-format query results for analyzeResults
            AgentforceWorkspaceModels.ExecutionData ed = new AgentforceWorkspaceModels.ExecutionData();
            ed.queryResultsText = AgentforceWorkspaceQueryService.formatQueryResults(executions);
            ed.recordLinks = recordLinks;
            ed.userName = userName;
            ed.userFullName = userFullName;
            ed.hasAnyResults = AgentforceWorkspaceQueryService.checkHasAnyResults(executions);

            // ── Data Cloud Enrichment ──────────────────────────────────────
            // If the user is asking about consumption/credit usage, inject Data Cloud DLO data
            // so Pass 2 can provide a unified CRM + Data Cloud analysis.
            try {
                A8_DataCloudCreditUsageService.EnrichmentResult dcResult =
                    A8_DataCloudCreditUsageService.enrich(userMessage, executions);
                if (dcResult != null && dcResult.hasData) {
                    ed.queryResultsText += '\n\n' + dcResult.formattedResults;
                    ed.hasAnyResults = true;
                    queriedLabels.add('Data Cloud usage');
                    // Surface each DLO account as a dedicated Related Records tab (supports comparison)
                    if (dcResult.recordTabs != null && !dcResult.recordTabs.isEmpty()) {
                        for (Integer ti = dcResult.recordTabs.size() - 1; ti >= 0; ti--) {
                            recordTabs.add(0, dcResult.recordTabs[ti]);
                        }
                    }
                }
            } catch (Exception dcEx) {
                // DC enrichment failures are non-fatal — log and continue
                System.debug(LoggingLevel.WARN, 'Data Cloud enrichment skipped: ' + dcEx.getMessage());
            }

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
    public static AgentforceWorkspaceModels.ChatResult analyzeResults(String executionDataJson, String userMessage, String conversationHistory, String modelName) {
        AgentforceWorkspaceModels.ChatResult error = new AgentforceWorkspaceModels.ChatResult();
        if (String.isBlank(executionDataJson)) {
            error.response = '<p>No query data available to analyze.</p>';
            return error;
        }

        String resolvedModel = String.isNotBlank(modelName)
            ? modelName : AgentforceWorkspaceAnalysisService.DEFAULT_MODEL;

        try {
            Map<String, Object> wrapper = (Map<String, Object>) JSON.deserializeUntyped(executionDataJson);

            // Handle reasoning engine failure explanations (all attempts exhausted or clarification needed)
            if (wrapper.containsKey('isFailureExplanation') && (Boolean) wrapper.get('isFailureExplanation')) {
                AgentforceWorkspaceModels.ChatResult cr = new AgentforceWorkspaceModels.ChatResult();
                cr.response = (String) wrapper.get('html');
                if (wrapper.containsKey('suggestions') && wrapper.get('suggestions') != null) {
                    for (Object s : (List<Object>) wrapper.get('suggestions')) {
                        cr.suggestions.add(String.valueOf(s));
                    }
                }
                return cr;
            }

            // Handle create action results (already processed in buildQueries)
            if (wrapper.containsKey('isCreateResult') && (Boolean) wrapper.get('isCreateResult')) {
                Map<String, Object> crMap = (Map<String, Object>) wrapper.get('chatResult');
                AgentforceWorkspaceModels.ChatResult cr = new AgentforceWorkspaceModels.ChatResult();
                cr.response = (String) crMap.get('response');
                cr.forceRecordUpdate = crMap.containsKey('forceRecordUpdate') ? (Boolean) crMap.get('forceRecordUpdate') : false;
                if (crMap.containsKey('suggestions')) {
                    List<Object> sugs = (List<Object>) crMap.get('suggestions');
                    for (Object s : sugs) cr.suggestions.add(String.valueOf(s));
                }
                // Deserialize createdRecord info for the frontend card
                if (crMap.containsKey('createdRecord') && crMap.get('createdRecord') != null) {
                    cr.createdRecord = deserializeCreatedRecordInfo((Map<String, Object>) crMap.get('createdRecord'));
                }
                // Deserialize all created records for multi-create
                if (crMap.containsKey('allCreatedRecords') && crMap.get('allCreatedRecords') != null) {
                    List<AgentforceWorkspaceModels.CreatedRecordInfo> allRecs = new List<AgentforceWorkspaceModels.CreatedRecordInfo>();
                    for (Object recObj : (List<Object>) crMap.get('allCreatedRecords')) {
                        allRecs.add(deserializeCreatedRecordInfo((Map<String, Object>) recObj));
                    }
                    cr.allCreatedRecords = allRecs;
                }
                // Deserialize updatedRecord info
                if (crMap.containsKey('updatedRecord') && crMap.get('updatedRecord') != null) {
                    cr.updatedRecord = deserializeCreatedRecordInfo((Map<String, Object>) crMap.get('updatedRecord'));
                }
                // Deserialize pending update prompt
                if (crMap.containsKey('pendingUpdate') && crMap.get('pendingUpdate') != null) {
                    Map<String, Object> puMap = (Map<String, Object>) crMap.get('pendingUpdate');
                    AgentforceWorkspaceModels.PendingUpdate pu = new AgentforceWorkspaceModels.PendingUpdate();
                    pu.recordId = (String) puMap.get('recordId');
                    pu.objectApiName = (String) puMap.get('objectApiName');
                    pu.recordName = (String) puMap.get('recordName');
                    if (puMap.containsKey('blankFields') && puMap.get('blankFields') != null) {
                        for (Object fpObj : (List<Object>) puMap.get('blankFields')) {
                            Map<String, Object> fpMap = (Map<String, Object>) fpObj;
                            AgentforceWorkspaceModels.FieldPromptItem fp = new AgentforceWorkspaceModels.FieldPromptItem();
                            fp.apiName = (String) fpMap.get('apiName');
                            fp.label = (String) fpMap.get('label');
                            pu.blankFields.add(fp);
                        }
                    }
                    cr.pendingUpdate = pu;
                }
                cr.pendingUpdateCleared = crMap.containsKey('pendingUpdateCleared')
                    && crMap.get('pendingUpdateCleared') == true;
                return cr;
            }

            // Deserialize execution data
            Map<String, Object> edMap = (Map<String, Object>) wrapper.get('executionData');
            AgentforceWorkspaceModels.ExecutionData data = new AgentforceWorkspaceModels.ExecutionData();
            data.queryResultsText = (String) edMap.get('queryResultsText');
            data.userName = (String) edMap.get('userName');
            data.userFullName = edMap.containsKey('userFullName') ? (String) edMap.get('userFullName') : UserInfo.getName();
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
            String analysisPrompt = AgentforceWorkspaceAnalysisService.buildAnalysisPromptFromData(
                data, userMessage, conversationHistory);
            String rawResponse = AgentforceWorkspaceAnalysisService.callModelsAPI(analysisPrompt, resolvedModel);

            // Protect EMAIL_DRAFT block from link injection (JSON would break)
            String emailDraftBlock2 = '';
            Integer edStart2 = rawResponse.indexOf('<EMAIL_DRAFT>');
            Integer edEnd2 = rawResponse.indexOf('</EMAIL_DRAFT>');
            if (edStart2 != -1 && edEnd2 != -1 && edEnd2 > edStart2) {
                emailDraftBlock2 = rawResponse.substring(edStart2, edEnd2 + 14);
                rawResponse = rawResponse.substring(0, edStart2)
                    + '___EMAIL_DRAFT_PLACEHOLDER___'
                    + rawResponse.substring(edEnd2 + 14);
            }
            rawResponse = AgentforceWorkspaceLinkService.safeInjectRecordLinks(rawResponse, data.recordLinks);
            if (String.isNotBlank(emailDraftBlock2)) {
                rawResponse = rawResponse.replace('___EMAIL_DRAFT_PLACEHOLDER___', emailDraftBlock2);
            }

            return AgentforceWorkspaceAnalysisService.parseSuggestions(rawResponse);

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'analyzeResults error: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, 'Stack: ' + e.getStackTraceString());
            error.response = '<p>Something went wrong while analyzing. Please try again.</p>';
            return error;
        }
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

    /** Shared helper to deserialize a CreatedRecordInfo from a JSON map. */
    private static AgentforceWorkspaceModels.CreatedRecordInfo deserializeCreatedRecordInfo(Map<String, Object> recMap) {
        AgentforceWorkspaceModels.CreatedRecordInfo info = new AgentforceWorkspaceModels.CreatedRecordInfo();
        info.objectApiName = (String) recMap.get('objectApiName');
        info.objectLabel = (String) recMap.get('objectLabel');
        info.iconName = (String) recMap.get('iconName');
        info.recordId = (String) recMap.get('recordId');
        info.recordName = (String) recMap.get('recordName');
        info.recordUrl = (String) recMap.get('recordUrl');
        if (recMap.containsKey('fields') && recMap.get('fields') != null) {
            for (Object fObj : (List<Object>) recMap.get('fields')) {
                Map<String, Object> fMap = (Map<String, Object>) fObj;
                AgentforceWorkspaceModels.RecordField rf = new AgentforceWorkspaceModels.RecordField();
                rf.label = (String) fMap.get('label');
                rf.value = (String) fMap.get('value');
                rf.type = (String) fMap.get('type');
                info.fields.add(rf);
            }
        }
        return info;
    }
}
