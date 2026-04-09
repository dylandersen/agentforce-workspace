@isTest
public class AgentforceWorkspaceControllerTest {

    @TestSetup
    static void setupTestData() {
        Account testAccount = new Account(
            Name = 'Workspace Controller Test Account',
            Industry = 'Technology',
            Type = 'Customer - Direct',
            Phone = '555-0001',
            AnnualRevenue = 1000000,
            NumberOfEmployees = 50
        );
        insert testAccount;

        Contact testContact = new Contact(
            FirstName = 'Controller',
            LastName = 'TestContact',
            AccountId = testAccount.Id,
            Email = 'controller@test.com'
        );
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.allowSave = true;
        Database.insert(testContact, dml);

        Opportunity testOpp = new Opportunity(
            Name = 'Workspace Controller Opp',
            AccountId = testAccount.Id,
            Amount = 75000,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert testOpp;

        Lead testLead = new Lead(
            FirstName = 'Controller',
            LastName = 'TestLead',
            Company = 'Test Corp',
            Status = 'Open - Not Contacted'
        );
        Database.insert(testLead, dml);
    }

    // ═══════════════════════════════════════════════
    //  RecordCreator — parseCreateAction
    // ═══════════════════════════════════════════════

    @isTest
    static void testParseCreateAction_Null() {
        System.assertEquals(null, AgentforceWorkspaceRecordCreator.parseCreateAction(null));
    }

    @isTest
    static void testParseCreateAction_Blank() {
        System.assertEquals(null, AgentforceWorkspaceRecordCreator.parseCreateAction(''));
    }

    @isTest
    static void testParseCreateAction_InvalidJson() {
        System.assertEquals(null, AgentforceWorkspaceRecordCreator.parseCreateAction('not json at all'));
    }

    @isTest
    static void testParseCreateAction_JsonNoActionKey() {
        System.assertEquals(null, AgentforceWorkspaceRecordCreator.parseCreateAction('{"key":"value"}'));
    }

    @isTest
    static void testParseCreateAction_ValidCreate() {
        String json = '{"action":"create","objectApiName":"Account","fields":{"Name":"Test"}}';
        Map<String, Object> result = AgentforceWorkspaceRecordCreator.parseCreateAction(json);
        System.assertNotEquals(null, result);
        System.assertEquals('create', result.get('action'));
        System.assertEquals('Account', result.get('objectApiName'));
    }

    @isTest
    static void testParseCreateAction_MarkdownCodeBlock() {
        String json = '```json\n{"action":"create_execute","objectApiName":"Task","fields":{"Subject":"Test"}}\n```';
        Map<String, Object> result = AgentforceWorkspaceRecordCreator.parseCreateAction(json);
        System.assertNotEquals(null, result);
        System.assertEquals('create_execute', result.get('action'));
    }

    // ═══════════════════════════════════════════════
    //  RecordCreator — handleCreateConfirm
    // ═══════════════════════════════════════════════

    @isTest
    static void testHandleCreateConfirm_Account() {
        Map<String, Object> actionResult = new Map<String, Object>{
            'action' => 'create',
            'objectApiName' => 'Account',
            'fields' => new Map<String, Object>{ 'Name' => 'New Corp' }
        };
        Test.startTest();
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceRecordCreator.handleCreateConfirm(actionResult, 'Dylan', 'sfdc_ai__DefaultVertexAIGemini31FlashLite');
        Test.stopTest();
        // callModelsAPI returns error string in test, parseSuggestions processes it
        System.assertNotEquals(null, result);
        System.assertNotEquals(null, result.response);
    }

    @isTest
    static void testHandleCreateConfirm_TaskCall() {
        Map<String, Object> actionResult = new Map<String, Object>{
            'action' => 'create',
            'objectApiName' => 'Task',
            'fields' => new Map<String, Object>{ 'Subject' => 'Call with David', 'TaskSubtype' => 'Call' }
        };
        Test.startTest();
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceRecordCreator.handleCreateConfirm(actionResult, 'Dylan', 'sfdc_ai__DefaultVertexAIGemini31FlashLite');
        Test.stopTest();
        System.assertNotEquals(null, result);
    }

    @isTest
    static void testHandleCreateConfirm_Event() {
        Map<String, Object> actionResult = new Map<String, Object>{
            'action' => 'create',
            'objectApiName' => 'Event'
        };
        Test.startTest();
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceRecordCreator.handleCreateConfirm(actionResult, 'Dylan', 'sfdc_ai__DefaultVertexAIGemini31FlashLite');
        Test.stopTest();
        System.assertNotEquals(null, result);
    }

    @isTest
    static void testHandleCreateConfirm_NoFields() {
        Map<String, Object> actionResult = new Map<String, Object>{
            'action' => 'create',
            'objectApiName' => 'Account'
        };
        Test.startTest();
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceRecordCreator.handleCreateConfirm(actionResult, 'Dylan', 'sfdc_ai__DefaultVertexAIGemini31FlashLite');
        Test.stopTest();
        System.assertNotEquals(null, result);
    }

    // ═══════════════════════════════════════════════
    //  RecordCreator — handleCreateExecute
    // ═══════════════════════════════════════════════

    @isTest
    static void testHandleCreateExecute_BlankObjectName() {
        Map<String, Object> actionResult = new Map<String, Object>{
            'objectApiName' => '',
            'fields' => new Map<String, Object>{ 'Name' => 'Test' }
        };
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceRecordCreator.handleCreateExecute(actionResult, 'Dylan', 'test');
        System.assert(result.response.contains('I need at least a name'));
    }

    @isTest
    static void testHandleCreateExecute_EmptyFields() {
        Map<String, Object> actionResult = new Map<String, Object>{
            'objectApiName' => 'Account',
            'fields' => new Map<String, Object>()
        };
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceRecordCreator.handleCreateExecute(actionResult, 'Dylan', 'test');
        System.assert(result.response.contains('I need at least a name'));
    }

    @isTest
    static void testHandleCreateExecute_NoFieldsKey() {
        Map<String, Object> actionResult = new Map<String, Object>{
            'objectApiName' => 'Account'
        };
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceRecordCreator.handleCreateExecute(actionResult, 'Dylan', 'test');
        System.assert(result.response.contains('I need at least a name'));
    }

    @isTest
    static void testHandleCreateExecute_UnsupportedObject() {
        Map<String, Object> actionResult = new Map<String, Object>{
            'objectApiName' => 'Lead',
            'fields' => new Map<String, Object>{ 'LastName' => 'Test' }
        };
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceRecordCreator.handleCreateExecute(actionResult, 'Dylan', 'test');
        System.assert(result.response.contains('I can create Account, Task, and Event'));
    }

    @isTest
    static void testHandleCreateExecute_Account() {
        Map<String, Object> actionResult = new Map<String, Object>{
            'objectApiName' => 'Account',
            'fields' => new Map<String, Object>{
                'Name' => 'Test Create Account',
                'Industry' => 'Technology',
                'Phone' => '555-9999',
                'AnnualRevenue' => '500000',
                'NumberOfEmployees' => '25',
                'Website' => 'https://test.com',
                'Description' => 'Test description'
            }
        };
        Test.startTest();
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceRecordCreator.handleCreateExecute(actionResult, 'Dylan', 'test');
        Test.stopTest();
        System.assert(result.response.contains('Account Created'));
        System.assert(result.response.contains('Test Create Account'));
        System.assertNotEquals(null, result.createdRecord);
        System.assertEquals('Account', result.createdRecord.objectApiName);
        System.assertEquals('Test Create Account', result.createdRecord.recordName);
        System.assertEquals(2, result.suggestions.size());
        // Verify record was actually created
        List<Account> created = [SELECT Id FROM Account WHERE Name = 'Test Create Account'];
        System.assertEquals(1, created.size());
    }

    @isTest
    static void testHandleCreateExecute_Task() {
        Account acc = [SELECT Id FROM Account WHERE Name = 'Workspace Controller Test Account' LIMIT 1];
        Map<String, Object> actionResult = new Map<String, Object>{
            'objectApiName' => 'Task',
            'fields' => new Map<String, Object>{
                'Subject' => 'Test Created Task',
                'Status' => 'Not Started',
                'Priority' => 'High',
                'ActivityDate' => String.valueOf(Date.today()),
                'WhatId' => String.valueOf(acc.Id),
                'Description' => 'Test task description'
            }
        };
        Test.startTest();
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceRecordCreator.handleCreateExecute(actionResult, 'Dylan', 'test');
        Test.stopTest();
        System.assert(result.response.contains('Task Created'));
        System.assertNotEquals(null, result.createdRecord);
        System.assertEquals('Task', result.createdRecord.objectApiName);
        System.assert(result.suggestions.contains('Log another task'));
    }

    @isTest
    static void testHandleCreateExecute_TaskCall() {
        Map<String, Object> actionResult = new Map<String, Object>{
            'objectApiName' => 'Task',
            'fields' => new Map<String, Object>{
                'Subject' => 'Call with Client',
                'TaskSubtype' => 'Call',
                'Status' => 'Completed',
                'ActivityDate' => String.valueOf(Date.today())
            }
        };
        Test.startTest();
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceRecordCreator.handleCreateExecute(actionResult, 'Dylan', 'test');
        Test.stopTest();
        System.assert(result.response.contains('Call Logged'));
        System.assert(result.suggestions.contains('Log another call'));
    }

    @isTest
    static void testHandleCreateExecute_Event() {
        Map<String, Object> actionResult = new Map<String, Object>{
            'objectApiName' => 'Event',
            'fields' => new Map<String, Object>{
                'Subject' => 'Quarterly Review Meeting',
                'StartDateTime' => '2026-03-20T10:00:00',
                'EndDateTime' => '2026-03-20T11:00:00',
                'Location' => 'Conference Room A',
                'Description' => 'Review Q1 performance'
            }
        };
        Test.startTest();
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceRecordCreator.handleCreateExecute(actionResult, 'Dylan', 'test');
        Test.stopTest();
        System.assert(result.response.contains('Event Scheduled'));
        System.assertNotEquals(null, result.createdRecord);
        System.assertEquals('Event', result.createdRecord.objectApiName);
        System.assert(result.suggestions.contains('Schedule another meeting'));
    }

    @isTest
    static void testHandleCreateExecute_TaskWithContactNameResolution() {
        Map<String, Object> actionResult = new Map<String, Object>{
            'objectApiName' => 'Task',
            'fields' => new Map<String, Object>{
                'Subject' => 'Follow up call',
                'TaskSubtype' => 'Call',
                'Status' => 'Completed',
                'WhoId' => 'Controller TestContact',
                'ActivityDate' => String.valueOf(Date.today())
            }
        };
        Test.startTest();
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceRecordCreator.handleCreateExecute(actionResult, 'Dylan', 'test');
        Test.stopTest();
        System.assert(result.response.contains('Call Logged'));
        // Verify WhoId was resolved to the Contact
        List<Task> tasks = [SELECT WhoId, WhatId FROM Task WHERE Subject = 'Follow up call'];
        System.assertEquals(1, tasks.size());
        Contact c = [SELECT Id, AccountId FROM Contact WHERE LastName = 'TestContact' LIMIT 1];
        System.assertEquals(c.Id, tasks[0].WhoId);
        // WhatId should have been auto-populated with the contact's account
        System.assertEquals(c.AccountId, tasks[0].WhatId);
    }

    @isTest
    static void testHandleCreateExecute_TaskWithLeadNameResolution() {
        Map<String, Object> actionResult = new Map<String, Object>{
            'objectApiName' => 'Task',
            'fields' => new Map<String, Object>{
                'Subject' => 'Lead follow up',
                'Status' => 'Not Started',
                'WhoId' => 'Controller TestLead',
                'ActivityDate' => String.valueOf(Date.today())
            }
        };
        Test.startTest();
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceRecordCreator.handleCreateExecute(actionResult, 'Dylan', 'test');
        Test.stopTest();
        List<Task> tasks = [SELECT WhoId FROM Task WHERE Subject = 'Lead follow up'];
        System.assertEquals(1, tasks.size());
        Lead l = [SELECT Id FROM Lead WHERE LastName = 'TestLead' LIMIT 1];
        System.assertEquals(l.Id, tasks[0].WhoId);
    }

    @isTest
    static void testHandleCreateExecute_TaskWithAccountNameForWhatId() {
        Map<String, Object> actionResult = new Map<String, Object>{
            'objectApiName' => 'Task',
            'fields' => new Map<String, Object>{
                'Subject' => 'Account task',
                'Status' => 'Not Started',
                'WhatId' => 'Workspace Controller Test Account',
                'ActivityDate' => String.valueOf(Date.today())
            }
        };
        Test.startTest();
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceRecordCreator.handleCreateExecute(actionResult, 'Dylan', 'test');
        Test.stopTest();
        List<Task> tasks = [SELECT WhatId FROM Task WHERE Subject = 'Account task'];
        System.assertEquals(1, tasks.size());
        Account a = [SELECT Id FROM Account WHERE Name = 'Workspace Controller Test Account' LIMIT 1];
        System.assertEquals(a.Id, tasks[0].WhatId);
    }

    @isTest
    static void testHandleCreateExecute_TaskWithOppNameForWhatId() {
        Map<String, Object> actionResult = new Map<String, Object>{
            'objectApiName' => 'Task',
            'fields' => new Map<String, Object>{
                'Subject' => 'Opp task',
                'Status' => 'Not Started',
                'WhatId' => 'Workspace Controller Opp',
                'ActivityDate' => String.valueOf(Date.today())
            }
        };
        Test.startTest();
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceRecordCreator.handleCreateExecute(actionResult, 'Dylan', 'test');
        Test.stopTest();
        List<Task> tasks = [SELECT WhatId FROM Task WHERE Subject = 'Opp task'];
        System.assertEquals(1, tasks.size());
        Opportunity o = [SELECT Id FROM Opportunity WHERE Name = 'Workspace Controller Opp' LIMIT 1];
        System.assertEquals(o.Id, tasks[0].WhatId);
    }

    @isTest
    static void testHandleCreateExecute_UnresolvableWhoId() {
        Map<String, Object> actionResult = new Map<String, Object>{
            'objectApiName' => 'Task',
            'fields' => new Map<String, Object>{
                'Subject' => 'Unresolvable who',
                'Status' => 'Not Started',
                'WhoId' => 'Nobody Exists ZZZZZZZ',
                'ActivityDate' => String.valueOf(Date.today())
            }
        };
        Test.startTest();
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceRecordCreator.handleCreateExecute(actionResult, 'Dylan', 'test');
        Test.stopTest();
        // WhoId should have been removed since it couldn't be resolved
        List<Task> tasks = [SELECT WhoId FROM Task WHERE Subject = 'Unresolvable who'];
        System.assertEquals(1, tasks.size());
        System.assertEquals(null, tasks[0].WhoId);
    }

    @isTest
    static void testHandleCreateExecute_UnresolvableWhatId() {
        Map<String, Object> actionResult = new Map<String, Object>{
            'objectApiName' => 'Task',
            'fields' => new Map<String, Object>{
                'Subject' => 'Unresolvable what',
                'Status' => 'Not Started',
                'WhatId' => 'NoCompany Exists ZZZZZZZ',
                'ActivityDate' => String.valueOf(Date.today())
            }
        };
        Test.startTest();
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceRecordCreator.handleCreateExecute(actionResult, 'Dylan', 'test');
        Test.stopTest();
        List<Task> tasks = [SELECT WhatId FROM Task WHERE Subject = 'Unresolvable what'];
        System.assertEquals(1, tasks.size());
        System.assertEquals(null, tasks[0].WhatId);
    }

    @isTest
    static void testHandleCreateExecute_BooleanField() {
        // Event with IsAllDayEvent (boolean field)
        Map<String, Object> actionResult = new Map<String, Object>{
            'objectApiName' => 'Event',
            'fields' => new Map<String, Object>{
                'Subject' => 'All Day Event Test',
                'IsAllDayEvent' => 'true',
                'ActivityDate' => String.valueOf(Date.today())
            }
        };
        Test.startTest();
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceRecordCreator.handleCreateExecute(actionResult, 'Dylan', 'test');
        Test.stopTest();
        System.assertNotEquals(null, result.createdRecord);
    }

    @isTest
    static void testHandleCreateExecute_NullFieldValue() {
        // A field with value 'null' string should be skipped by setTypedFieldValue
        Map<String, Object> actionResult = new Map<String, Object>{
            'objectApiName' => 'Account',
            'fields' => new Map<String, Object>{
                'Name' => 'Null Field Test Account',
                'Description' => 'null'
            }
        };
        Test.startTest();
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceRecordCreator.handleCreateExecute(actionResult, 'Dylan', 'test');
        Test.stopTest();
        System.assert(result.response.contains('Account Created'));
        Account created = [SELECT Description FROM Account WHERE Name = 'Null Field Test Account'];
        System.assertEquals(null, created.Description);
    }

    @isTest
    static void testHandleCreateExecute_OwnerIdAutoSet() {
        // Task without OwnerId should auto-set to running user
        Map<String, Object> actionResult = new Map<String, Object>{
            'objectApiName' => 'Task',
            'fields' => new Map<String, Object>{
                'Subject' => 'Auto Owner Task',
                'Status' => 'Not Started'
            }
        };
        Test.startTest();
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceRecordCreator.handleCreateExecute(actionResult, 'Dylan', 'test');
        Test.stopTest();
        Task created = [SELECT OwnerId FROM Task WHERE Subject = 'Auto Owner Task'];
        System.assertEquals(UserInfo.getUserId(), created.OwnerId);
    }

    // ═══════════════════════════════════════════════
    //  Controller — getUserFirstName
    // ═══════════════════════════════════════════════

    @isTest
    static void testGetUserFirstName() {
        String name = AgentforceWorkspaceController.getUserFirstName();
        System.assert(String.isNotBlank(name));
    }

    // ═══════════════════════════════════════════════
    //  Controller — getUserPhotoUrl
    // ═══════════════════════════════════════════════

    @isTest
    static void testGetUserPhotoUrl() {
        String url = AgentforceWorkspaceController.getUserPhotoUrl();
        // May or may not be null depending on org, but method should not throw
        System.assert(true);
    }

    // ═══════════════════════════════════════════════
    //  Controller — chat
    // ═══════════════════════════════════════════════

    @isTest
    static void testChat_BlankMessage() {
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceController.chat('', null, null);
        System.assert(result.response.contains('Please provide a question'));
    }

    @isTest
    static void testChat_ModelsAPIUnavailable() {
        // In test context, callModelsAPI returns an error string
        // parseAndValidateSOQL will return empty plans → "couldn't generate a valid query"
        Test.startTest();
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceController.chat('Show my pipeline', null, null);
        Test.stopTest();
        System.assertNotEquals(null, result.response);
    }

    @isTest
    static void testChat_WithModelName() {
        Test.startTest();
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceController.chat('Show accounts', null, 'sfdc_ai__DefaultVertexAIGemini31FlashLite');
        Test.stopTest();
        System.assertNotEquals(null, result.response);
    }

    // ═══════════════════════════════════════════════
    //  Controller — buildQueries
    // ═══════════════════════════════════════════════

    @isTest
    static void testBuildQueries_BlankMessage() {
        AgentforceWorkspaceModels.QueryResult result =
            AgentforceWorkspaceController.buildQueries('', null, null);
        System.assertEquals('Please provide a question.', result.querySummary);
    }

    @isTest
    static void testBuildQueries_ModelsAPIUnavailable() {
        // callModelsAPI returns error HTML → buildQueries detects it and returns AI unavailable message
        Test.startTest();
        AgentforceWorkspaceModels.QueryResult result =
            AgentforceWorkspaceController.buildQueries('Show my pipeline', null, null);
        Test.stopTest();
        System.assertNotEquals(null, result.querySummary);
        System.assertNotEquals(null, result.executionDataJson);
    }

    @isTest
    static void testBuildQueries_WithModelName() {
        Test.startTest();
        AgentforceWorkspaceModels.QueryResult result =
            AgentforceWorkspaceController.buildQueries('Show accounts', null, 'sfdc_ai__DefaultVertexAIGemini31FlashLite');
        Test.stopTest();
        System.assertNotEquals(null, result.querySummary);
    }

    // ═══════════════════════════════════════════════
    //  Controller — analyzeResults
    // ═══════════════════════════════════════════════

    @isTest
    static void testAnalyzeResults_BlankData() {
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceController.analyzeResults('', 'test', null, null);
        System.assert(result.response.contains('No query data available'));
    }

    @isTest
    static void testAnalyzeResults_CreateResult() {
        String json = JSON.serialize(new Map<String, Object>{
            'isCreateResult' => true,
            'chatResult' => new Map<String, Object>{
                'response' => '<p>Account created!</p>',
                'suggestions' => new List<String>{ 'Show accounts', 'Create another' },
                'forceRecordUpdate' => true,
                'createdRecord' => new Map<String, Object>{
                    'objectApiName' => 'Account',
                    'objectLabel' => 'Account',
                    'iconName' => 'standard:account',
                    'recordId' => '001000000000001',
                    'recordName' => 'Test Corp',
                    'recordUrl' => '/lightning/r/Account/001000000000001/view',
                    'fields' => new List<Object>{
                        new Map<String, Object>{
                            'label' => 'Industry',
                            'value' => 'Technology',
                            'type' => 'STRING'
                        }
                    }
                }
            }
        });
        Test.startTest();
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceController.analyzeResults(json, 'test', null, null);
        Test.stopTest();
        System.assertEquals('<p>Account created!</p>', result.response);
        System.assertEquals(true, result.forceRecordUpdate);
        System.assertEquals(2, result.suggestions.size());
        System.assertNotEquals(null, result.createdRecord);
        System.assertEquals('Account', result.createdRecord.objectApiName);
        System.assertEquals('Test Corp', result.createdRecord.recordName);
        System.assertEquals(1, result.createdRecord.fields.size());
    }

    @isTest
    static void testAnalyzeResults_CreateResultNoCreatedRecord() {
        String json = JSON.serialize(new Map<String, Object>{
            'isCreateResult' => true,
            'chatResult' => new Map<String, Object>{
                'response' => '<p>Confirmed!</p>',
                'suggestions' => new List<String>{ 'Do it' }
            }
        });
        Test.startTest();
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceController.analyzeResults(json, 'test', null, null);
        Test.stopTest();
        System.assertEquals('<p>Confirmed!</p>', result.response);
        System.assertEquals(null, result.createdRecord);
    }

    @isTest
    static void testAnalyzeResults_ExecutionData() {
        String json = JSON.serialize(new Map<String, Object>{
            'executionData' => new Map<String, Object>{
                'queryResultsText' => '### Accounts\n1. Name: Test Account\n',
                'recordLinks' => new Map<String, Object>{
                    'Test Account' => new List<String>{ '001xxx', 'Account' }
                },
                'userName' => 'Dylan',
                'userFullName' => 'Dylan Andersen',
                'hasAnyResults' => true
            }
        });
        Test.startTest();
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceController.analyzeResults(json, 'Show accounts', null, null);
        Test.stopTest();
        // callModelsAPI returns error HTML in test, parseSuggestions processes it
        System.assertNotEquals(null, result.response);
    }

    @isTest
    static void testAnalyzeResults_ExecutionDataNoResults() {
        String json = JSON.serialize(new Map<String, Object>{
            'executionData' => new Map<String, Object>{
                'queryResultsText' => '',
                'recordLinks' => new Map<String, Object>(),
                'userName' => 'Dylan',
                'hasAnyResults' => false
            }
        });
        Test.startTest();
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceController.analyzeResults(json, 'Show nonexistent', 'Previous context', 'sfdc_ai__DefaultVertexAIGemini31FlashLite');
        Test.stopTest();
        System.assertNotEquals(null, result.response);
    }

    @isTest
    static void testAnalyzeResults_InvalidJson() {
        Test.startTest();
        AgentforceWorkspaceModels.ChatResult result =
            AgentforceWorkspaceController.analyzeResults('not json', 'test', null, null);
        Test.stopTest();
        System.assert(result.response.contains('Something went wrong'));
    }
}
