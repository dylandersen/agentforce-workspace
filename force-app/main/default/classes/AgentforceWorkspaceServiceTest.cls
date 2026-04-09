@isTest
public class AgentforceWorkspaceServiceTest {

    @TestSetup
    static void setupTestData() {
        Account testAccount = new Account(
            Name = 'Workspace Test Account',
            Industry = 'Technology',
            Type = 'Customer - Direct',
            Phone = '555-1234'
        );
        Account testAccount2 = new Account(
            Name = 'Workspace Test Account Two',
            Industry = 'Finance',
            Type = 'Prospect',
            Phone = '555-4321'
        );
        insert new List<Account>{ testAccount, testAccount2 };

        Contact testContact = new Contact(
            FirstName = 'Workspace',
            LastName = 'TestContact',
            AccountId = testAccount.Id,
            Email = 'workspace@test.com',
            Phone = '555-5678',
            Title = 'VP Sales'
        );
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.allowSave = true;
        Database.insert(testContact, dml);

        Opportunity testOpp = new Opportunity(
            Name = 'Workspace Test Opp',
            AccountId = testAccount.Id,
            Amount = 50000,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        Opportunity testOpp2 = new Opportunity(
            Name = 'Workspace Test Opp Two',
            AccountId = testAccount2.Id,
            Amount = 75000,
            StageName = 'Qualification',
            CloseDate = Date.today().addDays(60)
        );
        insert new List<Opportunity>{ testOpp, testOpp2 };

        // OpportunityContactRole for supplementary query testing
        OpportunityContactRole ocr = new OpportunityContactRole(
            OpportunityId = testOpp.Id,
            ContactId = testContact.Id,
            Role = 'Decision Maker',
            IsPrimary = true
        );
        insert ocr;

        Task testTask = new Task(
            Subject = 'Workspace Test Task',
            Status = 'Not Started',
            ActivityDate = Date.today().addDays(3),
            WhatId = testAccount.Id
        );
        insert testTask;

        Event testEvent = new Event(
            Subject = 'Workspace Test Event',
            StartDateTime = Datetime.now().addDays(1),
            EndDateTime = Datetime.now().addDays(1).addHours(1),
            WhatId = testAccount.Id
        );
        insert testEvent;
    }

    // ═══════════════════════════════════════════════
    //  QueryService — formatFieldValue
    // ═══════════════════════════════════════════════

    @isTest
    static void testFormatFieldValue_Currency() {
        System.assertEquals('$50,000', AgentforceWorkspaceQueryService.formatFieldValue(50000.0, 'CURRENCY'));
    }

    @isTest
    static void testFormatFieldValue_Percent() {
        System.assertEquals('75.5%', AgentforceWorkspaceQueryService.formatFieldValue(75.5, 'PERCENT'));
    }

    @isTest
    static void testFormatFieldValue_Decimal() {
        String result = AgentforceWorkspaceQueryService.formatFieldValue(1234.56, 'DOUBLE');
        System.assert(result.contains('1,234') || result.contains('1234'));
    }

    @isTest
    static void testFormatFieldValue_Date() {
        String result = AgentforceWorkspaceQueryService.formatFieldValue(Date.today(), 'DATE');
        System.assert(String.isNotBlank(result));
    }

    @isTest
    static void testFormatFieldValue_Datetime() {
        String result = AgentforceWorkspaceQueryService.formatFieldValue(Datetime.now(), 'DATETIME');
        System.assert(String.isNotBlank(result));
    }

    @isTest
    static void testFormatFieldValue_Boolean() {
        System.assertEquals('Yes', AgentforceWorkspaceQueryService.formatFieldValue(true, 'BOOLEAN'));
        System.assertEquals('No', AgentforceWorkspaceQueryService.formatFieldValue(false, 'BOOLEAN'));
    }

    @isTest
    static void testFormatFieldValue_String() {
        System.assertEquals('Hello', AgentforceWorkspaceQueryService.formatFieldValue('Hello', 'STRING'));
    }

    @isTest
    static void testFormatFieldValue_Null() {
        System.assertEquals('', AgentforceWorkspaceQueryService.formatFieldValue(null, 'STRING'));
    }

    // ═══════════════════════════════════════════════
    //  QueryService — collectAllOppIds
    // ═══════════════════════════════════════════════

    @isTest
    static void testCollectAllOppIds_WithOpps() {
        List<Opportunity> opps = [SELECT Id FROM Opportunity LIMIT 5];
        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.purpose = 'Opps';
        exec.soql = 'SELECT Id FROM Opportunity LIMIT 5';
        exec.results = opps;

        Set<Id> ids = AgentforceWorkspaceQueryService.collectAllOppIds(
            new List<BusinessIntelligence.QueryExecution>{ exec }
        );
        System.assertEquals(opps.size(), ids.size());
    }

    @isTest
    static void testCollectAllOppIds_WithErrors() {
        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.purpose = 'Bad';
        exec.soql = 'SELECT Id FROM Opportunity';
        exec.error = 'fail';

        Set<Id> ids = AgentforceWorkspaceQueryService.collectAllOppIds(
            new List<BusinessIntelligence.QueryExecution>{ exec }
        );
        System.assertEquals(0, ids.size());
    }

    @isTest
    static void testCollectAllOppIds_WithCount() {
        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.purpose = 'Count';
        exec.soql = 'SELECT COUNT() FROM Opportunity';
        exec.countResult = 5;
        exec.results = [SELECT Id FROM Opportunity LIMIT 5];

        Set<Id> ids = AgentforceWorkspaceQueryService.collectAllOppIds(
            new List<BusinessIntelligence.QueryExecution>{ exec }
        );
        System.assertEquals(0, ids.size(), 'Count queries should be skipped');
    }

    // ═══════════════════════════════════════════════
    //  QueryService — lookupOppAccounts
    // ═══════════════════════════════════════════════

    @isTest
    static void testLookupOppAccounts_Empty() {
        Map<Id, Opportunity> result = AgentforceWorkspaceQueryService.lookupOppAccounts(new Set<Id>());
        System.assertEquals(0, result.size());
    }

    @isTest
    static void testLookupOppAccounts_WithIds() {
        Opportunity opp = [SELECT Id FROM Opportunity LIMIT 1];
        Map<Id, Opportunity> result = AgentforceWorkspaceQueryService.lookupOppAccounts(new Set<Id>{ opp.Id });
        System.assertEquals(1, result.size());
        System.assertNotEquals(null, result.get(opp.Id).Account.Name);
    }

    // ═══════════════════════════════════════════════
    //  QueryService — findObjectsWithRecords
    // ═══════════════════════════════════════════════

    @isTest
    static void testFindObjectsWithRecords() {
        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.purpose = 'Accounts';
        exec.soql = 'SELECT Id, Name FROM Account LIMIT 5';
        exec.results = [SELECT Id, Name FROM Account LIMIT 5];

        Set<String> objects = AgentforceWorkspaceQueryService.findObjectsWithRecords(
            new List<BusinessIntelligence.QueryExecution>{ exec }
        );
        System.assert(objects.contains('Account'));
    }

    // ═══════════════════════════════════════════════
    //  QueryService — formatQueryResults
    // ═══════════════════════════════════════════════

    @isTest
    static void testFormatQueryResults_NormalResults() {
        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.purpose = 'Get accounts';
        exec.soql = 'SELECT Id, Name FROM Account LIMIT 5';
        exec.results = [SELECT Id, Name FROM Account LIMIT 5];
        exec.limitReached = false;

        String result = AgentforceWorkspaceQueryService.formatQueryResults(
            new List<BusinessIntelligence.QueryExecution>{ exec }
        );
        System.assert(result.contains('Get accounts'));
        System.assert(result.contains('record(s)'));
    }

    @isTest
    static void testFormatQueryResults_Error() {
        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.purpose = 'Bad query';
        exec.soql = 'SELECT Bad FROM Account';
        exec.error = 'Field not found';

        String result = AgentforceWorkspaceQueryService.formatQueryResults(
            new List<BusinessIntelligence.QueryExecution>{ exec }
        );
        System.assert(result.contains('Field not found'));
    }

    @isTest
    static void testFormatQueryResults_Count() {
        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.purpose = 'Count';
        exec.soql = 'SELECT COUNT() FROM Account';
        exec.countResult = 42;

        String result = AgentforceWorkspaceQueryService.formatQueryResults(
            new List<BusinessIntelligence.QueryExecution>{ exec }
        );
        System.assert(result.contains('Total Count'));
        System.assert(result.contains('42'));
    }

    @isTest
    static void testFormatQueryResults_Empty() {
        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.purpose = 'Empty';
        exec.soql = 'SELECT Id FROM Lead LIMIT 5';
        exec.results = new List<SObject>();

        String result = AgentforceWorkspaceQueryService.formatQueryResults(
            new List<BusinessIntelligence.QueryExecution>{ exec }
        );
        System.assert(result.contains('No records found'));
    }

    @isTest
    static void testFormatQueryResults_LimitReached() {
        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.purpose = 'Capped';
        exec.soql = 'SELECT Id FROM Account LIMIT 200';
        exec.results = [SELECT Id FROM Account LIMIT 5];
        exec.limitReached = true;

        String result = AgentforceWorkspaceQueryService.formatQueryResults(
            new List<BusinessIntelligence.QueryExecution>{ exec }
        );
        System.assert(result.contains('display cap reached'));
    }

    @isTest
    static void testFormatQueryResults_WithRelationship() {
        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.purpose = 'Opps with accounts';
        exec.soql = 'SELECT Id, Name, Account.Name FROM Opportunity LIMIT 5';
        exec.results = [SELECT Id, Name, Account.Name FROM Opportunity LIMIT 5];
        exec.limitReached = false;

        String result = AgentforceWorkspaceQueryService.formatQueryResults(
            new List<BusinessIntelligence.QueryExecution>{ exec }
        );
        System.assert(result.contains('Account.'));
    }

    // ═══════════════════════════════════════════════
    //  QueryService — checkHasAnyResults
    // ═══════════════════════════════════════════════

    @isTest
    static void testCheckHasAnyResults_WithResults() {
        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.results = [SELECT Id FROM Account LIMIT 1];
        System.assert(AgentforceWorkspaceQueryService.checkHasAnyResults(
            new List<BusinessIntelligence.QueryExecution>{ exec }
        ));
    }

    @isTest
    static void testCheckHasAnyResults_WithCount() {
        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.countResult = 5;
        System.assert(AgentforceWorkspaceQueryService.checkHasAnyResults(
            new List<BusinessIntelligence.QueryExecution>{ exec }
        ));
    }

    @isTest
    static void testCheckHasAnyResults_Empty() {
        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.results = new List<SObject>();
        System.assert(!AgentforceWorkspaceQueryService.checkHasAnyResults(
            new List<BusinessIntelligence.QueryExecution>{ exec }
        ));
    }

    @isTest
    static void testCheckHasAnyResults_ErrorOnly() {
        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.error = 'fail';
        System.assert(!AgentforceWorkspaceQueryService.checkHasAnyResults(
            new List<BusinessIntelligence.QueryExecution>{ exec }
        ));
    }

    // ═══════════════════════════════════════════════
    //  QueryService — buildRecordTabs
    // ═══════════════════════════════════════════════

    @isTest
    static void testBuildRecordTabs_WithAccounts() {
        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.purpose = 'Accounts';
        exec.soql = 'SELECT Id, Name, Industry, Phone FROM Account ORDER BY Name LIMIT 200';
        exec.results = [SELECT Id, Name, Industry, Phone FROM Account LIMIT 5];

        List<AgentforceWorkspaceModels.RecordTab> tabs = AgentforceWorkspaceQueryService.buildRecordTabs(
            new List<BusinessIntelligence.QueryExecution>{ exec },
            new Map<Id, Opportunity>(),
            new Map<String, List<SObject>>()
        );
        System.assert(!tabs.isEmpty());
        System.assertEquals('Account', tabs[0].objectApiName);
        System.assert(!tabs[0].columns.isEmpty());
        System.assert(!tabs[0].rows.isEmpty());
    }

    @isTest
    static void testBuildRecordTabs_WithOpportunitiesAndAccounts() {
        Opportunity opp = [SELECT Id, Name, Amount, StageName, CloseDate, AccountId FROM Opportunity LIMIT 1];
        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.purpose = 'Opps';
        exec.soql = 'SELECT Id, Name, Amount, StageName, CloseDate FROM Opportunity ORDER BY CloseDate DESC LIMIT 200';
        exec.results = new List<SObject>{ opp };

        Map<Id, Opportunity> oppAccountMap = AgentforceWorkspaceQueryService.lookupOppAccounts(new Set<Id>{ opp.Id });

        List<AgentforceWorkspaceModels.RecordTab> tabs = AgentforceWorkspaceQueryService.buildRecordTabs(
            new List<BusinessIntelligence.QueryExecution>{ exec },
            oppAccountMap,
            new Map<String, List<SObject>>()
        );
        System.assert(!tabs.isEmpty());
        System.assertEquals('Opportunity', tabs[0].objectApiName);
    }

    @isTest
    static void testBuildRecordTabs_WithCountAndSupplementary() {
        BusinessIntelligence.QueryExecution countExec = new BusinessIntelligence.QueryExecution();
        countExec.purpose = 'Count accounts';
        countExec.soql = 'SELECT COUNT() FROM Account';
        countExec.countResult = 1;
        countExec.results = new List<SObject>();

        Map<String, List<SObject>> supplementary = new Map<String, List<SObject>>();
        supplementary.put('Account', [SELECT Id, Name, Industry, Type, Phone FROM Account LIMIT 5]);

        List<AgentforceWorkspaceModels.RecordTab> tabs = AgentforceWorkspaceQueryService.buildRecordTabs(
            new List<BusinessIntelligence.QueryExecution>{ countExec },
            new Map<Id, Opportunity>(),
            supplementary
        );
        System.assert(!tabs.isEmpty());
        System.assertNotEquals(null, tabs[0].totalCount);
    }

    @isTest
    static void testBuildRecordTabs_Empty() {
        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.error = 'fail';

        List<AgentforceWorkspaceModels.RecordTab> tabs = AgentforceWorkspaceQueryService.buildRecordTabs(
            new List<BusinessIntelligence.QueryExecution>{ exec },
            new Map<Id, Opportunity>(),
            new Map<String, List<SObject>>()
        );
        System.assertEquals(0, tabs.size());
    }

    // ═══════════════════════════════════════════════
    //  QueryService — runSupplementaryQueries
    // ═══════════════════════════════════════════════

    @isTest
    static void testRunSupplementaryQueries_AggregateOnly() {
        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.purpose = 'Grouped';
        exec.soql = 'SELECT StageName, COUNT(Id) FROM Opportunity GROUP BY StageName LIMIT 10';
        exec.results = new List<SObject>();
        exec.countResult = null;

        Set<String> objectsWithRecords = new Set<String>();
        Map<String, List<SObject>> result = AgentforceWorkspaceQueryService.runSupplementaryQueries(
            new List<BusinessIntelligence.QueryExecution>{ exec },
            objectsWithRecords
        );
        // Should attempt supplementary query for Opportunity
        // May or may not have results depending on test data
        System.assertNotEquals(null, result);
    }

    @isTest
    static void testRunSupplementaryQueries_EventWithAccountWhatId() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Event testEvt = new Event(
            Subject = 'Supp Query Test',
            StartDateTime = Datetime.now().addDays(1),
            EndDateTime = Datetime.now().addDays(1).addHours(1),
            WhatId = acc.Id
        );
        insert testEvt;

        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.purpose = 'Events';
        exec.soql = 'SELECT Id, Subject, WhatId FROM Event LIMIT 10';
        exec.results = [SELECT Id, Subject, WhatId FROM Event WHERE Id = :testEvt.Id];
        exec.limitReached = false;

        Set<String> objectsWithRecords = new Set<String>{ 'Event' };
        Map<String, List<SObject>> result = AgentforceWorkspaceQueryService.runSupplementaryQueries(
            new List<BusinessIntelligence.QueryExecution>{ exec },
            objectsWithRecords
        );
        // Should have supplementary Account records from Event WhatId
        System.assert(result.containsKey('Account'), 'Should have supplementary Account records');
    }

    @isTest
    static void testBuildRecordTabs_OppsWithAccountRelationship() {
        // Test Opportunity records that include Account.Name relationship field
        List<Opportunity> opps = [SELECT Id, Name, Amount, StageName, CloseDate, Account.Name, AccountId FROM Opportunity LIMIT 5];
        if (opps.isEmpty()) return;

        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.purpose = 'Opps with Account';
        exec.soql = 'SELECT Id, Name, Amount, StageName, CloseDate, Account.Name FROM Opportunity ORDER BY Amount DESC LIMIT 200';
        exec.results = opps;
        exec.limitReached = false;

        Set<Id> oppIds = new Set<Id>();
        for (Opportunity o : opps) oppIds.add(o.Id);
        Map<Id, Opportunity> oppAccountMap = AgentforceWorkspaceQueryService.lookupOppAccounts(oppIds);

        List<AgentforceWorkspaceModels.RecordTab> tabs = AgentforceWorkspaceQueryService.buildRecordTabs(
            new List<BusinessIntelligence.QueryExecution>{ exec },
            oppAccountMap,
            new Map<String, List<SObject>>()
        );
        System.assert(!tabs.isEmpty());
        // Should have Account.Name or _accountName column
        Boolean hasAccountCol = false;
        for (AgentforceWorkspaceModels.ColumnDef col : tabs[0].columns) {
            if (col.fieldName == 'Account.Name' || col.fieldName == '_accountName') {
                hasAccountCol = true;
                break;
            }
        }
        System.assert(hasAccountCol, 'Should have Account column for Opportunities');
    }

    @isTest
    static void testBuildRecordTabs_OppsWithoutAccountName() {
        // Opps WITHOUT Account.Name in query — should inject _accountName via oppAccountMap
        List<Opportunity> opps = [SELECT Id, Name, Amount, StageName, CloseDate FROM Opportunity LIMIT 5];
        if (opps.isEmpty()) return;

        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.purpose = 'Opps no account';
        exec.soql = 'SELECT Id, Name, Amount, StageName, CloseDate FROM Opportunity ORDER BY Amount DESC LIMIT 200';
        exec.results = opps;
        exec.limitReached = false;

        Set<Id> oppIds = new Set<Id>();
        for (Opportunity o : opps) oppIds.add(o.Id);
        Map<Id, Opportunity> oppAccountMap = AgentforceWorkspaceQueryService.lookupOppAccounts(oppIds);

        List<AgentforceWorkspaceModels.RecordTab> tabs = AgentforceWorkspaceQueryService.buildRecordTabs(
            new List<BusinessIntelligence.QueryExecution>{ exec },
            oppAccountMap,
            new Map<String, List<SObject>>()
        );
        System.assert(!tabs.isEmpty());
        // Should inject _accountName column since Account.Name wasn't in the query
        Boolean hasInjectedCol = false;
        for (AgentforceWorkspaceModels.ColumnDef col : tabs[0].columns) {
            if (col.fieldName == '_accountName') {
                hasInjectedCol = true;
                break;
            }
        }
        System.assert(hasInjectedCol, 'Should have injected _accountName column');
    }

    @isTest
    static void testBuildRecordTabs_WithSorting() {
        // Test with multiple records to exercise sortRows — need 2+ accounts
        List<Account> accs = [SELECT Id, Name, Industry, Type, Phone FROM Account ORDER BY Name LIMIT 5];
        System.assert(accs.size() >= 2, 'Need at least 2 accounts for sort test');

        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.purpose = 'Accounts sorted';
        exec.soql = 'SELECT Id, Name, Industry, Type, Phone FROM Account ORDER BY Name ASC LIMIT 200';
        exec.results = accs;
        exec.limitReached = false;

        List<AgentforceWorkspaceModels.RecordTab> tabs = AgentforceWorkspaceQueryService.buildRecordTabs(
            new List<BusinessIntelligence.QueryExecution>{ exec },
            new Map<Id, Opportunity>(),
            new Map<String, List<SObject>>()
        );
        System.assert(!tabs.isEmpty());
        System.assert(tabs[0].rows.size() >= 2, 'Should have multiple rows for sorting');
    }

    @isTest
    static void testRunSupplementaryQueries_WithOCR() {
        // OpportunityContactRole results should trigger supplementary Contact and Opportunity queries
        List<OpportunityContactRole> ocrs = [SELECT Id, ContactId, OpportunityId, Role FROM OpportunityContactRole LIMIT 5];
        if (ocrs.isEmpty()) return;

        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.purpose = 'Contact Roles';
        exec.soql = 'SELECT Id, ContactId, OpportunityId, Role FROM OpportunityContactRole LIMIT 5';
        exec.results = ocrs;
        exec.limitReached = false;

        Set<String> objectsWithRecords = new Set<String>{ 'OpportunityContactRole' };
        Map<String, List<SObject>> result = AgentforceWorkspaceQueryService.runSupplementaryQueries(
            new List<BusinessIntelligence.QueryExecution>{ exec },
            objectsWithRecords
        );
        // Should have supplementary Contact and Opportunity records
        System.assert(result.containsKey('Contact'), 'Should have supplementary Contact records from OCR');
        System.assert(result.containsKey('Opportunity'), 'Should have supplementary Opportunity records from OCR');
    }

    @isTest
    static void testRunSupplementaryQueries_AggregateWithWhere() {
        // Aggregate query with WHERE clause — exercises extractBestWhereClause
        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.purpose = 'Opp stages';
        exec.soql = 'SELECT StageName, COUNT(Id) FROM Opportunity WHERE OwnerId = \'' + UserInfo.getUserId() + '\' GROUP BY StageName LIMIT 10';
        exec.results = new List<SObject>();
        exec.countResult = null;
        exec.limitReached = false;

        Set<String> objectsWithRecords = new Set<String>();
        Map<String, List<SObject>> result = AgentforceWorkspaceQueryService.runSupplementaryQueries(
            new List<BusinessIntelligence.QueryExecution>{ exec },
            objectsWithRecords
        );
        System.assertNotEquals(null, result);
    }

    // ═══════════════════════════════════════════════
    //  LinkService — collectRecordLinks
    // ═══════════════════════════════════════════════

    @isTest
    static void testCollectRecordLinks_WithAccounts() {
        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.purpose = 'Accounts';
        exec.soql = 'SELECT Id, Name FROM Account LIMIT 5';
        exec.results = [SELECT Id, Name FROM Account LIMIT 5];

        Map<String, List<String>> links = AgentforceWorkspaceLinkService.collectRecordLinks(
            new List<BusinessIntelligence.QueryExecution>{ exec },
            new Map<Id, Opportunity>(),
            new Map<String, List<SObject>>()
        );
        // Our test account name is > 4 chars so it should be linked
        System.assert(!links.isEmpty());
    }

    @isTest
    static void testCollectRecordLinks_WithOppsAndAccounts() {
        List<Opportunity> opps = [SELECT Id, Name, Account.Name FROM Opportunity LIMIT 5];
        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.purpose = 'Opps';
        exec.soql = 'SELECT Id, Name, Account.Name FROM Opportunity LIMIT 5';
        exec.results = opps;

        Set<Id> oppIds = new Set<Id>();
        for (Opportunity o : opps) oppIds.add(o.Id);
        Map<Id, Opportunity> oppAccountMap = AgentforceWorkspaceQueryService.lookupOppAccounts(oppIds);

        Map<String, List<String>> links = AgentforceWorkspaceLinkService.collectRecordLinks(
            new List<BusinessIntelligence.QueryExecution>{ exec },
            oppAccountMap,
            new Map<String, List<SObject>>()
        );
        System.assert(!links.isEmpty());
    }

    @isTest
    static void testCollectRecordLinks_WithCases() {
        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.purpose = 'Cases';
        exec.soql = 'SELECT Id, CaseNumber FROM Case LIMIT 5';
        exec.results = [SELECT Id, CaseNumber FROM Case LIMIT 5];

        Map<String, List<String>> links = AgentforceWorkspaceLinkService.collectRecordLinks(
            new List<BusinessIntelligence.QueryExecution>{ exec },
            new Map<Id, Opportunity>(),
            new Map<String, List<SObject>>()
        );
        // Case links should include "Case XXXXX" alternate key
        System.assertNotEquals(null, links);
    }

    @isTest
    static void testCollectRecordLinks_WithSupplementary() {
        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.error = 'fail';

        Map<String, List<SObject>> supplementary = new Map<String, List<SObject>>();
        supplementary.put('Account', [SELECT Id, Name FROM Account LIMIT 5]);

        Map<String, List<String>> links = AgentforceWorkspaceLinkService.collectRecordLinks(
            new List<BusinessIntelligence.QueryExecution>{ exec },
            new Map<Id, Opportunity>(),
            supplementary
        );
        System.assert(!links.isEmpty());
    }

    @isTest
    static void testCollectRecordLinks_WithEvents() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        BusinessIntelligence.QueryExecution exec = new BusinessIntelligence.QueryExecution();
        exec.purpose = 'Events';
        exec.soql = 'SELECT Id, Subject, WhatId FROM Event LIMIT 5';
        exec.results = [SELECT Id, Subject, WhatId FROM Event WHERE WhatId = :acc.Id LIMIT 5];

        Map<String, List<String>> links = AgentforceWorkspaceLinkService.collectRecordLinks(
            new List<BusinessIntelligence.QueryExecution>{ exec },
            new Map<Id, Opportunity>(),
            new Map<String, List<SObject>>()
        );
        System.assertNotEquals(null, links);
    }

    // ═══════════════════════════════════════════════
    //  LinkService — safeInjectRecordLinks
    // ═══════════════════════════════════════════════

    @isTest
    static void testSafeInjectRecordLinks_EmptyLinks() {
        String result = AgentforceWorkspaceLinkService.safeInjectRecordLinks(
            '<p>Hello</p>', new Map<String, List<String>>()
        );
        System.assertEquals('<p>Hello</p>', result);
    }

    @isTest
    static void testSafeInjectRecordLinks_BlankHtml() {
        Map<String, List<String>> links = new Map<String, List<String>>{
            'Test Account' => new List<String>{ '001xxx', 'Account' }
        };
        String result = AgentforceWorkspaceLinkService.safeInjectRecordLinks('', links);
        System.assertEquals('', result);
    }

    @isTest
    static void testSafeInjectRecordLinks_InjectsLinks() {
        Map<String, List<String>> links = new Map<String, List<String>>{
            'Workspace Test Account' => new List<String>{ '001xxx', 'Account' }
        };
        String html = '<p>Check out Workspace Test Account for details.</p>';
        String result = AgentforceWorkspaceLinkService.safeInjectRecordLinks(html, links);
        System.assert(result.contains('<a href='));
        System.assert(result.contains('Workspace Test Account'));
    }

    @isTest
    static void testSafeInjectRecordLinks_SkipsAlreadyLinked() {
        Map<String, List<String>> links = new Map<String, List<String>>{
            'Workspace Test Account' => new List<String>{ '001xxx', 'Account' }
        };
        String html = '<p><a href="/test"><b>Workspace Test Account</b></a> is great.</p>';
        String result = AgentforceWorkspaceLinkService.safeInjectRecordLinks(html, links);
        // Should not double-link
        Integer count = result.countMatches('<a href=');
        System.assertEquals(1, count);
    }

    @isTest
    static void testSafeInjectRecordLinks_PreservesChartAndSuggestions() {
        Map<String, List<String>> links = new Map<String, List<String>>{
            'Workspace Test Account' => new List<String>{ '001xxx', 'Account' }
        };
        String html = '<p>Workspace Test Account</p><CHART>{"chartType":"bar"}</CHART><SUGGESTIONS>["test"]</SUGGESTIONS>';
        String result = AgentforceWorkspaceLinkService.safeInjectRecordLinks(html, links);
        System.assert(result.contains('<CHART>'));
        System.assert(result.contains('<SUGGESTIONS>'));
        System.assert(result.contains('<a href='));
    }

    // ═══════════════════════════════════════════════
    //  AnalysisService — buildNLtoSOQLPrompt
    // ═══════════════════════════════════════════════

    @isTest
    static void testBuildNLtoSOQLPrompt() {
        String prompt = AgentforceWorkspaceAnalysisService.buildNLtoSOQLPrompt(
            'Show my pipeline', null, UserInfo.getUserId(), 'Dylan', 'Schema context'
        );
        System.assert(prompt.contains('Show my pipeline'));
        System.assert(prompt.contains('Dylan'));
        System.assert(prompt.contains('SOQL expert'));
        System.assert(prompt.contains('Schema context'));
    }

    @isTest
    static void testBuildNLtoSOQLPrompt_WithHistory() {
        String prompt = AgentforceWorkspaceAnalysisService.buildNLtoSOQLPrompt(
            'Break it down by stage', 'User: Show my pipeline\nAI: Here is your pipeline...',
            UserInfo.getUserId(), 'Dylan', 'Schema context'
        );
        System.assert(prompt.contains('CONVERSATION CONTEXT'));
        System.assert(prompt.contains('Break it down by stage'));
    }

    // ═══════════════════════════════════════════════
    //  AnalysisService — buildAnalysisPromptFromData
    // ═══════════════════════════════════════════════

    @isTest
    static void testBuildAnalysisPromptFromData_WithResults() {
        AgentforceWorkspaceModels.ExecutionData data = new AgentforceWorkspaceModels.ExecutionData();
        data.queryResultsText = '### Test\n1. Name: Test Account\n';
        data.recordLinks = new Map<String, List<String>>{
            'Test Account' => new List<String>{ '001xxx', 'Account' }
        };
        data.userName = 'Dylan';
        data.userFullName = 'Dylan Andersen';
        data.hasAnyResults = true;

        String prompt = AgentforceWorkspaceAnalysisService.buildAnalysisPromptFromData(
            data, 'Show accounts', null
        );
        System.assert(prompt.contains('Dylan'));
        System.assert(prompt.contains('RECORD LINK TABLE'));
        System.assert(prompt.contains('Key Findings'));
    }

    @isTest
    static void testBuildAnalysisPromptFromData_NoResults() {
        AgentforceWorkspaceModels.ExecutionData data = new AgentforceWorkspaceModels.ExecutionData();
        data.queryResultsText = '';
        data.recordLinks = new Map<String, List<String>>();
        data.userName = 'Dylan';
        data.userFullName = 'Dylan Andersen';
        data.hasAnyResults = false;

        String prompt = AgentforceWorkspaceAnalysisService.buildAnalysisPromptFromData(
            data, 'Show something', 'Previous history'
        );
        System.assert(prompt.contains('no matching data was found'));
        System.assert(prompt.contains('CONVERSATION SO FAR'));
    }

    // ═══════════════════════════════════════════════
    //  AnalysisService — callModelsAPI
    // ═══════════════════════════════════════════════

    @isTest
    static void testCallModelsAPI_ReturnsErrorInTest() {
        Test.startTest();
        String result = AgentforceWorkspaceAnalysisService.callModelsAPI('test prompt', 'sfdc_ai__DefaultVertexAIGemini31FlashLite');
        Test.stopTest();
        // In test context, the managed package call will fail — we should get an error string
        System.assert(String.isNotBlank(result));
    }

    // ═══════════════════════════════════════════════
    //  AnalysisService — parseSuggestions
    // ═══════════════════════════════════════════════

    @isTest
    static void testParseSuggestions_FullResponse() {
        String raw = '<h1>Title</h1><p>Analysis</p>'
            + '<CHART>{"chartType":"bar","title":"Test","valueLabel":"Count","items":[{"label":"A","value":10}]}</CHART>'
            + '<SUGGESTIONS>["Follow up 1?","Follow up 2?","Follow up 3?"]</SUGGESTIONS>';

        AgentforceWorkspaceModels.ChatResult result = AgentforceWorkspaceAnalysisService.parseSuggestions(raw);
        System.assert(result.response.contains('Title'));
        System.assertEquals(3, result.suggestions.size());
        System.assertNotEquals(null, result.chartData);
        System.assertEquals('bar', result.chartData.chartType);
        System.assertEquals(1, result.chartData.items.size());
    }

    @isTest
    static void testParseSuggestions_NoSuggestions() {
        String raw = '<p>Just some HTML</p>';
        AgentforceWorkspaceModels.ChatResult result = AgentforceWorkspaceAnalysisService.parseSuggestions(raw);
        System.assertEquals('<p>Just some HTML</p>', result.response);
        System.assert(!result.suggestions.isEmpty(), 'Should have fallback suggestions');
    }

    @isTest
    static void testParseSuggestions_Blank() {
        AgentforceWorkspaceModels.ChatResult result = AgentforceWorkspaceAnalysisService.parseSuggestions('');
        System.assertEquals('', result.response);
    }

    @isTest
    static void testParseSuggestions_InvalidChartJson() {
        String raw = '<p>Test</p><CHART>not json</CHART><SUGGESTIONS>["q1?"]</SUGGESTIONS>';
        AgentforceWorkspaceModels.ChatResult result = AgentforceWorkspaceAnalysisService.parseSuggestions(raw);
        System.assertEquals(null, result.chartData);
        System.assertEquals(1, result.suggestions.size());
    }

    @isTest
    static void testParseSuggestions_InvalidSuggestionsJson() {
        String raw = '<p>Test</p><SUGGESTIONS>not json</SUGGESTIONS>';
        AgentforceWorkspaceModels.ChatResult result = AgentforceWorkspaceAnalysisService.parseSuggestions(raw);
        System.assert(!result.suggestions.isEmpty(), 'Should have fallback suggestions');
    }

    @isTest
    static void testParseSuggestions_FallbackWithOpps() {
        String raw = '<p>Your opportunity pipeline looks strong</p>';
        AgentforceWorkspaceModels.ChatResult result = AgentforceWorkspaceAnalysisService.parseSuggestions(raw);
        System.assert(!result.suggestions.isEmpty());
    }

    @isTest
    static void testParseSuggestions_FallbackWithCases() {
        String raw = '<p>Here are your open cases and leads</p>';
        AgentforceWorkspaceModels.ChatResult result = AgentforceWorkspaceAnalysisService.parseSuggestions(raw);
        System.assert(!result.suggestions.isEmpty());
    }

    @isTest
    static void testParseSuggestions_FallbackWithCampaigns() {
        String raw = '<p>Campaign performance and tasks overview</p>';
        AgentforceWorkspaceModels.ChatResult result = AgentforceWorkspaceAnalysisService.parseSuggestions(raw);
        System.assert(!result.suggestions.isEmpty());
    }

    @isTest
    static void testParseSuggestions_FallbackBlank() {
        String raw = '<p></p>';
        AgentforceWorkspaceModels.ChatResult result = AgentforceWorkspaceAnalysisService.parseSuggestions(raw);
        // Very short HTML triggers default suggestions
        System.assert(result.suggestions.size() <= 3);
    }
}
