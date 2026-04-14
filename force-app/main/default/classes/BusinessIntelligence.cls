global with sharing class BusinessIntelligence {

  // Standard objects with hardcoded detailed schemas in the prompt
  private static final Set<String> STANDARD_BI_OBJECTS = new Set<String>{
    'Account', 'Contact', 'Opportunity', 'Case', 'Lead', 'Task', 'Event',
    'OpportunityLineItem', 'Campaign', 'CampaignMember', 'Contract',
    'OpportunityContactRole', 'User',
    'Incident', 'Problem', 'ChangeRequest', 'Release', 'ConfigurationItem',
    'IncidentConfigurationItem', 'ProblemConfigurationItem', 'ChangeRequestCnfgItem',
    'ProblemIncident', 'ReleaseParticipant', 'ReleaseRelatedRecord',
    'ChangeRequestRelatedIssue', 'ChangeRequestRelatedItem', 'IncidentRelatedItem', 'ProblemRelatedItem'
  };

  private static final Integer MAX_QUERY_LIMIT = 200;

  @InvocableMethod(
    label='Business Intelligence Query'
    description='Answers business intelligence questions by translating natural language into SOQL queries, executing them as the running user, and providing AI-powered analysis of the results.'
  )
  public static List<BIResult> analyze(List<BIRequest> requests) {
    List<BIResult> results = new List<BIResult>();

    if (requests == null || requests.isEmpty()) {
      BIResult errorResult = new BIResult();
      errorResult.chartData = makeHtmlResult('No query provided for analysis.');
      results.add(errorResult);
      return results;
    }

    BIRequest request = requests[0];

    if (String.isBlank(request.userQuery)) {
      BIResult errorResult = new BIResult();
      errorResult.chartData = makeHtmlResult('A question is required for analysis.');
      results.add(errorResult);
      return results;
    }

    try {
      String userId = UserInfo.getUserId();
      String userName = UserInfo.getFirstName();
      if (String.isBlank(userName)) {
          userName = UserInfo.getName().split(' ')[0];
      }
      String resolvedModel = AgentforceWorkspaceAnalysisService.DEFAULT_MODEL;

      // --- Pass 1: NL to SOQL (enhanced workspace prompt) ---
      String schemaContext = buildSchemaContext(request.userQuery);
      String nlToSoqlPrompt = AgentforceWorkspaceAnalysisService.buildNLtoSOQLPrompt(
          request.userQuery, null, userId, userName, schemaContext);
      String soqlResponse = AgentforceWorkspaceAnalysisService.callModelsAPI(nlToSoqlPrompt, resolvedModel);

      // Check for record creation action
      Map<String, Object> createAction = AgentforceWorkspaceRecordCreator.parseCreateAction(soqlResponse);
      if (createAction != null) {
          String action = (String) createAction.get('action');
          AgentforceWorkspaceModels.ChatResult cr;
          if (action == 'create') {
              cr = AgentforceWorkspaceRecordCreator.handleCreateConfirm(createAction, userName, resolvedModel);
          } else if (action == 'create_execute') {
              cr = AgentforceWorkspaceRecordCreator.handleCreateExecute(createAction, userName, resolvedModel);
          } else {
              cr = null;
          }
          if (cr != null) {
              BIResult result = new BIResult();
              result.chartData = makeHtmlResult(cr.response);
              results.add(result);
              return results;
          }
      }

      List<QueryPlan> plans = parseAndValidateSOQL(soqlResponse);

      if (plans.isEmpty()) {
        BIResult errorResult = new BIResult();
        errorResult.chartData = makeHtmlResult('Unable to generate a valid query for your question. Please try rephrasing.');
        results.add(errorResult);
        return results;
      }

      // Execute the validated queries
      List<QueryExecution> executions = executeQueries(plans);

      // --- Retry if ALL queries failed ---
      Boolean allFailed = true;
      List<String> errorMessages = new List<String>();
      for (QueryExecution exec : executions) {
          if (exec.error == null) {
              allFailed = false;
              break;
          }
          errorMessages.add(exec.error + ' | SOQL: ' + exec.soql);
      }
      if (allFailed && !errorMessages.isEmpty()) {
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
              List<QueryPlan> retryPlans = parseAndValidateSOQL(retryResponse);
              if (!retryPlans.isEmpty()) {
                  executions = executeQueries(retryPlans);
              }
          }
      }

      // --- Consolidated data collection ---
      Set<Id> allOppIds = AgentforceWorkspaceQueryService.collectAllOppIds(executions);
      Set<String> objectsWithRecords = AgentforceWorkspaceQueryService.findObjectsWithRecords(executions);
      Map<String, List<SObject>> supplementaryRecords =
          AgentforceWorkspaceQueryService.runSupplementaryQueries(executions, objectsWithRecords);

      if (supplementaryRecords.containsKey('Opportunity')) {
          for (SObject rec : supplementaryRecords.get('Opportunity')) {
              if (rec.Id != null) allOppIds.add(rec.Id);
          }
      }

      Map<Id, Opportunity> oppAccountMap = AgentforceWorkspaceQueryService.lookupOppAccounts(allOppIds);
      Map<String, List<String>> recordLinks =
          AgentforceWorkspaceLinkService.collectRecordLinks(executions, oppAccountMap, supplementaryRecords);

      // --- Pass 2: Results to BI Analysis ---
      AgentforceWorkspaceModels.ExecutionData data = new AgentforceWorkspaceModels.ExecutionData();
      data.queryResultsText = AgentforceWorkspaceQueryService.formatQueryResults(executions);
      data.recordLinks = recordLinks;
      data.userName = userName;
      data.userFullName = UserInfo.getName();
      data.hasAnyResults = AgentforceWorkspaceQueryService.checkHasAnyResults(executions);

      String analysisPrompt = AgentforceWorkspaceAnalysisService.buildAnalysisPromptFromData(
          data, request.userQuery, null);
      String rawResponse = AgentforceWorkspaceAnalysisService.callModelsAPI(analysisPrompt, resolvedModel);

      // Inject record links (protect EMAIL_DRAFT from corruption)
      String emailDraftBlock = '';
      Integer edStart = rawResponse.indexOf('<EMAIL_DRAFT>');
      Integer edEnd = rawResponse.indexOf('</EMAIL_DRAFT>');
      if (edStart != -1 && edEnd != -1 && edEnd > edStart) {
          emailDraftBlock = rawResponse.substring(edStart, edEnd + 14);
          rawResponse = rawResponse.substring(0, edStart)
              + '___EMAIL_DRAFT_PLACEHOLDER___'
              + rawResponse.substring(edEnd + 14);
      }
      rawResponse = AgentforceWorkspaceAnalysisService.enforceRunningUserIdentity(
          rawResponse, data.userName, data.userFullName);
      rawResponse = AgentforceWorkspaceLinkService.safeInjectRecordLinks(rawResponse, recordLinks);
      if (String.isNotBlank(emailDraftBlock)) {
          rawResponse = rawResponse.replace('___EMAIL_DRAFT_PLACEHOLDER___', emailDraftBlock);
      }

      // Extract chart JSON before cleaning strips it
      String chartJson = null;
      Integer cOpen = rawResponse.indexOf('<CHART>');
      Integer cClose = rawResponse.indexOf('</CHART>');
      if (cOpen != -1 && cClose != -1 && cClose > cOpen) {
          chartJson = rawResponse.substring(cOpen + 7, cClose).trim();
      }

      // Clean up response for Agentforce
      rawResponse = cleanResponseForAgent(rawResponse);

      BIResult result = new BIResult();
      result.chartData = makeHtmlResult(rawResponse);
      result.chartData.chartJson = chartJson;
      results.add(result);
      return results;
    } catch (Exception e) {
      System.debug(LoggingLevel.ERROR, 'Error in BusinessIntelligence.analyze: ' + e.getMessage());
      System.debug(LoggingLevel.ERROR, 'Stack Trace: ' + e.getStackTraceString());
      BIResult errorResult = new BIResult();
      errorResult.chartData = makeHtmlResult('Error analyzing your question: ' + e.getMessage()
        + '\n\nPlease check debug logs for more details.');
      results.add(errorResult);
      return results;
    }
  }

  // ═══════════════════════════════════════════════
  // Response Cleanup for Agentforce
  // ═══════════════════════════════════════════════

  /**
   * Clean response for Agentforce output:
   * - Convert EMAIL_DRAFT blocks to readable inline HTML
   * - Strip CHART blocks (Agentforce cannot render them)
   * - Strip SUGGESTIONS blocks (agent manages follow-ups itself)
   */
  private static AnalyticsChartResult makeHtmlResult(String html) {
      AnalyticsChartResult r = new AnalyticsChartResult();
      r.analysisHtml = html;
      return r;
  }

  @TestVisible
  private static String cleanResponseForAgent(String response) {
      if (String.isBlank(response)) return response;

      // Convert EMAIL_DRAFT to readable HTML
      Integer emailOpen = response.indexOf('<EMAIL_DRAFT>');
      Integer emailClose = response.indexOf('</EMAIL_DRAFT>');
      if (emailOpen != -1 && emailClose != -1 && emailClose > emailOpen) {
          String emailJson = response.substring(emailOpen + 13, emailClose).trim();
          String emailHtml = formatEmailDraftAsHtml(emailJson);
          response = response.substring(0, emailOpen) + emailHtml + response.substring(emailClose + 14);
      }

      // Strip CHART blocks
      Integer chartOpen = response.indexOf('<CHART>');
      Integer chartClose = response.indexOf('</CHART>');
      if (chartOpen != -1 && chartClose != -1 && chartClose > chartOpen) {
          response = response.substring(0, chartOpen) + response.substring(chartClose + 8);
      }

      // Strip SUGGESTIONS blocks
      Integer sugOpen = response.indexOf('<SUGGESTIONS>');
      Integer sugClose = response.indexOf('</SUGGESTIONS>');
      if (sugOpen != -1 && sugClose != -1 && sugClose > sugOpen) {
          response = response.substring(0, sugOpen);
      }

      return response.trim();
  }

  private static String formatEmailDraftAsHtml(String emailJson) {
      try {
          Map<String, Object> em = (Map<String, Object>) JSON.deserializeUntyped(emailJson);
          String toName = (String) em.get('toName');
          String toAddress = (String) em.get('toAddress');
          String subject = (String) em.get('subject');
          String body = (String) em.get('body');

          List<String> html = new List<String>();
          html.add('<h2>Draft Email</h2>');
          if (String.isNotBlank(toName)) {
              String toLine = '<p><b>To:</b> ' + toName;
              if (String.isNotBlank(toAddress)) toLine += ' (' + toAddress + ')';
              toLine += '</p>';
              html.add(toLine);
          }
          if (String.isNotBlank(subject)) {
              html.add('<p><b>Subject:</b> ' + subject + '</p>');
          }
          html.add('<hr/>');
          if (String.isNotBlank(body)) {
              List<String> paragraphs = body.split('\n\n');
              for (String p : paragraphs) {
                  String trimmed = p.trim();
                  if (String.isNotBlank(trimmed)) {
                      html.add('<p>' + trimmed.replace('\n', '<br/>') + '</p>');
                  }
              }
          }
          return String.join(html, '');
      } catch (Exception e) {
          System.debug(LoggingLevel.WARN, 'Failed to format email draft: ' + e.getMessage());
          return '';
      }
  }

  // ═══════════════════════════════════════════════
  // Schema Context (shared with AgentforceWorkspaceController)
  // ═══════════════════════════════════════════════

  /**
   * Build schema context: hardcoded standard objects + dynamically discovered custom objects
   */
  @TestVisible
  public static String buildSchemaContext() {
    return buildSchemaContext(null);
  }

  /**
   * Build schema context with optional user message so explicitly named custom
   * objects (e.g., My_Object__c) are always included in the prompt.
   */
  @TestVisible
  public static String buildSchemaContext(String userMessage) {
    List<String> parts = new List<String>();
    parts.add('## SALESFORCE SCHEMA\n\n');

    // --- Hardcoded standard object schemas (detailed fields) ---
    parts.add('### Standard Objects\n\n');

    parts.add('**Account** — Company/organization record\n');
    parts.add('Key fields: Id, Name, Type, Industry, AnnualRevenue, NumberOfEmployees, OwnerId, LastActivityDate, BillingCity, BillingState, BillingCountry, Phone, Website, Description, CreatedDate, LastModifiedDate, ParentId\n\n');

    parts.add('**Contact** — Individual person record\n');
    parts.add('Key fields: Id, Name, FirstName, LastName, Email, Phone, MobilePhone, Title, Department, AccountId, OwnerId, MailingCity, MailingState, MailingCountry, LeadSource, CreatedDate, LastModifiedDate\n\n');

    parts.add('**Opportunity** — Sales deal record\n');
    parts.add('Key fields: Id, Name, Amount, StageName, Probability, CloseDate, Type, LeadSource, NextStep, Description, AccountId, OwnerId, IsClosed, IsWon, ForecastCategory, ForecastCategoryName, CreatedDate, LastModifiedDate, ExpectedRevenue, CampaignId, ContactId\n');
    parts.add('Common stages: Prospecting, Qualification, Needs Analysis, Value Proposition, Id. Decision Makers, Perception Analysis, Proposal/Price Quote, Negotiation/Review, Closed Won, Closed Lost\n\n');

    parts.add('**Case** — Customer service/support record\n');
    parts.add('Key fields: Id, CaseNumber, Subject, Description, Status, Priority, Type, Origin, AccountId, ContactId, OwnerId, IsClosed, ClosedDate, CreatedDate, LastModifiedDate\n');
    parts.add('Common statuses: New, Working, Escalated, Closed\n');
    parts.add('Common priorities: High, Medium, Low\n\n');

    parts.add('**Lead** — Prospective customer record\n');
    parts.add('Key fields: Id, Name, FirstName, LastName, Company, Title, Email, Phone, Status, LeadSource, Industry, AnnualRevenue, NumberOfEmployees, OwnerId, IsConverted, ConvertedAccountId, ConvertedContactId, ConvertedOpportunityId, CreatedDate, LastModifiedDate\n\n');

    parts.add('**Task** — Activity/to-do record\n');
    parts.add('Key fields: Id, Subject, Status, Priority, ActivityDate, Description, WhoId, WhatId, OwnerId, IsClosed, CreatedDate, CallType, CallDurationInSeconds, TaskSubtype\n\n');

    parts.add('**Event** — Calendar event/meeting record\n');
    parts.add('Key fields: Id, Subject, StartDateTime, EndDateTime, Description, WhoId, WhatId, OwnerId, DurationInMinutes, Location, IsAllDayEvent, CreatedDate\n\n');

    parts.add('**OpportunityLineItem** — Product line on an opportunity\n');
    parts.add('Key fields: Id, OpportunityId, Name, Quantity, UnitPrice, TotalPrice, Description\n\n');

    parts.add('**Campaign** — Marketing campaign record\n');
    parts.add('Key fields: Id, Name, Type, Status, StartDate, EndDate, BudgetedCost, ActualCost, ExpectedRevenue, NumberOfLeads, NumberOfContacts, NumberOfOpportunities, NumberOfWonOpportunities, AmountWonOpportunities, IsActive, OwnerId, CreatedDate\n\n');

    parts.add('**CampaignMember** — Campaign participation record\n');
    parts.add('Key fields: Id, CampaignId, LeadId, ContactId, Status, FirstRespondedDate, CreatedDate\n\n');

    parts.add('**Contract** — Contract/agreement record\n');
    parts.add('Key fields: Id, ContractNumber, AccountId, Status, StartDate, EndDate, ContractTerm, OwnerId, CreatedDate\n\n');

    parts.add('**OpportunityContactRole** — Links Contact to Opportunity with a Role (e.g., Decision Maker, Champion, Evaluator, Economic Buyer). REQUIRED when the user asks about decision makers, contact roles, stakeholders, or contacts on opportunities.\n');
    parts.add('Key fields: Id, OpportunityId, ContactId, Role, IsPrimary, Contact.Name, Contact.Email, Opportunity.Name, Opportunity.Amount, Opportunity.StageName\n');
    parts.add('Query pattern: SELECT Id, OpportunityId, ContactId, Role, IsPrimary, Contact.Name, Contact.Email, Opportunity.Name, Opportunity.Amount FROM OpportunityContactRole WHERE OpportunityId IN (SELECT Id FROM Opportunity WHERE ...) [AND Role = \'Decision Maker\' if user asks for decision makers]. Always include Contact.Name and Opportunity.Name for display.\n\n');

    parts.add('**User** — Salesforce user record\n');
    parts.add('Key fields: Id, Name, FirstName, LastName, Email, Username, IsActive, UserRoleId, ProfileId, ManagerId, Department, Title, Phone, CreatedDate\n\n');

    // --- ITSM objects ---
    parts.add('**Incident** — IT incident/service disruption record\n');
    parts.add('Key fields: Id, IncidentNumber, Subject, Description, Status, Priority, Category, SubCategory, Impact, Urgency, Type, OwnerId, AssignedUserId, AssignedGroupId, ReportedById, ResolvedById, IsClosed, IsMajorIncident, MajorIncidentStatus, ParentIncidentId, StartDateTime, EndDateTime, ResolutionDateTime, ResolutionSummary, CreatedDate, LastModifiedDate\n');
    parts.add('Common statuses: New, In Progress, Pending, Resolved, Closed\n');
    parts.add('TEXT SEARCH: For incidents "related to" or "about" a product/keyword (e.g., Zscaler, VPN), use SOSL to search BOTH Subject AND Description: '
      + 'FIND {keyword} IN ALL FIELDS RETURNING Incident(Id, IncidentNumber, Subject, Status, Priority, CreatedDate WHERE CreatedDate = LAST_N_DAYS:90) LIMIT 200. '
      + 'SOSL searches long text (Description); SOQL Subject LIKE only searches the title. For date range use LAST_N_DAYS:n or LAST_N_MONTHS:n in the WHERE.\n\n');

    parts.add('**Problem** — Root cause investigation record\n');
    parts.add('Key fields: Id, ProblemNumber, Subject, Description, Status, Priority, Category, SubCategory, Impact, Urgency, OwnerId, AssignedUserId, AssignedGroupId, ReportedById, ResolvedById, IsClosed, ParentProblemId, ResolutionDateTime, ResolutionSummary, RootCauseSummary, Workaround, PermanentSolution, CreatedDate, LastModifiedDate\n');
    parts.add('Common statuses: New, Investigating, Known Error, Resolved, Closed\n\n');

    parts.add('**ChangeRequest** — IT change request record\n');
    parts.add('Key fields: Id, ChangeRequestNumber, Subject, Description, Status, Priority, ChangeType, Category, SubCategory, Impact, Urgency, RiskLevel, OwnerId, AssignedUserId, AssignedGroupId, RequestedById, ReviewerId, IsClosed, EstimatedStartTime, EstimatedEndTime, ActualStartDate, CompletionDate, ImplementationPlan, TestPlan, RemediationPlan, CreatedDate, LastModifiedDate\n');
    parts.add('Common statuses: Draft, Submitted, In Progress, Pending Approval, Scheduled, Implemented, Closed\n\n');

    parts.add('**Release** — Release/deployment record\n');
    parts.add('Key fields: Id, Name, Description, Status, Priority, Type, RiskLevel, OwnerId, ReleaseOwnerId, RequestedById, PlannedStartDate, PlannedEndDate, PlannedDuration, ActualStartDate, ActualEndDate, ActualDuration, DeploymentDate, ClosingSummary, CreatedDate, LastModifiedDate\n\n');

    parts.add('**ConfigurationItem** — CMDB configuration item record\n');
    parts.add('Key fields: Id, Name, AssetId, ConfigurationItemTypeId, OwnerId, CreatedDate, LastModifiedDate\n\n');

    parts.add('**IncidentConfigurationItem** — Links Incident to ConfigurationItem (affected CIs)\n');
    parts.add('Key fields: Id, IncidentId, ConfigurationItemId, RelationshipType, Name, CreatedDate\n\n');

    parts.add('**ProblemConfigurationItem** — Links Problem to ConfigurationItem (affected CIs)\n');
    parts.add('Key fields: Id, ProblemId, ConfigurationItemId, RelationshipType, Name, CreatedDate\n\n');

    parts.add('**ChangeRequestCnfgItem** — Links ChangeRequest to ConfigurationItem (affected CIs)\n');
    parts.add('Key fields: Id, ChangeRequestId, ConfigurationItemId, RelationshipType, Name, CreatedDate\n\n');

    parts.add('**ProblemIncident** — Links Problem to Incident (related issues)\n');
    parts.add('Key fields: Id, IssueId, RelatedIssueId, RelatedEntityType, RelationshipType, Name, CreatedDate\n');
    parts.add('IssueId and RelatedIssueId reference either Problem or Incident; use RelatedEntityType to distinguish\n\n');

    parts.add('**ReleaseParticipant** — Release participant/assignee\n');
    parts.add('Key fields: Id, ReleaseId, AssignedToId, Role, Name, CreatedDate\n\n');

    parts.add('**ReleaseRelatedRecord** — Links Release to related records (ChangeRequest, Incident, Problem, Release)\n');
    parts.add('Key fields: Id, ReleaseId, RelatedRecordId, RelationshipType, Name, CreatedDate\n');
    parts.add('RelatedRecordId is polymorphic lookup to Problem, Incident, ChangeRequest, or Release\n\n');

    parts.add('**ChangeRequestRelatedIssue** — Links ChangeRequest to related Incident/Problem/Case/ChangeRequest\n');
    parts.add('Key fields: Id, ChangeRequestId, RelatedIssueId, RelatedEntityType, RelationshipType, Name, CreatedDate\n');
    parts.add('RelatedIssueId is polymorphic lookup to Problem, Incident, Case, or ChangeRequest\n\n');

    parts.add('**ChangeRequestRelatedItem** — Links ChangeRequest to related Asset\n');
    parts.add('Key fields: Id, ChangeRequestId, AssetId, Comment, ImpactLevel, RelationshipType, Name, CreatedDate\n\n');

    parts.add('**IncidentRelatedItem** — Links Incident to related Asset or Product\n');
    parts.add('Key fields: Id, IncidentId, AssetId, Product2Id, Comment, ImpactLevel, ImpactType, Name, CreatedDate\n\n');

    parts.add('**ProblemRelatedItem** — Links Problem to related Asset\n');
    parts.add('Key fields: Id, ProblemId, AssetId, Comment, ImpactLevel, ImpactType, Name, CreatedDate\n\n');

    // --- Compliance Document (hardcoded for NL-to-SOQL accuracy) ---
    parts.add('**Compliance_Document__c** — Compliance/legal agreement tracking for school districts (DPAs, MSAs, FERPA/COPPA docs, security questionnaires)\n');
    parts.add('Key fields: Id, Name, Document_Title__c, Document_Type__c, District_Account__c, State__c, Status__c, Processing_Status__c, Expiration_Date__c, Effective_Date__c, Renewal_Date__c, Priority__c, Student_Count__c, Products_Covered__c, Data_Categories__c, FERPA_Compliant__c, COPPA_Compliant__c, Data_Deletion_Clause__c, Breach_Notification_Days__c, Data_Retention_Period__c, Security_Standards__c, AI_Confidence_Score__c, AI_Summary__c, Missing_Clauses__c, AI_Processed_Date__c, Related_Opportunity__c, District_Contact__c, Assigned_To__c, Notes__c\n');
    parts.add('Relationships: District_Account__c -> Account (school district), Related_Opportunity__c -> Opportunity, District_Contact__c -> Contact, Assigned_To__c -> User\n');
    parts.add('Common statuses: Draft, Pending Review, Under Legal Review, Pending District Signature, Active, Expired, Renewal Required, Superseded\n');
    parts.add('Processing statuses: Not Processed, Processing, Processed, Needs Human Review, Processing Failed\n');
    parts.add('Document types: DPA (SDPC National), DPA (State-Specific), DPA (District Custom), MSA, FERPA Compliance Agreement, COPPA Consent, Licensing Agreement, State Addendum, Security Questionnaire, VPAT/ACR\n');
    parts.add('Query patterns: Use District_Account__r.Name for district name. Filter by State__c for state-specific queries. Use Expiration_Date__c < TODAY + N for expiring docs. Use Processing_Status__c for AI processing status. AI_Confidence_Score__c is a Percent (0-1 range in SOQL, display as percentage).\n\n');

    // --- Dynamic discovery of custom objects (enriched via SchemaService) ---
    parts.add('### Custom Objects\n\n');
    Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
    Map<String, String> customObjByLower = new Map<String, String>();
    for (String objName : globalDescribe.keySet()) {
      if (objName.endsWith('__c')) {
        customObjByLower.put(objName.toLowerCase(), objName);
      }
    }

    // Identify custom objects explicitly referenced in the user message —
    // these get FULL field-level schema context so the LLM generates accurate SOQL.
    Set<String> prioritizedCustomObjects = new Set<String>();
    if (String.isNotBlank(userMessage)) {
      Matcher matcher = Pattern.compile('(?i)([A-Za-z][A-Za-z0-9_]*__c)').matcher(userMessage);
      while (matcher.find()) {
        String rawName = matcher.group(1);
        String normalized = rawName != null ? rawName.toLowerCase() : null;
        if (String.isNotBlank(normalized) && customObjByLower.containsKey(normalized)) {
          prioritizedCustomObjects.add(customObjByLower.get(normalized));
        }
      }
    }

    // Label-based resolution: match natural language against custom object labels
    // so "show me invoices" enriches Invoice__c even without the API name
    if (String.isNotBlank(userMessage) && prioritizedCustomObjects.size() < 5) {
      String msgLower = userMessage.toLowerCase();
      for (String objName : customObjByLower.values()) {
        if (prioritizedCustomObjects.size() >= 5) break;
        if (prioritizedCustomObjects.contains(objName)) continue;
        Schema.DescribeSObjectResult dsr = globalDescribe.get(objName.toLowerCase()).getDescribe();
        if (!dsr.isQueryable() || !dsr.isAccessible()) continue;
        String lbl = dsr.getLabel();
        String plr = dsr.getLabelPlural();
        if ((String.isNotBlank(lbl) && lbl.length() >= 4 && matchesWholeWord(msgLower, lbl.toLowerCase())) ||
            (String.isNotBlank(plr) && plr.length() >= 4 && matchesWholeWord(msgLower, plr.toLowerCase()))) {
          prioritizedCustomObjects.add(objName);
        }
      }
    }

    // For prioritized objects, include FULL field-level context via SchemaService
    for (String objName : prioritizedCustomObjects) {
      String richContext = AgentforceWorkspaceSchemaService.buildCustomObjectSchemaContext(objName);
      if (String.isNotBlank(richContext)) {
        parts.add(richContext);
      }
    }

    // Remaining custom objects get label-only listings (catalog for the LLM to reference)
    List<String> remainingCustomObjects = new List<String>();
    for (String objName : customObjByLower.values()) {
      if (!prioritizedCustomObjects.contains(objName)) {
        remainingCustomObjects.add(objName);
      }
    }
    remainingCustomObjects.sort();

    Integer customCount = prioritizedCustomObjects.size();
    Integer maxCustomObjectsInPrompt = 60;
    for (String objName : remainingCustomObjects) {
      if (customCount >= maxCustomObjectsInPrompt) break;
      Schema.DescribeSObjectResult describeResult = globalDescribe.get(objName).getDescribe();
      if (describeResult.isQueryable() && describeResult.isAccessible()) {
        parts.add('**' + objName + '** — ' + describeResult.getLabel() + '\n');
        customCount++;
      }
    }
    if (customCount == 0) {
      parts.add('No custom objects found.\n');
    }

    return String.join(parts, '');
  }

  // ═══════════════════════════════════════════════
  // SOQL Parsing & Validation (shared with AgentforceWorkspaceController)
  // ═══════════════════════════════════════════════

  /**
   * Parse LLM response and validate each SOQL query
   */
  @TestVisible
  public static List<QueryPlan> parseAndValidateSOQL(String llmResponse) {
    List<QueryPlan> plans = new List<QueryPlan>();

    if (String.isBlank(llmResponse)) {
      return plans;
    }

    // Strip markdown code blocks if present
    String cleaned = llmResponse.trim();
    if (cleaned.startsWith('```')) {
      Integer firstNewline = cleaned.indexOf('\n');
      if (firstNewline > 0) {
        cleaned = cleaned.substring(firstNewline + 1);
      }
      if (cleaned.endsWith('```')) {
        cleaned = cleaned.substring(0, cleaned.lastIndexOf('```'));
      }
      cleaned = cleaned.trim();
    }

    // Parse JSON
    try {
      Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(cleaned);
      List<Object> queries = (List<Object>) parsed.get('queries');

      if (queries == null || queries.isEmpty()) {
        return plans;
      }

      // Build set of all allowed objects (standard + custom)
      Set<String> allowedObjects = new Set<String>();
      for (String obj : STANDARD_BI_OBJECTS) {
        allowedObjects.add(obj.toLowerCase());
      }
      Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
      for (String objName : globalDescribe.keySet()) {
        if (objName.endsWith('__c')) {
          allowedObjects.add(objName.toLowerCase());
        }
      }

      for (Object q : queries) {
        Map<String, Object> queryMap = (Map<String, Object>) q;
        String purpose = (String) queryMap.get('purpose');
        String soql = (String) queryMap.get('soql');

        if (String.isBlank(soql)) {
          continue;
        }

        soql = soql.trim();
        String upperSoql = soql.toUpperCase();

        // Validate: must start with SELECT or FIND (SOSL)
        if (!upperSoql.startsWith('SELECT') && !upperSoql.startsWith('FIND')) {
          System.debug(LoggingLevel.WARN, 'Rejected non-SELECT/FIND query: ' + soql);
          continue;
        }

        String objectName = null;
        if (upperSoql.startsWith('FIND')) {
          // SOSL: FIND {...} RETURNING Incident(...) — extract object from RETURNING
          Integer returnIdx = upperSoql.indexOf(' RETURNING ');
          if (returnIdx < 0) {
            System.debug(LoggingLevel.WARN, 'Rejected SOSL without RETURNING: ' + soql);
            continue;
          }
          String afterReturning = soql.substring(returnIdx + 11).trim();
          objectName = afterReturning.split('[\\s(]')[0].trim();
        } else {
          // SOQL: extract FROM object
          Integer fromIndex = upperSoql.indexOf(' FROM ');
          if (fromIndex < 0) {
            System.debug(LoggingLevel.WARN, 'Rejected query without FROM: ' + soql);
            continue;
          }
          String afterFrom = soql.substring(fromIndex + 6).trim();
          objectName = afterFrom.split('\\s+')[0].trim();
        }
        objectName = objectName.replaceAll('[,\\(\\)]', '');

        if (!allowedObjects.contains(objectName.toLowerCase())) {
          System.debug(LoggingLevel.WARN, 'Rejected query for non-allowed object: ' + objectName);
          continue;
        }

        // SOSL: no further SOQL-specific validation
        if (upperSoql.startsWith('FIND')) {
          QueryPlan plan = new QueryPlan();
          plan.purpose = String.isNotBlank(purpose) ? purpose : 'Search';
          plan.soql = soql;
          plans.add(plan);
          continue;
        }

        // Semi-join + OR: Salesforce forbids OR between two IN (SELECT...) clauses.
        // If detected, try to split into two separate queries. If the split fails,
        // fall through and let the database engine validate — the OR may be between
        // simple conditions (e.g., a null check) which is perfectly valid SOQL.
        if (hasOrWithSubquery(upperSoql)) {
          List<String> splitQueries = splitOrWithSubquery(soql);
          if (!splitQueries.isEmpty()) {
            for (Integer j = 0; j < splitQueries.size(); j++) {
              QueryPlan splitPlan = new QueryPlan();
              splitPlan.purpose = String.isNotBlank(purpose) ? purpose + ' (part ' + (j + 1) + ')' : 'Query (part ' + (j + 1) + ')';
              splitPlan.soql = splitQueries[j];
              plans.add(splitPlan);
            }
            continue;
          }
          // Split failed — don't reject. Let the database engine decide validity.
          System.debug(LoggingLevel.INFO, 'OR+subquery detected but split failed — passing through to database: ' + soql);
        }

        // Check if this is an aggregate query without GROUP BY
        // (e.g., SELECT COUNT(Id) FROM ... — these cannot have LIMIT)
        Boolean isNonGroupedAggregate = hasAggregateFunction(upperSoql)
          && !upperSoql.contains(' GROUP BY ');

        if (isNonGroupedAggregate) {
          // Remove LIMIT if present — SOQL forbids LIMIT on non-grouped aggregates
          Pattern limitPattern = Pattern.compile('(?i)\\s+LIMIT\\s+\\d+');
          soql = limitPattern.matcher(soql).replaceAll('');
        } else if (!upperSoql.contains(' LIMIT ')) {
          // Non-aggregate query: enforce LIMIT if missing
          soql = soql + ' LIMIT ' + MAX_QUERY_LIMIT;
        } else {
          // Non-aggregate query with LIMIT: ensure it doesn't exceed max
          Pattern limitPattern = Pattern.compile('(?i)LIMIT\\s+(\\d+)');
          Matcher limitMatcher = limitPattern.matcher(soql);
          if (limitMatcher.find()) {
            Integer existingLimit = Integer.valueOf(limitMatcher.group(1));
            if (existingLimit > MAX_QUERY_LIMIT) {
              soql = soql.substring(0, limitMatcher.start()) + 'LIMIT ' + MAX_QUERY_LIMIT
                + soql.substring(limitMatcher.end());
            }
          }
        }

        QueryPlan plan = new QueryPlan();
        plan.purpose = String.isNotBlank(purpose) ? purpose : 'Query';
        plan.soql = soql;
        plans.add(plan);
      }
    } catch (Exception e) {
      System.debug(LoggingLevel.ERROR, 'Error parsing SOQL JSON: ' + e.getMessage());
      System.debug(LoggingLevel.ERROR, 'Raw LLM response: ' + llmResponse);
    }

    return plans;
  }

  /**
   * Split SOQL with OR+subquery into two valid queries. Returns empty list if split fails.
   */
  @TestVisible
  private static List<String> splitOrWithSubquery(String soql) {
    List<String> result = new List<String>();
    String upper = soql.toUpperCase();
    Integer inSelectIdx = upper.indexOf(' IN (SELECT');
    if (inSelectIdx < 0) {
      return result;
    }
    Integer openParen = upper.indexOf('(', inSelectIdx + 4);
    if (openParen < 0) {
      return result;
    }
    Integer closeParen = findMatchingCloseParen(soql, openParen);
    if (closeParen < 0 || closeParen >= soql.length() - 5) {
      return result;
    }
    String afterFirst = soql.substring(closeParen + 1).trim();
    if (!afterFirst.toUpperCase().startsWith('OR ')) {
      return result;
    }
    Integer secondInIdx = afterFirst.toUpperCase().indexOf(' IN (SELECT');
    if (secondInIdx < 0) {
      return result;
    }
    Integer secondOpen = afterFirst.indexOf('(', secondInIdx + 4);
    if (secondOpen < 0) {
      return result;
    }
    Integer secondClose = findMatchingCloseParen(afterFirst, secondOpen);
    if (secondClose < 0) {
      return result;
    }
    String afterSecond = afterFirst.substring(secondClose + 1).trim();
    String trailing = '';
    if (afterSecond.length() > 0) {
      trailing = ' ' + afterSecond;
    }
    Integer whereIdx = upper.indexOf(' WHERE ');
    if (whereIdx < 0) {
      return result;
    }
    String selectFromWhere = soql.substring(0, whereIdx + 7);
    String firstClause = soql.substring(whereIdx + 7, inSelectIdx).trim()
      + ' IN (' + soql.substring(openParen + 1, closeParen) + ')';
    String secondClause = afterFirst.substring(3, secondInIdx).trim()
      + ' IN (' + afterFirst.substring(secondOpen + 1, secondClose) + ')';
    String suffix = trailing;
    if (upper.startsWith('SELECT COUNT()')) {
      suffix = suffix.replaceAll('(?i)\\s+LIMIT\\s+\\d+', '');
    } else if (!upper.contains(' LIMIT ')) {
      suffix = suffix + ' LIMIT ' + MAX_QUERY_LIMIT;
    }
    result.add(selectFromWhere + firstClause + suffix);
    result.add(selectFromWhere + secondClause + suffix);
    return result;
  }

  private static Integer findMatchingCloseParen(String s, Integer openPos) {
    Integer depth = 1;
    for (Integer i = openPos + 1; i < s.length(); i++) {
      String c = s.substring(i, i + 1);
      if (c == '(') {
        depth++;
      } else if (c == ')') {
        depth--;
        if (depth == 0) {
          return i;
        }
      }
    }
    return -1;
  }

  /**
   * Check if SOQL uses OR *between two semi-join subselects* — SOQL forbids this.
   * Example of INVALID: ... Id IN (SELECT ...) OR Name IN (SELECT ...)
   * Example of VALID:   ... Id IN (SELECT ...) AND (Status = 'A' OR Status = 'B')
   *
   * Previous implementation was overly broad: any co-occurrence of IN (SELECT)
   * and OR anywhere in the string triggered rejection. This caused false positives
   * on common patterns like null-check ORs alongside subqueries.
   *
   * New approach: locate each semi-join block, then check whether the text
   * between two blocks contains a bare OR (not inside parentheses).
   */
  @TestVisible
  private static Boolean hasOrWithSubquery(String upperSoql) {
    if (!upperSoql.contains(' OR ') || !upperSoql.contains(' IN (SELECT')) {
      return false;
    }

    // Find the start positions of all semi-join expressions: IN (SELECT or NOT IN (SELECT
    List<Integer> semiJoinStarts = new List<Integer>();
    Integer searchFrom = 0;
    while (searchFrom < upperSoql.length()) {
      Integer idx = upperSoql.indexOf(' IN (SELECT', searchFrom);
      if (idx < 0) break;
      semiJoinStarts.add(idx);
      searchFrom = idx + 11;
    }

    // Need at least 2 semi-joins for the invalid pattern
    if (semiJoinStarts.size() < 2) return false;

    // For each consecutive pair of semi-joins, check if OR connects them
    for (Integer i = 0; i < semiJoinStarts.size() - 1; i++) {
      Integer firstStart = semiJoinStarts[i];
      // Find the close of the first subquery's parentheses
      Integer openParen = upperSoql.indexOf('(', firstStart + 4);
      if (openParen < 0) continue;
      Integer closeParen = findMatchingCloseParen(upperSoql, openParen);
      if (closeParen < 0) continue;

      // Text between end of first subquery and start of next semi-join
      Integer nextStart = semiJoinStarts[i + 1];
      if (closeParen >= nextStart) continue;
      String between = upperSoql.substring(closeParen + 1, nextStart).trim();

      // Check for bare OR at the top level (not nested in parens)
      if (containsBareOr(between)) return true;
    }

    return false;
  }

  /** Check if a string fragment contains a bare OR keyword not nested inside parentheses. */
  private static Boolean containsBareOr(String fragment) {
    Integer depth = 0;
    String upper = fragment.toUpperCase();
    for (Integer i = 0; i < upper.length(); i++) {
      String ch = upper.substring(i, i + 1);
      if (ch == '(') { depth++; continue; }
      if (ch == ')') { depth--; continue; }
      if (depth == 0 && i + 4 <= upper.length()) {
        // Check for word-bounded OR
        String slice = upper.substring(i, Math.min(i + 4, upper.length()));
        if (slice.startsWith('OR ') || slice.startsWith('OR)')) {
          Boolean leftBound = (i == 0)
            || upper.substring(i - 1, i) == ' '
            || upper.substring(i - 1, i) == ')';
          if (leftBound) return true;
        }
      }
    }
    return false;
  }

  /**
   * Check if a SOQL query (uppercased) uses aggregate functions
   */
  @TestVisible
  private static Boolean hasAggregateFunction(String upperSoql) {
    // Match aggregate functions: COUNT(...), COUNT(), SUM(...), AVG(...), MIN(...), MAX(...)
    return Pattern.compile('\\b(COUNT|SUM|AVG|MIN|MAX)\\s*\\(').matcher(upperSoql).find();
  }

  // ═══════════════════════════════════════════════
  // Query Execution (shared with AgentforceWorkspaceController)
  // ═══════════════════════════════════════════════

  /**
   * Execute validated SOQL queries as the running user
   */
  @TestVisible
  public static List<QueryExecution> executeQueries(List<QueryPlan> plans) {
    List<QueryExecution> executions = new List<QueryExecution>();

    for (QueryPlan plan : plans) {
      QueryExecution exec = new QueryExecution();
      exec.purpose = plan.purpose;
      exec.soql = plan.soql;

      try {
        String upperSoql = plan.soql.trim().toUpperCase();
        if (upperSoql.startsWith('FIND')) {
          // SOSL — searches Subject and Description (long text)
          List<List<SObject>> searchResults = Search.query(plan.soql, AccessLevel.USER_MODE);
          exec.results = searchResults.isEmpty() ? new List<SObject>() : searchResults[0];
          exec.countResult = null;
          exec.error = null;
          exec.limitReached = (exec.results.size() == MAX_QUERY_LIMIT);
        } else if (upperSoql.startsWith('SELECT COUNT()')) {
          Integer countResult = Database.countQuery(plan.soql, AccessLevel.USER_MODE);
          exec.results = new List<SObject>();
          exec.countResult = countResult;
          exec.error = null;
          exec.limitReached = false;
        } else {
          exec.results = Database.query(plan.soql, AccessLevel.USER_MODE);
          exec.countResult = null;
          exec.error = null;
          exec.limitReached = (exec.results.size() == MAX_QUERY_LIMIT);
        }
      } catch (Exception e) {
        System.debug(LoggingLevel.WARN, 'Query execution error: ' + e.getMessage() + ' | SOQL: ' + plan.soql);
        exec.results = new List<SObject>();
        exec.countResult = null;
        exec.error = e.getMessage();
        exec.limitReached = false;
      }

      executions.add(exec);
    }

    return executions;
  }

  // ═══════════════════════════════════════════════
  // Inner Classes
  // ═══════════════════════════════════════════════

  @JsonAccess(serializable='always' deserializable='always')
  global class BIRequest {
    @InvocableVariable(required=true label='User Query')
    global String userQuery;
  }

  @JsonAccess(serializable='always' deserializable='always')
  global class BIResult {
    @InvocableVariable(label='Chart Data')
    global AnalyticsChartResult chartData;
  }

  /** Word-boundary match: returns true if `word` appears as a standalone token in `text`. */
  @TestVisible
  private static Boolean matchesWholeWord(String text, String word) {
    if (String.isBlank(word) || word.length() < 4) return false;
    String safe = word.replace('\\', '\\\\').replace('.', '\\.').replace('(', '\\(')
                      .replace(')', '\\)').replace('[', '\\[').replace(']', '\\]')
                      .replace('{', '\\{').replace('}', '\\}').replace('*', '\\*')
                      .replace('+', '\\+').replace('?', '\\?').replace('^', '\\^')
                      .replace('$', '\\$').replace('|', '\\|');
    return Pattern.compile('\\b' + safe + '\\b').matcher(text).find();
  }

  @TestVisible
  public class QueryPlan {
    public String purpose;
    public String soql;
  }

  @TestVisible
  public class QueryExecution {
    public String purpose;
    public String soql;
    public List<SObject> results;
    public Integer countResult;  // For SELECT COUNT() queries
    public String error;
    public Boolean limitReached;
  }
}
