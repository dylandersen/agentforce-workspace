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
    System.assertNotEquals(null, results[0].chartData, 'Chart data should not be null');
    System.assertNotEquals(null, results[0].chartData.analysisHtml, 'Analysis HTML should not be null');
  }

  @isTest
  static void testAnalyze_EmptyRequest() {
    Test.startTest();
    List<BusinessIntelligence.BIResult> results = BusinessIntelligence.analyze(
      new List<BusinessIntelligence.BIRequest>()
    );
    Test.stopTest();

    System.assertEquals(1, results.size());
    System.assert(results[0].chartData.analysisHtml.contains('No query provided'));
  }

  @isTest
  static void testAnalyze_NullRequest() {
    Test.startTest();
    List<BusinessIntelligence.BIResult> results = BusinessIntelligence.analyze(null);
    Test.stopTest();

    System.assertEquals(1, results.size());
    System.assert(results[0].chartData.analysisHtml.contains('No query provided'));
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
    System.assert(results[0].chartData.analysisHtml.contains('question is required'));
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
    System.assert(results[0].chartData.analysisHtml.contains('question is required'));
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
  // hasOrWithSubquery() / hasAggregateFunction()
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
  // cleanResponseForAgent()
  // ═══════════════════════════════════════════════

  @isTest
  static void testCleanResponseForAgent_StripsSuggestionsAndChart() {
    String input = '<h1>Pipeline Summary</h1><p>You have <b>5</b> open deals.</p>'
        + '<CHART>{"chartType":"bar","title":"By Stage","items":[{"label":"Prospecting","value":2}]}</CHART>'
        + '<SUGGESTIONS>["Show deals closing this month","Break down by rep"]</SUGGESTIONS>';

    Test.startTest();
    String result = BusinessIntelligence.cleanResponseForAgent(input);
    Test.stopTest();

    System.assert(result.contains('Pipeline Summary'), 'Should keep HTML content');
    System.assert(!result.contains('<CHART>'), 'Should strip CHART block');
    System.assert(!result.contains('<SUGGESTIONS>'), 'Should strip SUGGESTIONS block');
    System.assert(!result.contains('chartType'), 'Should strip chart JSON');
  }

  @isTest
  static void testCleanResponseForAgent_ConvertsEmailDraft() {
    String input = '<p>Here\'s a draft:</p>'
        + '<EMAIL_DRAFT>{"toName":"Jane Doe","toAddress":"jane@acme.com","subject":"Follow Up","body":"Hi Jane,\\n\\nThanks for the call.\\n\\nBest,\\nDylan"}</EMAIL_DRAFT>'
        + '<SUGGESTIONS>["Send it","Edit the draft"]</SUGGESTIONS>';

    Test.startTest();
    String result = BusinessIntelligence.cleanResponseForAgent(input);
    Test.stopTest();

    System.assert(result.contains('Draft Email'), 'Should convert EMAIL_DRAFT to HTML heading');
    System.assert(result.contains('Jane Doe'), 'Should include recipient name');
    System.assert(result.contains('jane@acme.com'), 'Should include email address');
    System.assert(result.contains('Follow Up'), 'Should include subject');
    System.assert(!result.contains('<EMAIL_DRAFT>'), 'Should strip EMAIL_DRAFT tags');
    System.assert(!result.contains('<SUGGESTIONS>'), 'Should strip SUGGESTIONS');
  }

  @isTest
  static void testCleanResponseForAgent_PlainHtml() {
    String input = '<h1>Results</h1><p>Here are your accounts.</p>';

    Test.startTest();
    String result = BusinessIntelligence.cleanResponseForAgent(input);
    Test.stopTest();

    System.assertEquals(input, result, 'Plain HTML should pass through unchanged');
  }

  @isTest
  static void testCleanResponseForAgent_PreservesRecordLinks() {
    String input = '<p>Top account: <a href="/lightning/r/Account/001xx/view"><b>Acme Corp</b></a> with '
        + '<a href="/lightning/r/Opportunity/006xx/view"><b>Big Deal</b></a>.</p>';

    Test.startTest();
    String result = BusinessIntelligence.cleanResponseForAgent(input);
    Test.stopTest();

    System.assert(result.contains('<a href="/lightning/r/Account/001xx/view">'), 'Should preserve Account link');
    System.assert(result.contains('<a href="/lightning/r/Opportunity/006xx/view">'), 'Should preserve Opportunity link');
    System.assert(result.contains('<b>Acme Corp</b>'), 'Should keep bold record name');
    System.assert(result.contains('<b>Big Deal</b>'), 'Should keep bold opportunity name');
  }

  @isTest
  static void testCleanResponseForAgent_BlankInput() {
    Test.startTest();
    String result = BusinessIntelligence.cleanResponseForAgent('');
    Test.stopTest();

    System.assertEquals('', result);
  }
}
