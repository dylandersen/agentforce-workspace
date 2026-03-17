/**
 * Record creation flow for the Agentforce Workspace feature.
 * Handles create confirmation, execution, field resolution, and success rendering.
 */
public with sharing class AgentforceWorkspaceRecordCreator {

    /** Try to parse the LLM response as a create action JSON. Returns null if not a create action. */
    public static Map<String, Object> parseCreateAction(String response) {
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
    public static AgentforceWorkspaceModels.ChatResult handleCreateConfirm(
            Map<String, Object> actionResult, String userName, String modelName) {
        String objectApiName = (String) actionResult.get('objectApiName');
        Map<String, Object> fields = actionResult.containsKey('fields')
            ? (Map<String, Object>) actionResult.get('fields')
            : new Map<String, Object>();

        String prompt = buildCreateConfirmPrompt(objectApiName, fields, userName);
        String response = AgentforceWorkspaceAnalysisService.callModelsAPI(prompt, modelName);

        return AgentforceWorkspaceAnalysisService.parseSuggestions(response);
    }

    /** Handle create execution: the user confirmed, so create the record and return results. */
    public static AgentforceWorkspaceModels.ChatResult handleCreateExecute(
            Map<String, Object> actionResult, String userName, String modelName) {
        AgentforceWorkspaceModels.ChatResult errorResult = new AgentforceWorkspaceModels.ChatResult();
        String objectApiName = (String) actionResult.get('objectApiName');
        Map<String, Object> fields = actionResult.containsKey('fields')
            ? (Map<String, Object>) actionResult.get('fields')
            : new Map<String, Object>();

        if (String.isBlank(objectApiName) || fields.isEmpty()) {
            errorResult.response = '<p>I need at least a name to create the record. Could you provide more details?</p>';
            return errorResult;
        }

        Set<String> creatableObjects = new Set<String>{ 'Account', 'Task', 'Event' };
        if (!creatableObjects.contains(objectApiName)) {
            errorResult.response = '<p>I can create Account, Task, and Event records. Would you like me to create one of those instead?</p>';
            return errorResult;
        }

        // For Tasks/Events, ensure OwnerId is set to running user
        if (objectApiName == 'Task' || objectApiName == 'Event') {
            if (!fields.containsKey('OwnerId')) {
                fields.put('OwnerId', UserInfo.getUserId());
            }
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

            // Resolve name-based WhoId/WhatId to actual record IDs
            if (objectApiName == 'Task' || objectApiName == 'Event') {
                resolveActivityNameIds(fields);
            }

            for (String fieldName : fields.keySet()) {
                setTypedFieldValue(newRecord, fieldName, String.valueOf(fields.get(fieldName)), fieldMap);
            }

            insert newRecord;

            // Query the created record back for display
            Set<String> queryFieldSet = new Set<String>{ 'Id' };
            String defaultFields = AgentforceWorkspaceQueryService.DEFAULT_LIST_FIELDS.get(objectApiName);
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
            AgentforceWorkspaceModels.CreatedRecordInfo info = buildCreatedRecordInfo(objectApiName, created, fieldMap);

            AgentforceWorkspaceModels.ChatResult result = new AgentforceWorkspaceModels.ChatResult();
            result.response = response;
            if (objectApiName == 'Task') {
                String subtype = fields.containsKey('TaskSubtype') ? String.valueOf(fields.get('TaskSubtype')) : '';
                if ('Call'.equalsIgnoreCase(subtype)) {
                    result.suggestions = new List<String>{ 'Log another call', 'Show my recent activities', 'Set a follow-up task' };
                } else {
                    result.suggestions = new List<String>{ 'Log another task', 'Show my open tasks', 'Schedule a meeting' };
                }
            } else if (objectApiName == 'Event') {
                result.suggestions = new List<String>{ 'Schedule another meeting', 'Show my upcoming events', 'Log a follow-up task' };
            } else {
                result.suggestions = new List<String>{ 'Show me all my accounts', 'Create another account' };
            }
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

    /** Build the Pass 2 prompt for create confirmation — asks the user for additional fields. */
    private static String buildCreateConfirmPrompt(String objectApiName, Map<String, Object> fields, String userName) {
        List<String> parts = new List<String>();

        parts.add('You are a helpful Salesforce assistant. ');
        parts.add(userName + ' wants to create a new ' + objectApiName + ' record.\n\n');

        parts.add('## FIELDS PROVIDED SO FAR\n');
        if (fields.isEmpty()) {
            parts.add('- None yet\n');
        } else {
            for (String fieldName : fields.keySet()) {
                parts.add('- ' + fieldName + ': ' + String.valueOf(fields.get(fieldName)) + '\n');
            }
        }

        parts.add('\n## ADDITIONAL RECOMMENDED FIELDS\n');

        List<String> recommended;
        if (objectApiName == 'Task') {
            Boolean isCall = fields.containsKey('TaskSubtype') && 'Call'.equalsIgnoreCase(String.valueOf(fields.get('TaskSubtype')));
            parts.add('These are commonly used on ' + (isCall ? 'Call logs' : 'Tasks') + ':\n');
            recommended = new List<String>{
                'WhoId (Contact/Lead — ask who the call/task was with)',
                'WhatId (Account/Opportunity — ask what record to associate it with)',
                'ActivityDate (when did/will this happen)',
                'Description (notes or details)',
                'Status (Completed for past activities, Not Started for future)',
                'Priority (High, Normal, Low)'
            };
        } else if (objectApiName == 'Event') {
            parts.add('These are commonly used on Events/Meetings:\n');
            recommended = new List<String>{
                'WhoId (Contact/Lead — ask who is attending)',
                'WhatId (Account/Opportunity — ask what record to associate it with)',
                'StartDateTime (date and time of the meeting)',
                'EndDateTime (when the meeting ends — default 30 min if not specified)',
                'Location (where the meeting is)',
                'Description (agenda or notes)'
            };
        } else {
            parts.add('These are optional but commonly used on Accounts:\n');
            recommended = new List<String>{
                'Industry', 'Type', 'Phone', 'Website',
                'BillingCity', 'BillingState',
                'Description', 'NumberOfEmployees', 'AnnualRevenue'
            };
        }
        for (String rec : recommended) {
            String fieldKey = rec.contains(' ') ? rec.substring(0, rec.indexOf(' ')) : rec;
            if (!fields.containsKey(fieldKey)) {
                parts.add('- ' + rec + '\n');
            }
        }

        parts.add('\n## INSTRUCTIONS\n');
        parts.add('Generate a conversational HTML response that:\n');
        parts.add('1. Acknowledges the request warmly\n');
        parts.add('2. Confirms the fields already provided (bold the values)\n');
        parts.add('3. For Task/Event: Ask WHO the activity is with (Contact name) and WHAT record to link it to (Account/Opportunity). If the user mentioned a contact or account name, suggest looking them up.\n');
        parts.add('4. Ask for additional details — pick the 3-4 most useful missing fields\n');
        parts.add('5. Make it clear these are optional and the user can say "create it" or "log it" whenever ready\n\n');

        parts.add('## OUTPUT FORMAT\n');
        parts.add('Clean HTML only. No markdown. No code blocks. No inline CSS or class attributes.\n');
        parts.add('Use <b>bold</b> for the record name and field values.\n');
        parts.add('Keep it concise and friendly. Address user as ' + userName + '.\n');
        parts.add('Use <ul><li> for listing the requested fields.\n\n');

        String actionVerb = (objectApiName == 'Task' || objectApiName == 'Event') ? 'Log it now' : 'Create it now';
        parts.add('After your HTML response, output:\n');
        parts.add('<SUGGESTIONS>["' + actionVerb + '", "Let me add more details"]</SUGGESTIONS>\n');

        return String.join(parts, '');
    }

    /**
     * Resolve name-based WhoId/WhatId to actual Salesforce record IDs.
     * If the value looks like a name (not a 15/18 char ID), query for the record.
     */
    private static void resolveActivityNameIds(Map<String, Object> fields) {
        // Resolve WhoId (Contact or Lead name → ID)
        if (fields.containsKey('WhoId')) {
            String whoVal = String.valueOf(fields.get('WhoId'));
            if (String.isNotBlank(whoVal) && !isRecordId(whoVal)) {
                String searchName = '%' + whoVal.trim() + '%';
                List<Contact> contacts = [SELECT Id, AccountId FROM Contact WHERE Name LIKE :searchName WITH USER_MODE LIMIT 1];
                if (!contacts.isEmpty()) {
                    fields.put('WhoId', contacts[0].Id);
                    // Auto-populate WhatId with the contact's account if not already set
                    if (!fields.containsKey('WhatId') && contacts[0].AccountId != null) {
                        fields.put('WhatId', contacts[0].AccountId);
                    }
                } else {
                    List<Lead> leads = [SELECT Id FROM Lead WHERE Name LIKE :searchName WITH USER_MODE LIMIT 1];
                    if (!leads.isEmpty()) {
                        fields.put('WhoId', leads[0].Id);
                    } else {
                        System.debug(LoggingLevel.WARN, 'Could not resolve WhoId name: ' + whoVal);
                        fields.remove('WhoId');
                    }
                }
            }
        }

        // Resolve WhatId (Account or Opportunity name → ID)
        if (fields.containsKey('WhatId')) {
            String whatVal = String.valueOf(fields.get('WhatId'));
            if (String.isNotBlank(whatVal) && !isRecordId(whatVal)) {
                String searchName = '%' + whatVal.trim() + '%';
                List<Account> accounts = [SELECT Id FROM Account WHERE Name LIKE :searchName WITH USER_MODE LIMIT 1];
                if (!accounts.isEmpty()) {
                    fields.put('WhatId', accounts[0].Id);
                } else {
                    List<Opportunity> opps = [SELECT Id FROM Opportunity WHERE Name LIKE :searchName WITH USER_MODE LIMIT 1];
                    if (!opps.isEmpty()) {
                        fields.put('WhatId', opps[0].Id);
                    } else {
                        System.debug(LoggingLevel.WARN, 'Could not resolve WhatId name: ' + whatVal);
                        fields.remove('WhatId');
                    }
                }
            }
        }
    }

    private static Boolean isRecordId(String val) {
        if (val == null || val.length() < 15) return false;
        return Pattern.matches('[a-zA-Z0-9]{15,18}', val);
    }

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
            } else if (fieldType == Schema.DisplayType.DATETIME) {
                // Handle ISO 8601 format (e.g., 2026-03-17T10:00:00)
                record.put(fieldName, Datetime.valueOf(value.replace('T', ' ')));
            } else if (fieldType == Schema.DisplayType.REFERENCE) {
                // Only set if it looks like a valid Salesforce ID
                if (isRecordId(value)) {
                    record.put(fieldName, value);
                }
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
        Map<String, Object> populated = created.getPopulatedFieldsAsMap();
        String recordUrl = '/lightning/r/' + objectApiName + '/' + created.Id + '/view';

        // Determine record name and heading based on object type
        String recordName;
        String heading;
        String verb;
        if (objectApiName == 'Task') {
            recordName = String.valueOf(populated.get('Subject'));
            String subtype = populated.containsKey('TaskSubtype') ? String.valueOf(populated.get('TaskSubtype')) : '';
            heading = 'Call'.equalsIgnoreCase(subtype) ? 'Call Logged' : 'Task Created';
            verb = 'Call'.equalsIgnoreCase(subtype) ? 'logged' : 'created';
        } else if (objectApiName == 'Event') {
            recordName = String.valueOf(populated.get('Subject'));
            heading = 'Event Scheduled';
            verb = 'scheduled';
        } else {
            recordName = String.valueOf(populated.get('Name'));
            heading = objectApiName + ' Created';
            verb = 'created';
        }
        if (recordName == null) recordName = 'Record';

        List<String> html = new List<String>();
        html.add('<h1>' + heading + '</h1>');
        html.add('<p>' + userName + ', I\'ve ' + verb + ' <a href="' + recordUrl + '"><b>' + recordName + '</b></a> successfully.</p>');

        // List the fields that were set (skip Id, Name/Subject which is already shown, and internal fields)
        Set<String> skipFields = new Set<String>{ 'Id', 'Name', 'Subject', 'OwnerId', 'TaskSubtype' };
        List<String> fieldItems = new List<String>();
        for (String fn : populated.keySet()) {
            if (skipFields.contains(fn)) continue;
            Object val = populated.get(fn);
            if (val == null || val instanceof SObject) continue;
            String displayVal = String.valueOf(val);
            if (String.isBlank(displayVal)) continue;

            // For WhoId/WhatId, try to show the relationship name instead of the raw ID
            if (fn == 'WhoId' && populated.containsKey('Who')) {
                SObject whoObj = (SObject) populated.get('Who');
                if (whoObj != null) {
                    String whoName = String.valueOf(whoObj.get('Name'));
                    String whoUrl = '/lightning/r/Contact/' + displayVal + '/view';
                    fieldItems.add('<li><b>Contact:</b> <a href="' + whoUrl + '">' + whoName + '</a></li>');
                    continue;
                }
            }
            if (fn == 'WhatId' && populated.containsKey('What')) {
                SObject whatObj = (SObject) populated.get('What');
                if (whatObj != null) {
                    String whatName = String.valueOf(whatObj.get('Name'));
                    String whatType = String.valueOf(whatObj.getSObjectType());
                    String whatUrl = '/lightning/r/' + whatType + '/' + displayVal + '/view';
                    fieldItems.add('<li><b>Related To:</b> <a href="' + whatUrl + '">' + whatName + '</a></li>');
                    continue;
                }
            }
            // Skip raw reference IDs if we couldn't resolve them
            if (fn.endsWith('Id') && fn != 'Id') continue;

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
    private static AgentforceWorkspaceModels.CreatedRecordInfo buildCreatedRecordInfo(
            String objectApiName, SObject created, Map<String, Schema.SObjectField> fieldMap) {
        Schema.SObjectType sObjType = Schema.getGlobalDescribe().get(objectApiName);
        Map<String, Object> populated = created.getPopulatedFieldsAsMap();
        String recordName;
        if (objectApiName == 'Task' || objectApiName == 'Event') {
            recordName = String.valueOf(populated.get('Subject'));
        } else {
            recordName = String.valueOf(populated.get('Name'));
        }
        if (recordName == null) recordName = 'Record';

        AgentforceWorkspaceModels.CreatedRecordInfo info = new AgentforceWorkspaceModels.CreatedRecordInfo();
        info.objectApiName = objectApiName;
        info.objectLabel = sObjType.getDescribe().getLabel();
        info.iconName = AgentforceWorkspaceQueryService.OBJECT_ICONS.containsKey(objectApiName)
            ? AgentforceWorkspaceQueryService.OBJECT_ICONS.get(objectApiName) : 'standard:record';
        info.recordId = created.Id;
        info.recordName = recordName;
        info.recordUrl = '/lightning/r/' + objectApiName + '/' + created.Id + '/view';

        // For Task/Event, extract Who (Contact) and What (Account/Opp) relationship names first
        if (objectApiName == 'Task' || objectApiName == 'Event') {
            if (populated.containsKey('Who') && populated.get('Who') != null) {
                SObject whoObj = (SObject) populated.get('Who');
                AgentforceWorkspaceModels.RecordField rf = new AgentforceWorkspaceModels.RecordField();
                rf.label = 'Contact';
                rf.value = String.valueOf(whoObj.get('Name'));
                rf.type = 'STRING';
                info.fields.add(rf);
            }
            if (populated.containsKey('What') && populated.get('What') != null) {
                SObject whatObj = (SObject) populated.get('What');
                AgentforceWorkspaceModels.RecordField rf = new AgentforceWorkspaceModels.RecordField();
                rf.label = 'Related To';
                rf.value = String.valueOf(whatObj.get('Name'));
                rf.type = 'STRING';
                info.fields.add(rf);
            }
        }

        Set<String> skipFields = new Set<String>{ 'Id', 'Name', 'Subject', 'OwnerId', 'WhoId', 'WhatId' };
        for (String fn : populated.keySet()) {
            if (skipFields.contains(fn)) continue;
            Object val = populated.get(fn);
            if (val == null || val instanceof SObject) continue;

            // Skip reference/lookup IDs
            if (fieldMap.containsKey(fn.toLowerCase())) {
                Schema.DescribeFieldResult dfr = fieldMap.get(fn.toLowerCase()).getDescribe();
                if (dfr.getType() == Schema.DisplayType.REFERENCE) continue;

                AgentforceWorkspaceModels.RecordField rf = new AgentforceWorkspaceModels.RecordField();
                rf.label = dfr.getLabel();
                rf.value = AgentforceWorkspaceQueryService.formatFieldValue(val, dfr.getType().name());
                rf.type = dfr.getType().name();
                info.fields.add(rf);
            }
        }

        return info;
    }
}
