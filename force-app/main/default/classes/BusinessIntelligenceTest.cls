@isTest
public class BusinessIntelligenceTest {

  @TestSetup
  static void setupTestData() {
    Account testAccount = new Account(
      Name = 'BI Test Account',
      Industry = 'Technology',
      Type = 'Customer',
      AnnualRevenue = 500000,
      NumberOfEmployees = 100
    );
    insert testAccount;

    List<Opportunity> opps = new List<Opportunity>();
    opps.add(new Opportunity(
      Name = 'BI Test Opp - Closing Soon',
      AccountId = testAccount.Id,
      Amount = 75000,
      StageName = 'Negotiation/Review',
      CloseDate = Date.today().addDays(15),
      Probability = 80
    ));
    opps.add(new Opportunity(
      Name = 'BI Test Opp - Early Stage',
      AccountId = testAccount.Id,
      Amount = 30000,
      StageName = 'Prospecting',
      CloseDate = Date.today().addDays(60),
      Probability = 20
    ));
    insert opps;

    List<Case> cases = new List<Case>();
    cases.add(new Case(
      Subject = 'BI Test Case - Open',
      Status = 'New',
      Priority = 'High',
      AccountId = testAccount.Id
    ));
    cases.add(new Case(
      Subject = 'BI Test Case - Working',
      Status = 'Working',
      Priority = 'Medium',
      AccountId = testAccount.Id
    ));
    insert cases;

    Task testTask = new Task(
      Subject = 'Follow up with BI Test Account',
      WhatId = opps[0].Id,
      Status = 'Not Started',
      ActivityDate = Date.today().addDays(3),
      Priority = 'High'
    );
    insert testTask;
  }

  // ═══════════════════════════════════════════════
  // analyze() — top-level entry point
  // ═══════════════════════════════════════════════

  @isTest
  static void testAnalyze_ValidQuery() {
    BusinessIntelligence.BIRequest request = new BusinessIntelligence.BIRequest();
    request.userQuery = 'How many open opportunities do I have?';

    Test.startTest();
    List<BusinessIntelligence.BIResult> results = BusinessIntelligence.analyze(
      new List<BusinessIntelligence.BIRequest>{ request }
    );
    Test.stopTest();

    System.assertEquals(1, results.size(), 'Should return exactly one result');
    System.assertNotEquals(null, results[0].analysisResult, 'Analysis result should not be null');
  }

  @isTest
  static void testAnalyze_EmptyRequest() {
    Test.startTest();
    List<BusinessIntelligence.BIResult> results = BusinessIntelligence.analyze(
      new List<BusinessIntelligence.BIRequest>()
    );
    Test.stopTest();

    System.assertEquals(1, results.size());
    System.assert(results[0].analysisResult.contains('No query provided'));
  }

  @isTest
  static void testAnalyze_NullRequest() {
    Test.startTest();
    List<BusinessIntelligence.BIResult> results = BusinessIntelligence.analyze(null);
    Test.stopTest();

    System.assertEquals(1, results.size());
    System.assert(results[0].analysisResult.contains('No query provided'));
  }

  @isTest
  static void testAnalyze_BlankQuery() {
    BusinessIntelligence.BIRequest request = new BusinessIntelligence.BIRequest();
    request.userQuery = '';

    Test.startTest();
    List<BusinessIntelligence.BIResult> results = BusinessIntelligence.analyze(
      new List<BusinessIntelligence.BIRequest>{ request }
    );
    Test.stopTest();

    System.assertEquals(1, results.size());
    System.assert(results[0].analysisResult.contains('question is required'));
  }

  @isTest
  static void testAnalyze_NullQuery() {
    BusinessIntelligence.BIRequest request = new BusinessIntelligence.BIRequest();
    request.userQuery = null;

    Test.startTest();
    List<BusinessIntelligence.BIResult> results = BusinessIntelligence.analyze(
      new List<BusinessIntelligence.BIRequest>{ request }
    );
    Test.stopTest();

    System.assertEquals(1, results.size());
    System.assert(results[0].analysisResult.contains('question is required'));
  }

  // ═══════════════════════════════════════════════
  // buildSchemaContext()
  // ═══════════════════════════════════════════════

  @isTest
  static void testBuildSchemaContext() {
    Test.startTest();
    String context = BusinessIntelligence.buildSchemaContext();
    Test.stopTest();

    System.assert(context.contains('Account'), 'Should contain Account');
    System.assert(context.contains('Opportunity'), 'Should contain Opportunity');
    System.assert(context.contains('Case'), 'Should contain Case');
    System.assert(context.contains('Standard Objects'), 'Should contain standard header');
    System.assert(context.contains('Custom Objects'), 'Should contain custom header');
  }

  // ═══════════════════════════════════════════════
  // buildNLtoSOQLPrompt()
  // ═══════════════════════════════════════════════

  @isTest
  static void testBuildNLtoSOQLPrompt() {
    Test.startTest();
    String prompt = BusinessIntelligence.buildNLtoSOQLPrompt(
      'Show me my deals', '005000000000001', 'Test User', 'Schema context here'
    );
    Test.stopTest();

    System.assert(prompt.contains('Show me my deals'));
    System.assert(prompt.contains('Test User'));
    System.assert(prompt.contains('005000000000001'));
    System.assert(prompt.contains('SOQL expert'));
  }

  // ═══════════════════════════════════════════════
  // parseAndValidateSOQL()
  // ═══════════════════════════════════════════════

  @isTest
  static void testParseSOQL_ValidJson() {
    String json = '{"queries":[{"purpose":"Test query","soql":"SELECT Id, Name FROM Account LIMIT 10"}]}';

    Test.startTest();
    List<BusinessIntelligence.QueryPlan> plans = BusinessIntelligence.parseAndValidateSOQL(json);
    Test.stopTest();

    System.assertEquals(1, plans.size());
    System.assertEquals('Test query', plans[0].purpose);
    System.assert(plans[0].soql.contains('SELECT Id, Name FROM Account'));
  }

  @isTest
  static void testParseSOQL_MarkdownWrapped() {
    String json = '```json\n{"queries":[{"purpose":"Test","soql":"SELECT Id FROM Account LIMIT 5"}]}\n```';

    Test.startTest();
    List<BusinessIntelligence.QueryPlan> plans = BusinessIntelligence.parseAndValidateSOQL(json);
    Test.stopTest();

    System.assertEquals(1, plans.size());
  }

  @isTest
  static void testParseSOQL_BlankResponse() {
    Test.startTest();
    List<BusinessIntelligence.QueryPlan> plans = BusinessIntelligence.parseAndValidateSOQL('');
    Test.stopTest();

    System.assertEquals(0, plans.size());
  }

  @isTest
  static void testParseSOQL_NullResponse() {
    Test.startTest();
    List<BusinessIntelligence.QueryPlan> plans = BusinessIntelligence.parseAndValidateSOQL(null);
    Test.stopTest();

    System.assertEquals(0, plans.size());
  }

  @isTest
  static void testParseSOQL_InvalidJson() {
    Test.startTest();
    List<BusinessIntelligence.QueryPlan> plans = BusinessIntelligence.parseAndValidateSOQL('not valid json at all');
    Test.stopTest();

    System.assertEquals(0, plans.size());
  }

  @isTest
  static void testParseSOQL_NonSelectRejected() {
    String json = '{"queries":[{"purpose":"Delete","soql":"DELETE FROM Account LIMIT 1"}]}';

    Test.startTest();
    List<BusinessIntelligence.QueryPlan> plans = BusinessIntelligence.parseAndValidateSOQL(json);
    Test.stopTest();

    System.assertEquals(0, plans.size());
  }

  @isTest
  static void testParseSOQL_DisallowedObject() {
    String json = '{"queries":[{"purpose":"Query","soql":"SELECT Id FROM LoginHistory LIMIT 10"}]}';

    Test.startTest();
    List<BusinessIntelligence.QueryPlan> plans = BusinessIntelligence.parseAndValidateSOQL(json);
    Test.stopTest();

    System.assertEquals(0, plans.size());
  }

  @isTest
  static void testParseSOQL_OrWithSubquerySplitIntoTwo() {
    String json = '{"queries":[{"purpose":"ProblemIncident links","soql":"SELECT Id, IssueId, RelatedIssueId FROM ProblemIncident WHERE IssueId IN (SELECT Id FROM Incident WHERE CreatedDate = LAST_N_DAYS:60) OR RelatedIssueId IN (SELECT Id FROM Incident WHERE CreatedDate = LAST_N_DAYS:60) LIMIT 200"}]}';

    Test.startTest();
    List<BusinessIntelligence.QueryPlan> plans = BusinessIntelligence.parseAndValidateSOQL(json);
    Test.stopTest();

    System.assertEquals(2, plans.size(), 'OR with subquery should be split into 2 queries');
    System.assert(plans[0].soql.contains('IssueId IN (SELECT'), 'First query should have IssueId clause');
    System.assert(plans[1].soql.contains('RelatedIssueId IN (SELECT'), 'Second query should have RelatedIssueId clause');
    System.assert(!plans[0].soql.toUpperCase().contains(' OR '), 'Split queries should not contain OR');
  }

  @isTest
  static void testParseSOQL_SingleSubqueryAllowed() {
    String json = '{"queries":[{"purpose":"ProblemIncident by RelatedIssueId","soql":"SELECT Id, IssueId, RelatedIssueId FROM ProblemIncident WHERE RelatedIssueId IN (SELECT Id FROM Incident WHERE CreatedDate = LAST_N_MONTHS:2) LIMIT 50"}]}';

    Test.startTest();
    List<BusinessIntelligence.QueryPlan> plans = BusinessIntelligence.parseAndValidateSOQL(json);
    Test.stopTest();

    System.assertEquals(1, plans.size(), 'Single IN (SELECT...) without OR should be allowed');
  }

  @isTest
  static void testParseSOQL_AddsLimitWhenMissing() {
    String json = '{"queries":[{"purpose":"Test","soql":"SELECT Id, Name FROM Account"}]}';

    Test.startTest();
    List<BusinessIntelligence.QueryPlan> plans = BusinessIntelligence.parseAndValidateSOQL(json);
    Test.stopTest();

    System.assertEquals(1, plans.size());
    System.assert(plans[0].soql.contains('LIMIT 200'));
  }

  @isTest
  static void testParseSOQL_CapsExcessiveLimit() {
    String json = '{"queries":[{"purpose":"Test","soql":"SELECT Id FROM Account LIMIT 5000"}]}';

    Test.startTest();
    List<BusinessIntelligence.QueryPlan> plans = BusinessIntelligence.parseAndValidateSOQL(json);
    Test.stopTest();

    System.assertEquals(1, plans.size());
    System.assert(plans[0].soql.contains('LIMIT 200'));
  }

  @isTest
  static void testParseSOQL_RemovesLimitFromNonGroupedAggregate() {
    String json = '{"queries":[{"purpose":"Count","soql":"SELECT COUNT(Id) FROM Account LIMIT 200"}]}';

    Test.startTest();
    List<BusinessIntelligence.QueryPlan> plans = BusinessIntelligence.parseAndValidateSOQL(json);
    Test.stopTest();

    System.assertEquals(1, plans.size());
    System.assert(!plans[0].soql.toUpperCase().contains('LIMIT'));
  }

  @isTest
  static void testParseSOQL_GroupedAggregateKeepsLimit() {
    String json = '{"queries":[{"purpose":"By stage","soql":"SELECT StageName, SUM(Amount) FROM Opportunity GROUP BY StageName LIMIT 50"}]}';

    Test.startTest();
    List<BusinessIntelligence.QueryPlan> plans = BusinessIntelligence.parseAndValidateSOQL(json);
    Test.stopTest();

    System.assertEquals(1, plans.size());
    System.assert(plans[0].soql.contains('LIMIT'));
  }

  @isTest
  static void testParseSOQL_EmptyQueriesArray() {
    String json = '{"queries":[]}';

    Test.startTest();
    List<BusinessIntelligence.QueryPlan> plans = BusinessIntelligence.parseAndValidateSOQL(json);
    Test.stopTest();

    System.assertEquals(0, plans.size());
  }

  @isTest
  static void testParseSOQL_BlankSoql() {
    String json = '{"queries":[{"purpose":"Test","soql":""}]}';

    Test.startTest();
    List<BusinessIntelligence.QueryPlan> plans = BusinessIntelligence.parseAndValidateSOQL(json);
    Test.stopTest();

    System.assertEquals(0, plans.size());
  }

  @isTest
  static void testParseSOQL_NoFromClause() {
    String json = '{"queries":[{"purpose":"Test","soql":"SELECT 1"}]}';

    Test.startTest();
    List<BusinessIntelligence.QueryPlan> plans = BusinessIntelligence.parseAndValidateSOQL(json);
    Test.stopTest();

    System.assertEquals(0, plans.size());
  }

  @isTest
  static void testParseSOQL_NullPurpose() {
    String json = '{"queries":[{"soql":"SELECT Id FROM Account LIMIT 10"}]}';

    Test.startTest();
    List<BusinessIntelligence.QueryPlan> plans = BusinessIntelligence.parseAndValidateSOQL(json);
    Test.stopTest();

    System.assertEquals(1, plans.size());
    System.assertEquals('Query', plans[0].purpose);
  }

  @isTest
  static void testParseSOQL_MultipleQueries() {
    String json = '{"queries":[' +
      '{"purpose":"Count","soql":"SELECT COUNT() FROM Opportunity"},' +
      '{"purpose":"Details","soql":"SELECT Id, Name, Amount FROM Opportunity LIMIT 50"}' +
    ']}';

    Test.startTest();
    List<BusinessIntelligence.QueryPlan> plans = BusinessIntelligence.parseAndValidateSOQL(json);
    Test.stopTest();

    System.assertEquals(2, plans.size());
  }

  @isTest
  static void testParseSOQL_NonGroupedAggregateWithoutLimit() {
    String json = '{"queries":[{"purpose":"Count all","soql":"SELECT COUNT(Id) FROM Account"}]}';

    Test.startTest();
    List<BusinessIntelligence.QueryPlan> plans = BusinessIntelligence.parseAndValidateSOQL(json);
    Test.stopTest();

    System.assertEquals(1, plans.size());
    System.assert(!plans[0].soql.toUpperCase().contains('LIMIT'));
  }

  // ═══════════════════════════════════════════════
  // hasAggregateFunction()
  // ═══════════════════════════════════════════════

  @isTest
  static void testHasOrWithSubquery() {
    Test.startTest();
    System.assert(BusinessIntelligence.hasOrWithSubquery('SELECT ID FROM ProblemIncident WHERE IssueId IN (SELECT Id FROM Incident) OR RelatedIssueId IN (SELECT Id FROM Incident)'));
    System.assert(BusinessIntelligence.hasOrWithSubquery('SELECT ID FROM X WHERE A IN (SELECT Id FROM Y) OR B IN (SELECT Id FROM Z)'));
    System.assert(!BusinessIntelligence.hasOrWithSubquery('SELECT ID FROM ProblemIncident WHERE RelatedIssueId IN (SELECT Id FROM Incident WHERE CreatedDate = LAST_N_MONTHS:2)'));
    System.assert(!BusinessIntelligence.hasOrWithSubquery('SELECT ID FROM Account WHERE Name = \'Test\' OR Status = \'Active\''));
    Test.stopTest();
  }

  @isTest
  static void testHasAggregateFunction_AllTypes() {
    Test.startTest();
    System.assert(BusinessIntelligence.hasAggregateFunction('SELECT COUNT(ID) FROM ACCOUNT'));
    System.assert(BusinessIntelligence.hasAggregateFunction('SELECT SUM(AMOUNT) FROM OPPORTUNITY'));
    System.assert(BusinessIntelligence.hasAggregateFunction('SELECT AVG(AMOUNT) FROM OPPORTUNITY'));
    System.assert(BusinessIntelligence.hasAggregateFunction('SELECT MIN(AMOUNT) FROM OPPORTUNITY'));
    System.assert(BusinessIntelligence.hasAggregateFunction('SELECT MAX(AMOUNT) FROM OPPORTUNITY'));
    System.assert(BusinessIntelligence.hasAggregateFunction('SELECT COUNT() FROM ACCOUNT'));
    System.assert(!BusinessIntelligence.hasAggregateFunction('SELECT ID, NAME FROM ACCOUNT'));
    Test.stopTest();
  }

  // ═══════════════════════════════════════════════
  // executeQueries()
  // ═══════════════════════════════════════════════

  @isTest
  static void testExecuteQueries_ValidQuery() {
    BusinessIntelligence.QueryPlan plan = new BusinessIntelligence.QueryPlan();
    plan.purpose = 'Get accounts';
    plan.soql = 'SELECT Id, Name FROM Account LIMIT 10';

    Test.startTest();
    List<BusinessIntelligence.QueryExecution> executions = BusinessIntelligence.executeQueries(
      new List<BusinessIntelligence.QueryPlan>{ plan }
    );
    Test.stopTest();

    System.assertEquals(1, executions.size());
    System.assertEquals('Get accounts', executions[0].purpose);
    System.assertNotEquals(null, executions[0].results);
    System.assertEquals(null, executions[0].countResult);
    System.assertEquals(null, executions[0].error);
  }

  @isTest
  static void testExecuteQueries_CountQuery() {
    BusinessIntelligence.QueryPlan plan = new BusinessIntelligence.QueryPlan();
    plan.purpose = 'Count accounts';
    plan.soql = 'SELECT COUNT() FROM Account';

    Test.startTest();
    List<BusinessIntelligence.QueryExecution> executions = BusinessIntelligence.executeQueries(
      new List<BusinessIntelligence.QueryPlan>{ plan }
    );
    Test.stopTest();

    System.assertEquals(1, executions.size());
    System.assertNotEquals(null, executions[0].countResult);
    System.assertEquals(null, executions[0].error);
    System.assertEquals(false, executions[0].limitReached);
  }

  @isTest
  static void testExecuteQueries_InvalidQuery() {
    BusinessIntelligence.QueryPlan plan = new BusinessIntelligence.QueryPlan();
    plan.purpose = 'Invalid query';
    plan.soql = 'SELECT InvalidField__xyz FROM Account LIMIT 10';

    Test.startTest();
    List<BusinessIntelligence.QueryExecution> executions = BusinessIntelligence.executeQueries(
      new List<BusinessIntelligence.QueryPlan>{ plan }
    );
    Test.stopTest();

    System.assertEquals(1, executions.size());
    System.assertNotEquals(null, executions[0].error);
    System.assertEquals(false, executions[0].limitReached);
  }

  @isTest
  static void testExecuteQueries_MultipleQueries() {
    List<BusinessIntelligence.QueryPlan> plans = new List<BusinessIntelligence.QueryPlan>();

    BusinessIntelligence.QueryPlan countPlan = new BusinessIntelligence.QueryPlan();
    countPlan.purpose = 'Count opps';
    countPlan.soql = 'SELECT COUNT() FROM Opportunity';
    plans.add(countPlan);

    BusinessIntelligence.QueryPlan detailPlan = new BusinessIntelligence.QueryPlan();
    detailPlan.purpose = 'Detail opps';
    detailPlan.soql = 'SELECT Id, Name, Amount FROM Opportunity LIMIT 50';
    plans.add(detailPlan);

    Test.startTest();
    List<BusinessIntelligence.QueryExecution> executions = BusinessIntelligence.executeQueries(plans);
    Test.stopTest();

    System.assertEquals(2, executions.size());
  }

  // ═══════════════════════════════════════════════
  // buildAnalysisPrompt()
  // ═══════════════════════════════════════════════

  @isTest
  static void testBuildAnalysisPrompt_WithResults() {
    BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
    exec.purpose = 'Get accounts';
    exec.soql = 'SELECT Id, Name, Industry FROM Account LIMIT 10';
    exec.results = [SELECT Id, Name, Industry FROM Account LIMIT 10];
    exec.countResult = null;
    exec.error = null;
    exec.limitReached = false;

    Test.startTest();
    String prompt = BusinessIntelligence.buildAnalysisPrompt(
      'Show me my accounts', 'Test User',
      new List<BusinessIntelligence.QueryExecution>{ exec }
    );
    Test.stopTest();

    System.assert(prompt.contains('Show me my accounts'));
    System.assert(prompt.contains('Get accounts'));
    System.assert(prompt.contains('Key Findings'));
    System.assert(prompt.contains('Recommendations'));
  }

  @isTest
  static void testBuildAnalysisPrompt_WithRelationshipFields() {
    BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
    exec.purpose = 'Opps with accounts';
    exec.soql = 'SELECT Id, Name, Account.Name FROM Opportunity LIMIT 10';
    exec.results = [SELECT Id, Name, Account.Name FROM Opportunity LIMIT 10];
    exec.countResult = null;
    exec.error = null;
    exec.limitReached = false;

    Test.startTest();
    String prompt = BusinessIntelligence.buildAnalysisPrompt(
      'Show me opportunities with account names', 'Test User',
      new List<BusinessIntelligence.QueryExecution>{ exec }
    );
    Test.stopTest();

    System.assert(prompt.length() > 0);
    System.assert(prompt.contains('Opps with accounts'));
  }

  @isTest
  static void testBuildAnalysisPrompt_EmptyResults() {
    BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
    exec.purpose = 'Get leads';
    exec.soql = 'SELECT Id FROM Lead LIMIT 10';
    exec.results = new List<SObject>();
    exec.countResult = null;
    exec.error = null;
    exec.limitReached = false;

    Test.startTest();
    String prompt = BusinessIntelligence.buildAnalysisPrompt(
      'Show me leads', 'Test User',
      new List<BusinessIntelligence.QueryExecution>{ exec }
    );
    Test.stopTest();

    System.assert(prompt.contains('No records found'));
  }

  @isTest
  static void testBuildAnalysisPrompt_WithError() {
    BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
    exec.purpose = 'Bad query';
    exec.soql = 'SELECT Invalid FROM Account';
    exec.results = new List<SObject>();
    exec.countResult = null;
    exec.error = 'Invalid field: Invalid';
    exec.limitReached = false;

    Test.startTest();
    String prompt = BusinessIntelligence.buildAnalysisPrompt(
      'Show me stuff', 'Test User',
      new List<BusinessIntelligence.QueryExecution>{ exec }
    );
    Test.stopTest();

    System.assert(prompt.contains('Invalid field'));
  }

  @isTest
  static void testBuildAnalysisPrompt_WithCountResult() {
    BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
    exec.purpose = 'Count accounts';
    exec.soql = 'SELECT COUNT() FROM Account';
    exec.results = new List<SObject>();
    exec.countResult = 5;
    exec.error = null;
    exec.limitReached = false;

    Test.startTest();
    String prompt = BusinessIntelligence.buildAnalysisPrompt(
      'How many accounts?', 'Test User',
      new List<BusinessIntelligence.QueryExecution>{ exec }
    );
    Test.stopTest();

    System.assert(prompt.contains('Total Count'));
  }

  @isTest
  static void testBuildAnalysisPrompt_LimitReached() {
    BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
    exec.purpose = 'Get many accounts';
    exec.soql = 'SELECT Id, Name FROM Account LIMIT 200';
    exec.results = [SELECT Id, Name FROM Account LIMIT 10];
    exec.countResult = null;
    exec.error = null;
    exec.limitReached = true;

    Test.startTest();
    String prompt = BusinessIntelligence.buildAnalysisPrompt(
      'Show me all accounts', 'Test User',
      new List<BusinessIntelligence.QueryExecution>{ exec }
    );
    Test.stopTest();

    System.assert(prompt.contains('display cap reached'));
  }

  @isTest
  static void testBuildAnalysisPrompt_NoResultsAtAll() {
    BusinessIntelligence.QueryExecution emptyExec = new BusinessIntelligence.QueryExecution();
    emptyExec.purpose = 'Empty search';
    emptyExec.soql = 'SELECT Id FROM Lead LIMIT 10';
    emptyExec.results = new List<SObject>();
    emptyExec.countResult = null;
    emptyExec.error = null;
    emptyExec.limitReached = false;

    BusinessIntelligence.QueryExecution errorExec = new BusinessIntelligence.QueryExecution();
    errorExec.purpose = 'Error query';
    errorExec.soql = 'SELECT BadField FROM Account';
    errorExec.results = new List<SObject>();
    errorExec.countResult = null;
    errorExec.error = 'Some error';
    errorExec.limitReached = false;

    Test.startTest();
    String prompt = BusinessIntelligence.buildAnalysisPrompt(
      'Find something', 'Test User',
      new List<BusinessIntelligence.QueryExecution>{ emptyExec, errorExec }
    );
    Test.stopTest();

    System.assert(prompt.contains('no matching data was found'));
  }

  @isTest
  static void testBuildAnalysisPrompt_MixedResults() {
    List<BusinessIntelligence.QueryExecution> executions = new List<BusinessIntelligence.QueryExecution>();

    BusinessIntelligence.QueryExecution countExec = new BusinessIntelligence.QueryExecution();
    countExec.purpose = 'Count accounts';
    countExec.soql = 'SELECT COUNT() FROM Account';
    countExec.results = new List<SObject>();
    countExec.countResult = 1;
    countExec.error = null;
    countExec.limitReached = false;
    executions.add(countExec);

    BusinessIntelligence.QueryExecution detailExec = new BusinessIntelligence.QueryExecution();
    detailExec.purpose = 'Account details';
    detailExec.soql = 'SELECT Id, Name, Industry FROM Account LIMIT 200';
    detailExec.results = [SELECT Id, Name, Industry FROM Account LIMIT 200];
    detailExec.countResult = null;
    detailExec.error = null;
    detailExec.limitReached = false;
    executions.add(detailExec);

    BusinessIntelligence.QueryExecution errorExec = new BusinessIntelligence.QueryExecution();
    errorExec.purpose = 'Failed query';
    errorExec.soql = 'SELECT BadField FROM Account';
    errorExec.results = new List<SObject>();
    errorExec.countResult = null;
    errorExec.error = 'Field not found';
    errorExec.limitReached = false;
    executions.add(errorExec);

    Test.startTest();
    String prompt = BusinessIntelligence.buildAnalysisPrompt(
      'Tell me about my accounts', 'Test User', executions
    );
    Test.stopTest();

    System.assert(prompt.contains('Total Count'));
    System.assert(prompt.contains('Account details'));
    System.assert(prompt.contains('Field not found'));
    System.assert(prompt.contains('Key Findings'));
  }
}
