/**
 * Record creation and update flow for the Agentforce Workspace feature.
 * Handles create confirmation, execution, field update, and success rendering.
 * Supported objects: Account, Contact, Case, Lead, Opportunity, Task, Event.
 */
public with sharing class AgentforceWorkspaceRecordCreator {

    /** Optional fields offered to the user for follow-up completion after record creation.
     *  Well-known overrides. For unlisted objects, getOptionalFieldsForObject() resolves dynamically. */
    private static final Map<String, List<String>> KNOWN_OPTIONAL_FIELDS = new Map<String, List<String>>{
        'Account' => new List<String>{ 'Phone', 'Website', 'Description', 'NumberOfEmployees', 'AnnualRevenue', 'Type' },
        'Contact' => new List<String>{ 'Phone', 'MobilePhone', 'Email', 'Title', 'Department' },
        'Case'    => new List<String>{ 'Priority', 'Type', 'Origin', 'Description' },
        'Lead'    => new List<String>{ 'Email', 'Phone', 'Title', 'Industry', 'LeadSource', 'Description' },
        'Opportunity' => new List<String>{ 'Amount', 'Probability', 'NextStep', 'Description', 'Type' },
        'Task'    => new List<String>{ 'Description', 'Priority' },
        'Event'   => new List<String>{ 'Location', 'Description' }
    };

    /** Try to parse the LLM response as a create/update action JSON. Returns null if not an action. */
    public static Map<String, Object> parseCreateAction(String response) {
        if (String.isBlank(response)) return null;
        String cleaned = response.trim();
        if (cleaned.startsWith('```')) {
            Integer endBlock = cleaned.lastIndexOf('```');
            if (endBlock > 3) {
                cleaned = cleaned.substring(cleaned.indexOf('\n') + 1, endBlock).trim();
            }
        }
        try {
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(cleaned);
            // Recognize both single {"action":...} and multi {"actions":[...]}
            if (parsed.containsKey('action') || parsed.containsKey('actions')) {
                return parsed;
            }
        } catch (Exception e) {
            // Not an action JSON — fall through to normal SOQL parsing
        }
        return null;
    }

    /** Handle a create confirmation: ask the user for additional fields before executing. */
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

    /** Handle create execution: insert the record, surface blank optional fields for follow-up. */
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

        if (!AgentforceWorkspaceSchemaService.isCreateable(objectApiName)) {
            errorResult.response = '<p>You don\'t have permission to create ' + objectApiName + ' records, or the object does not exist. Please check your access and try again.</p>';
            return errorResult;
        }

        // Ensure OwnerId is set for activities
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
            if (!sObjType.getDescribe().isCreateable()) {
                errorResult.response = '<p>You don\'t have permission to create ' + objectApiName + ' records.</p>';
                return errorResult;
            }

            SObject newRecord = sObjType.newSObject();
            Map<String, Schema.SObjectField> fieldMap = sObjType.getDescribe().fields.getMap();

            // Resolve name-based reference fields to Salesforce IDs
            resolveReferenceIds(objectApiName, fields);

            // Fix Contact name fields — guard against LLM putting full name in both First/Last
            if (objectApiName == 'Contact' || objectApiName == 'Lead') {
                fixPersonNameFields(fields);
            }

            for (String fieldName : fields.keySet()) {
                setTypedFieldValue(newRecord, fieldName, String.valueOf(fields.get(fieldName)), fieldMap);
            }

            insert newRecord;

            // Query the created record back with all display + optional fields
            Set<String> queryFieldSet = new Set<String>{ 'Id' };
            String defaultFields = AgentforceWorkspaceQueryService.DEFAULT_LIST_FIELDS.get(objectApiName);
            if (defaultFields != null) {
                for (String f : defaultFields.split(',')) queryFieldSet.add(f.trim());
            }
            for (String f : fields.keySet()) {
                if (fieldMap.containsKey(f.toLowerCase()) &&
                    fieldMap.get(f.toLowerCase()).getDescribe().getType() != Schema.DisplayType.REFERENCE) {
                    queryFieldSet.add(f);
                }
            }
            // Case needs auto-generated CaseNumber
            if (objectApiName == 'Case') {
                queryFieldSet.addAll(new Set<String>{ 'CaseNumber', 'Subject', 'Status', 'Priority' });
            }
            // Contact and Lead get a computed Name field
            if (objectApiName == 'Contact' || objectApiName == 'Lead') {
                queryFieldSet.add('Name');
            }
            // Also query optional fields so we can identify which are still blank
            List<String> optFields = getOptionalFieldsForObject(objectApiName);
            if (optFields != null) queryFieldSet.addAll(new Set<String>(optFields));

            String queryStr = 'SELECT ' + String.join(new List<String>(queryFieldSet), ', ') +
                              ' FROM ' + objectApiName +
                              ' WHERE Id = \'' + String.escapeSingleQuotes(String.valueOf(newRecord.Id)) + '\'';
            List<SObject> results = Database.query(queryStr);

            if (results.isEmpty()) {
                errorResult.response = '<p>Record was created but could not be retrieved. Record ID: ' + newRecord.Id + '</p>';
                return errorResult;
            }

            SObject created = results[0];

            String response = buildCreateSuccessHtml(objectApiName, created, userName, fieldMap);
            AgentforceWorkspaceModels.CreatedRecordInfo info = buildCreatedRecordInfo(objectApiName, created, fieldMap);

            AgentforceWorkspaceModels.ChatResult result = new AgentforceWorkspaceModels.ChatResult();
            result.createdRecord = info;

            // Surface blank optional fields for the user to fill out
            AgentforceWorkspaceModels.PendingUpdate pu = buildPendingUpdate(newRecord.Id, objectApiName, created, fieldMap);
            if (pu != null) {
                result.pendingUpdate = pu;
                response += buildPendingUpdateHtml(pu);
            }

            result.response = response;
            result.suggestions = buildCreateSuggestions(objectApiName, fields);
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

    /** Handle a record field update (follow-up after creation). */
    public static AgentforceWorkspaceModels.ChatResult handleUpdateExecute(
            Map<String, Object> actionResult, String userName) {
        AgentforceWorkspaceModels.ChatResult errorResult = new AgentforceWorkspaceModels.ChatResult();
        String recordId = (String) actionResult.get('recordId');
        String objectApiName = (String) actionResult.get('objectApiName');
        Map<String, Object> fields = actionResult.containsKey('fields')
            ? (Map<String, Object>) actionResult.get('fields')
            : new Map<String, Object>();

        if (String.isBlank(recordId) || String.isBlank(objectApiName) || fields.isEmpty()) {
            errorResult.response = '<p>I need to know which record to update and what fields to change.</p>';
            return errorResult;
        }

        try {
            Schema.SObjectType sObjType = Schema.getGlobalDescribe().get(objectApiName);
            if (sObjType == null) {
                errorResult.response = '<p>Unknown object type: ' + objectApiName + '</p>';
                return errorResult;
            }
            if (!sObjType.getDescribe().isUpdateable()) {
                errorResult.response = '<p>You don\'t have permission to update ' + objectApiName + ' records.</p>';
                return errorResult;
            }

            resolveReferenceIds(objectApiName, fields);

            SObject record = sObjType.newSObject(recordId);
            Map<String, Schema.SObjectField> fieldMap = sObjType.getDescribe().fields.getMap();

            for (String fieldName : fields.keySet()) {
                setTypedFieldValue(record, fieldName, String.valueOf(fields.get(fieldName)), fieldMap);
            }

            update record;

            // Query back for display
            Set<String> queryFieldSet = new Set<String>{ 'Id' };
            String defaultFields = AgentforceWorkspaceQueryService.DEFAULT_LIST_FIELDS.get(objectApiName);
            if (defaultFields != null) {
                for (String f : defaultFields.split(',')) queryFieldSet.add(f.trim());
            }
            for (String f : fields.keySet()) queryFieldSet.add(f);
            if (objectApiName == 'Case') {
                queryFieldSet.addAll(new Set<String>{ 'CaseNumber', 'Subject', 'Status', 'Priority' });
            }
            if (objectApiName == 'Contact' || objectApiName == 'Lead') {
                queryFieldSet.add('Name');
            }

            String queryStr = 'SELECT ' + String.join(new List<String>(queryFieldSet), ', ') +
                              ' FROM ' + objectApiName +
                              ' WHERE Id = \'' + String.escapeSingleQuotes(recordId) + '\'';
            List<SObject> results = Database.query(queryStr);

            if (results.isEmpty()) {
                errorResult.response = '<p>Record was updated but could not be retrieved.</p>';
                errorResult.pendingUpdateCleared = true;
                return errorResult;
            }

            SObject updated = results[0];
            String recordName = getRecordName(objectApiName, updated);
            String recordUrl = '/lightning/r/' + objectApiName + '/' + recordId + '/view';

            List<String> fieldItems = new List<String>();
            for (String fn : fields.keySet()) {
                String label = fn;
                if (fieldMap.containsKey(fn.toLowerCase())) {
                    label = fieldMap.get(fn.toLowerCase()).getDescribe().getLabel();
                }
                Object setVal = fields.get(fn);
                String displayVal = setVal != null ? String.valueOf(setVal) : '';
                if (String.isNotBlank(displayVal) && displayVal != 'null') {
                    fieldItems.add('<li><b>' + label + ':</b> ' + displayVal + '</li>');
                }
            }

            AgentforceWorkspaceModels.ChatResult result = new AgentforceWorkspaceModels.ChatResult();
            result.response = '<h1>' + sObjType.getDescribe().getLabel() + ' Updated</h1>'
                + '<p>' + userName + ', I\'ve updated <a href="' + recordUrl + '"><b>' + recordName + '</b></a>.'
                + (fieldItems.isEmpty() ? '' : '<ul>' + String.join(fieldItems, '') + '</ul>') + '</p>';
            result.updatedRecord = buildCreatedRecordInfo(objectApiName, updated, fieldMap);
            result.pendingUpdateCleared = true;
            result.suggestions = new List<String>{ 'Show me this record', 'Create another record', 'What else needs attention?' };
            return result;

        } catch (DmlException e) {
            errorResult.response = '<p>I wasn\'t able to update the record: ' + e.getDmlMessage(0) + '</p>';
            errorResult.pendingUpdateCleared = true;
            return errorResult;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Update execution error: ' + e.getMessage());
            errorResult.response = '<p>Something went wrong while updating: ' + e.getMessage() + '</p>';
            errorResult.pendingUpdateCleared = true;
            return errorResult;
        }
    }

    /**
     * Handle multiple sequential record creates from one user message (e.g. "create an Account AND a Contact on it").
     * Because Salesforce DML is visible within the same transaction, the Contact's AccountId name-lookup
     * will find the Account just inserted in step 1 — no manual ID threading required.
     */
    public static AgentforceWorkspaceModels.ChatResult handleMultiCreateExecute(
            Map<String, Object> multiAction, String userName, String modelName) {

        List<Object> actionsList = (List<Object>) multiAction.get('actions');
        if (actionsList == null || actionsList.isEmpty()) {
            AgentforceWorkspaceModels.ChatResult err = new AgentforceWorkspaceModels.ChatResult();
            err.response = '<p>No actions found in the multi-create request.</p>';
            return err;
        }

        List<String> htmlParts = new List<String>();
        List<AgentforceWorkspaceModels.CreatedRecordInfo> allRecords = new List<AgentforceWorkspaceModels.CreatedRecordInfo>();
        List<AgentforceWorkspaceModels.PendingUpdate> allPendingUpdates = new List<AgentforceWorkspaceModels.PendingUpdate>();
        List<String> combinedSuggestions = new List<String>();

        for (Object actionObj : actionsList) {
            Map<String, Object> actionMap = (Map<String, Object>) actionObj;
            String action = (String) actionMap.get('action');

            if (action == 'create_execute') {
                AgentforceWorkspaceModels.ChatResult stepResult =
                    handleCreateExecute(actionMap, userName, modelName);
                if (stepResult != null && String.isNotBlank(stepResult.response)) {
                    // Strip the per-step follow-up prompt — we'll consolidate one at the end
                    String stepHtml = stepResult.response;
                    Integer followUpIdx = stepHtml.indexOf('<hr/><p>Would you like to fill out');
                    if (followUpIdx != -1) {
                        stepHtml = stepHtml.substring(0, followUpIdx);
                    }
                    htmlParts.add(stepHtml);
                }
                if (stepResult != null && stepResult.createdRecord != null) {
                    allRecords.add(stepResult.createdRecord);
                    if (stepResult.pendingUpdate != null) allPendingUpdates.add(stepResult.pendingUpdate);
                    if (!stepResult.suggestions.isEmpty()) combinedSuggestions = stepResult.suggestions;
                }
            } else if (action == 'create') {
                AgentforceWorkspaceModels.ChatResult stepResult =
                    handleCreateConfirm(actionMap, userName, modelName);
                if (stepResult != null && String.isNotBlank(stepResult.response)) {
                    htmlParts.add(stepResult.response);
                }
            }
        }

        // Add one consolidated follow-up prompt at the end (if any records have blank optional fields)
        String consolidatedFollowUp = buildConsolidatedPendingUpdateHtml(allPendingUpdates);

        AgentforceWorkspaceModels.ChatResult result = new AgentforceWorkspaceModels.ChatResult();
        result.response = String.join(htmlParts, '') + consolidatedFollowUp;
        result.allCreatedRecords = allRecords;
        result.createdRecord = allRecords.isEmpty() ? null : allRecords[0];
        // Track the first record's pending update for the field-fill flow
        result.pendingUpdate = allPendingUpdates.isEmpty() ? null : allPendingUpdates[0];
        result.suggestions = combinedSuggestions.isEmpty()
            ? new List<String>{ 'Show me these records', 'Create another record' }
            : combinedSuggestions;
        return result;
    }

    /**
     * Minimal safety net: if the LLM accidentally put the same value in both
     * FirstName and LastName, clear FirstName so the name isn't duplicated.
     * Name parsing itself is intentionally left to the LLM.
     */
    private static void fixPersonNameFields(Map<String, Object> fields) {
        String fn = fields.containsKey('FirstName') ? String.valueOf(fields.get('FirstName')) : null;
        String ln = fields.containsKey('LastName')  ? String.valueOf(fields.get('LastName'))  : null;
        if (fn == 'null') fn = null;
        if (ln == 'null') ln = null;
        if (String.isNotBlank(fn) && fn == ln) {
            fields.remove('FirstName');
        }
    }

    /**
     * Build a single consolidated follow-up HTML for all records created in a multi-create.
     * Shows blank fields per-record so the user can fill them all at once.
     */
    private static String buildConsolidatedPendingUpdateHtml(List<AgentforceWorkspaceModels.PendingUpdate> updates) {
        if (updates.isEmpty()) return '';
        if (updates.size() == 1) return buildPendingUpdateHtml(updates[0]);

        List<String> sections = new List<String>();
        for (AgentforceWorkspaceModels.PendingUpdate pu : updates) {
            List<String> items = new List<String>();
            for (AgentforceWorkspaceModels.FieldPromptItem item : pu.blankFields) {
                items.add('<li>' + item.label + '</li>');
            }
            sections.add('<p><b>' + pu.recordName + '</b> (' + pu.objectApiName + ')</p>'
                + '<ul>' + String.join(items, '') + '</ul>');
        }
        return '<hr/><p>Would you like to fill out a few more fields on the records I just created?</p>'
            + String.join(sections, '')
            + '<p>Just tell me which ones to update and their values — or say <b>"skip"</b> if everything looks good.</p>';
    }

    /** Handle a user declining to fill out additional fields. */
    public static AgentforceWorkspaceModels.ChatResult handleUpdateCancel(String userName) {
        AgentforceWorkspaceModels.ChatResult result = new AgentforceWorkspaceModels.ChatResult();
        result.response = '<p>No problem, ' + userName + '! The record has been saved as-is. You can always update it later.</p>';
        result.pendingUpdateCleared = true;
        result.suggestions = new List<String>{ 'Show my recent records', 'Create another record' };
        return result;
    }

    /**
     * Invoked when the LLM emits {"action":"bulk_update_preview",...} for a set of
     * context record IDs that need user confirmation before changes are applied.
     * Queries the records, builds the preview HTML, and sets pendingBulkUpdate
     * so the next user turn can confirm or cancel.
     */
    public static AgentforceWorkspaceModels.ChatResult handleBulkUpdatePreviewAction(
            Map<String, Object> actionResult, String userName) {
        AgentforceWorkspaceModels.ChatResult errorResult = new AgentforceWorkspaceModels.ChatResult();

        String objectApiName = actionResult.get('objectApiName') != null
            ? String.valueOf(actionResult.get('objectApiName')) : null;

        List<String> recordIds = new List<String>();
        String idError = normalizeStringList(actionResult.get('recordIds'), recordIds);
        if (idError != null) {
            errorResult.response = '<p>' + idError + '</p>';
            return errorResult;
        }

        Map<String, String> fields = new Map<String, String>();
        String fieldError = normalizeStringMap(actionResult.get('fields'), fields);
        if (fieldError != null) {
            errorResult.response = '<p>' + fieldError + '</p>';
            return errorResult;
        }

        if (String.isBlank(objectApiName) || recordIds.isEmpty() || fields.isEmpty()) {
            errorResult.response = '<p>I need an object type, record IDs, and field values to preview a bulk update.</p>';
            return errorResult;
        }

        List<String> safeIds = new List<String>();
        for (String rid : recordIds) {
            if (isRecordId(rid)) safeIds.add(rid);
        }
        if (safeIds.isEmpty()) {
            errorResult.response = '<p>No valid record IDs found for the bulk update preview.</p>';
            return errorResult;
        }

        Schema.SObjectType sObjType = Schema.getGlobalDescribe().get(objectApiName);
        if (sObjType == null) {
            errorResult.response = '<p>Unknown object type: ' + objectApiName + '</p>';
            return errorResult;
        }

        // Pick the right name field for the object
        String nameSelect = 'Name';
        if (objectApiName == 'Task' || objectApiName == 'Event') {
            nameSelect = 'Subject';
        } else if (objectApiName == 'Case') {
            nameSelect = 'CaseNumber, Subject';
        }

        try {
            String escapedIds = '\'' + String.join(safeIds, '\',\'') + '\'';
            String soql = 'SELECT Id, ' + nameSelect + ' FROM ' + objectApiName
                + ' WHERE Id IN (' + escapedIds + ') WITH USER_MODE LIMIT 200';
            List<SObject> records = Database.query(soql);
            return buildBulkUpdatePreview(objectApiName, records, fields, userName);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'handleBulkUpdatePreviewAction error: ' + e.getMessage());
            errorResult.response = '<p>Something went wrong preparing the bulk update preview: ' + e.getMessage() + '</p>';
            return errorResult;
        }
    }

    /** Build a pending bulk-update payload and confirmation preview. */
    public static AgentforceWorkspaceModels.ChatResult buildBulkUpdatePreview(
            String objectApiName,
            List<SObject> matchedRecords,
            Map<String, String> fields,
            String userName) {
        AgentforceWorkspaceModels.ChatResult result = new AgentforceWorkspaceModels.ChatResult();
        if (String.isBlank(objectApiName) || matchedRecords == null || matchedRecords.isEmpty() || fields == null || fields.isEmpty()) {
            result.response = '<p>I need matched records and at least one field before I can preview a bulk update.</p>';
            return result;
        }
        if (matchedRecords.size() > 10) {
            result.response = '<p>Please preview 10 records or fewer in a single request.</p>';
            return result;
        }

        Schema.SObjectType sObjType = Schema.getGlobalDescribe().get(objectApiName);
        if (sObjType == null) {
            result.response = '<p>Unknown object type: ' + objectApiName + '</p>';
            return result;
        }

        Map<String, Schema.SObjectField> fieldMap = sObjType.getDescribe().fields.getMap();
        AgentforceWorkspaceModels.PendingBulkUpdate pending = new AgentforceWorkspaceModels.PendingBulkUpdate();
        pending.objectApiName = objectApiName;
        pending.matchedCount = matchedRecords.size();
        pending.fields.putAll(fields);

        for (SObject matchedRecord : matchedRecords) {
            if (matchedRecord == null || matchedRecord.Id == null) continue;
            pending.recordIds.add(String.valueOf(matchedRecord.Id));
            AgentforceWorkspaceModels.BulkUpdateRecordRef recordRef =
                new AgentforceWorkspaceModels.BulkUpdateRecordRef();
            recordRef.recordId = String.valueOf(matchedRecord.Id);
            recordRef.recordName = getRecordName(objectApiName, matchedRecord);
            pending.records.add(recordRef);
        }

        result.pendingBulkUpdate = pending;
        result.response = buildBulkUpdatePreviewHtml(userName, sObjType.getDescribe().getLabel(), pending, fieldMap);
        result.suggestions = new List<String>{ 'Apply these updates', 'Cancel' };
        return result;
    }

    /** Execute a confirmed bulk update across 1-10 records of the same object type. */
    public static AgentforceWorkspaceModels.ChatResult handleBulkUpdateExecute(
            Map<String, Object> actionResult,
            String userName) {
        AgentforceWorkspaceModels.ChatResult result = new AgentforceWorkspaceModels.ChatResult();
        if (actionResult == null) {
            result.response = '<p>I need bulk update details before I can make changes.</p>';
            return result;
        }

        Object objectApiNameValue = actionResult.get('objectApiName');
        String objectApiName = objectApiNameValue == null ? null : String.valueOf(objectApiNameValue);

        List<String> recordIds = new List<String>();
        String recordIdPayloadError = normalizeStringList(actionResult.get('recordIds'), recordIds);
        if (recordIdPayloadError != null) {
            result.response = '<p>' + recordIdPayloadError + '</p>';
            return result;
        }

        Map<String, String> fields = new Map<String, String>();
        String fieldPayloadError = normalizeStringMap(actionResult.get('fields'), fields);
        if (fieldPayloadError != null) {
            result.response = '<p>' + fieldPayloadError + '</p>';
            return result;
        }

        if (String.isBlank(objectApiName)) {
            result.response = '<p>I need to know which object type to update.</p>';
            return result;
        }
        if (recordIds.isEmpty()) {
            result.response = '<p>I need at least one record to update.</p>';
            return result;
        }
        if (recordIds.size() > 10) {
            result.response = '<p>Please update 10 records or fewer in a single request.</p>';
            return result;
        }
        if (fields.isEmpty()) {
            result.response = '<p>I need at least one field value before I can update these records.</p>';
            return result;
        }

        Schema.SObjectType sObjType = Schema.getGlobalDescribe().get(objectApiName);
        if (sObjType == null) {
            result.response = '<p>Unknown object type: ' + objectApiName + '</p>';
            return result;
        }

        Schema.DescribeSObjectResult objectDescribe = sObjType.getDescribe();
        if (!objectDescribe.isUpdateable()) {
            result.response = '<p>You don\'t have permission to update ' + objectApiName + ' records.</p>';
            return result;
        }

        Map<String, Schema.SObjectField> fieldMap = objectDescribe.fields.getMap();
        String fieldValidationError = validateBulkUpdateFields(fields, fieldMap);
        if (fieldValidationError != null) {
            result.response = '<p>' + fieldValidationError + '</p>';
            return result;
        }

        Map<String, Object> typedFields = new Map<String, Object>();
        String fieldValueError = convertBulkFieldValues(fields, fieldMap, typedFields);
        if (fieldValueError != null) {
            result.response = '<p>' + fieldValueError + '</p>';
            return result;
        }

        List<SObject> recordsToUpdate = new List<SObject>();
        for (String recordIdValue : recordIds) {
            if (!isRecordId(recordIdValue)) {
                result.response = '<p>I found an invalid record Id in this bulk update request.</p>';
                return result;
            }

            Id recordId = (Id) recordIdValue;
            if (recordId.getSObjectType() != sObjType) {
                result.response = '<p>I can only update one object type per request.</p>';
                return result;
            }

            SObject recordToUpdate = sObjType.newSObject(recordId);
            for (String fieldName : typedFields.keySet()) {
                recordToUpdate.put(fieldName, typedFields.get(fieldName));
            }
            recordsToUpdate.add(recordToUpdate);
        }

        try {
            update recordsToUpdate;

            result.response = buildBulkUpdateSuccessHtml(
                userName,
                objectDescribe.getLabel(),
                recordsToUpdate.size(),
                typedFields,
                fieldMap
            );
            result.pendingBulkUpdateCleared = true;
            result.suggestions = new List<String>{ 'Show updated records', 'Make another update' };
            return result;
        } catch (DmlException e) {
            result.response = '<p>I wasn\'t able to finish the bulk update: ' + e.getDmlMessage(0) + '</p>';
            return result;
        }
    }

    /** Clear a pending bulk-update preview without applying any changes. */
    public static AgentforceWorkspaceModels.ChatResult handleBulkUpdateCancel(String userName) {
        AgentforceWorkspaceModels.ChatResult result = new AgentforceWorkspaceModels.ChatResult();
        result.response = '<p>No changes were made, ' + userName + '. I cleared the pending bulk update.</p>';
        result.pendingBulkUpdateCleared = true;
        result.suggestions = new List<String>{ 'Review another update', 'Show my records' };
        return result;
    }

    // ─── Private Helpers ──────────────────────────────────────────────────────

    private static String normalizeStringList(Object rawValue, List<String> values) {
        if (rawValue == null) return null;

        try {
            for (Object item : (List<Object>) rawValue) {
                if (item != null) values.add(String.valueOf(item));
            }
            return null;
        } catch (Exception e) {
            return 'I couldn\'t read the recordIds payload format for this bulk update.';
        }
    }

    private static String normalizeStringMap(Object rawValue, Map<String, String> values) {
        if (rawValue == null) return null;

        try {
            Map<String, Object> rawMap = (Map<String, Object>) rawValue;
            for (String key : rawMap.keySet()) {
                values.put(key, rawMap.get(key) != null ? String.valueOf(rawMap.get(key)) : null);
            }
            return null;
        } catch (Exception e) {
            return 'I couldn\'t read the fields payload format for this bulk update.';
        }
    }

    private static String validateBulkUpdateFields(
            Map<String, String> fields,
            Map<String, Schema.SObjectField> fieldMap) {
        for (String fieldName : fields.keySet()) {
            Schema.SObjectField fieldToken = fieldMap.get(fieldName.toLowerCase());
            if (fieldToken == null) {
                return 'I couldn\'t find the field ' + fieldName + ' on this object.';
            }
            if (!fieldToken.getDescribe().isUpdateable()) {
                return 'You don\'t have permission to update the ' + fieldToken.getDescribe().getLabel() + ' field.';
            }
        }
        return null;
    }

    private static String convertBulkFieldValues(
            Map<String, String> fields,
            Map<String, Schema.SObjectField> fieldMap,
            Map<String, Object> typedValues) {
        for (String fieldName : fields.keySet()) {
            Schema.SObjectField fieldToken = fieldMap.get(fieldName.toLowerCase());
            Schema.DescribeFieldResult fieldDescribe = fieldToken.getDescribe();
            String rawValue = fields.get(fieldName);

            if (String.isBlank(rawValue) || rawValue == 'null') {
                return 'Please provide a valid value for ' + fieldDescribe.getLabel() + '.';
            }

            try {
                Schema.DisplayType fieldType = fieldDescribe.getType();
                if (fieldType == Schema.DisplayType.STRING ||
                    fieldType == Schema.DisplayType.TEXTAREA ||
                    fieldType == Schema.DisplayType.URL ||
                    fieldType == Schema.DisplayType.EMAIL ||
                    fieldType == Schema.DisplayType.PHONE ||
                    fieldType == Schema.DisplayType.PICKLIST) {
                    typedValues.put(fieldName, rawValue);
                } else if (fieldType == Schema.DisplayType.CURRENCY ||
                           fieldType == Schema.DisplayType.DOUBLE ||
                           fieldType == Schema.DisplayType.PERCENT) {
                    String cleanedDecimal = rawValue.replaceAll('[^0-9.\\-]', '');
                    if (String.isBlank(cleanedDecimal)) {
                        return 'Please provide a valid value for ' + fieldDescribe.getLabel() + '.';
                    }
                    typedValues.put(fieldName, Decimal.valueOf(cleanedDecimal));
                } else if (fieldType == Schema.DisplayType.INTEGER) {
                    String cleanedInteger = rawValue.replaceAll('[^0-9\\-]', '');
                    if (String.isBlank(cleanedInteger)) {
                        return 'Please provide a valid value for ' + fieldDescribe.getLabel() + '.';
                    }
                    typedValues.put(fieldName, Integer.valueOf(cleanedInteger));
                } else if (fieldType == Schema.DisplayType.DATE) {
                    typedValues.put(fieldName, Date.valueOf(rawValue));
                } else if (fieldType == Schema.DisplayType.DATETIME) {
                    typedValues.put(fieldName, Datetime.valueOf(rawValue.replace('T', ' ')));
                } else if (fieldType == Schema.DisplayType.REFERENCE) {
                    if (!isRecordId(rawValue)) {
                        return 'Please provide a valid Salesforce record Id for ' + fieldDescribe.getLabel() + '.';
                    }
                    typedValues.put(fieldName, rawValue);
                } else if (fieldType == Schema.DisplayType.BOOLEAN) {
                    String lowered = rawValue.toLowerCase();
                    if (lowered != 'true' && lowered != 'false') {
                        return 'Please provide a valid value for ' + fieldDescribe.getLabel() + '.';
                    }
                    typedValues.put(fieldName, lowered == 'true');
                } else {
                    typedValues.put(fieldName, rawValue);
                }
            } catch (Exception e) {
                return 'Please provide a valid value for ' + fieldDescribe.getLabel() + '.';
            }
        }

        return typedValues.isEmpty()
            ? 'I couldn\'t apply any of the requested bulk field updates.'
            : null;
    }

    private static String buildBulkUpdatePreviewHtml(
            String userName,
            String objectLabel,
            AgentforceWorkspaceModels.PendingBulkUpdate pending,
            Map<String, Schema.SObjectField> fieldMap) {
        List<String> fieldItems = new List<String>();
        for (String fieldName : pending.fields.keySet()) {
            fieldItems.add('<li><b>' + getFieldLabel(fieldName, fieldMap) + ':</b> ' + pending.fields.get(fieldName) + '</li>');
        }

        List<String> recordItems = new List<String>();
        for (AgentforceWorkspaceModels.BulkUpdateRecordRef recordRef : pending.records) {
            recordItems.add('<li>' + recordRef.recordName + '</li>');
        }

        return '<h1>Bulk Update Preview</h1>'
            + '<p>' + userName + ', I found ' + pending.matchedCount + ' ' + objectLabel
            + (pending.matchedCount == 1 ? ' record' : ' records') + ' ready for update.</p>'
            + '<p>Please confirm I should apply these field changes:</p>'
            + '<ul>' + String.join(fieldItems, '') + '</ul>'
            + '<p>Matched records:</p>'
            + '<ul>' + String.join(recordItems, '') + '</ul>';
    }

    private static String buildBulkUpdateSuccessHtml(
            String userName,
            String objectLabel,
            Integer recordCount,
            Map<String, Object> fields,
            Map<String, Schema.SObjectField> fieldMap) {
        List<String> fieldItems = new List<String>();
        for (String fieldName : fields.keySet()) {
            fieldItems.add('<li><b>' + getFieldLabel(fieldName, fieldMap) + ':</b> ' + String.valueOf(fields.get(fieldName)) + '</li>');
        }

        return '<h1>Bulk Update Complete</h1>'
            + '<p>' + userName + ', I updated ' + recordCount + ' ' + objectLabel
            + (recordCount == 1 ? ' record.' : ' records.') + '</p>'
            + '<ul>' + String.join(fieldItems, '') + '</ul>';
    }

    private static String getFieldLabel(String fieldName, Map<String, Schema.SObjectField> fieldMap) {
        Schema.SObjectField fieldToken = fieldMap.get(fieldName.toLowerCase());
        return fieldToken != null ? fieldToken.getDescribe().getLabel() : fieldName;
    }

    /**
     * Resolve name-based reference field values to actual Salesforce IDs.
     * Handles WhoId/WhatId for activities and AccountId/ContactId for other objects.
     */
    private static void resolveReferenceIds(String objectApiName, Map<String, Object> fields) {
        if (objectApiName == 'Task' || objectApiName == 'Event') {
            resolveActivityNameIds(fields);
            return;
        }

        // AccountId resolution for Contact, Case, Opportunity
        if (fields.containsKey('AccountId')) {
            String val = String.valueOf(fields.get('AccountId'));
            if (String.isNotBlank(val) && !isRecordId(val)) {
                String searchName = '%' + val.trim() + '%';
                List<Account> accts = [SELECT Id FROM Account WHERE Name LIKE :searchName WITH USER_MODE LIMIT 1];
                if (!accts.isEmpty()) {
                    fields.put('AccountId', accts[0].Id);
                } else {
                    System.debug(LoggingLevel.WARN, 'Could not resolve AccountId name: ' + val);
                    fields.remove('AccountId');
                }
            }
        }

        // ContactId resolution for Case
        if (objectApiName == 'Case' && fields.containsKey('ContactId')) {
            String val = String.valueOf(fields.get('ContactId'));
            if (String.isNotBlank(val) && !isRecordId(val)) {
                String searchName = '%' + val.trim() + '%';
                List<Contact> contacts = [SELECT Id FROM Contact WHERE Name LIKE :searchName WITH USER_MODE LIMIT 1];
                if (!contacts.isEmpty()) {
                    fields.put('ContactId', contacts[0].Id);
                } else {
                    System.debug(LoggingLevel.WARN, 'Could not resolve ContactId name: ' + val);
                    fields.remove('ContactId');
                }
            }
        }
    }

    /**
     * Resolve name-based WhoId/WhatId to actual Salesforce record IDs.
     * If the value looks like a name (not a 15/18 char ID), query for the record.
     */
    private static void resolveActivityNameIds(Map<String, Object> fields) {
        if (fields.containsKey('WhoId')) {
            String whoVal = String.valueOf(fields.get('WhoId'));
            if (String.isNotBlank(whoVal) && !isRecordId(whoVal)) {
                String searchName = '%' + whoVal.trim() + '%';
                List<Contact> contacts = [SELECT Id, AccountId FROM Contact WHERE Name LIKE :searchName WITH USER_MODE LIMIT 1];
                if (!contacts.isEmpty()) {
                    fields.put('WhoId', contacts[0].Id);
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

    /** Determine the record's display name based on object type. */
    private static String getRecordName(String objectApiName, SObject record) {
        Map<String, Object> populated = record.getPopulatedFieldsAsMap();
        if (objectApiName == 'Task' || objectApiName == 'Event') {
            String s = String.valueOf(populated.get('Subject'));
            return s != null ? s : 'Record';
        }
        if (objectApiName == 'Case') {
            String caseNum = populated.get('CaseNumber') != null ? String.valueOf(populated.get('CaseNumber')) : null;
            String subject = populated.get('Subject') != null ? String.valueOf(populated.get('Subject')) : null;
            if (caseNum != null && subject != null) return 'Case ' + caseNum + ': ' + subject;
            if (caseNum != null) return 'Case ' + caseNum;
            return 'Case';
        }
        String name = populated.get('Name') != null ? String.valueOf(populated.get('Name')) : null;
        return name != null ? name : 'Record';
    }

    /** Build the PendingUpdate object listing blank optional fields on the newly created record. */
    private static AgentforceWorkspaceModels.PendingUpdate buildPendingUpdate(
            Id recordId, String objectApiName, SObject createdRecord,
            Map<String, Schema.SObjectField> fieldMap) {
        List<String> optFields = getOptionalFieldsForObject(objectApiName);
        if (optFields == null || optFields.isEmpty()) return null;

        Map<String, Object> populated = createdRecord.getPopulatedFieldsAsMap();
        List<AgentforceWorkspaceModels.FieldPromptItem> blankFields = new List<AgentforceWorkspaceModels.FieldPromptItem>();

        for (String fn : optFields) {
            Object val = populated.get(fn);
            Boolean isBlank = (val == null) || (val instanceof String && String.isBlank((String) val));
            if (isBlank) {
                AgentforceWorkspaceModels.FieldPromptItem item = new AgentforceWorkspaceModels.FieldPromptItem();
                item.apiName = fn;
                item.label = fieldMap.containsKey(fn.toLowerCase())
                    ? fieldMap.get(fn.toLowerCase()).getDescribe().getLabel() : fn;
                blankFields.add(item);
            }
        }

        if (blankFields.isEmpty()) return null;

        AgentforceWorkspaceModels.PendingUpdate pu = new AgentforceWorkspaceModels.PendingUpdate();
        pu.recordId = String.valueOf(recordId);
        pu.objectApiName = objectApiName;
        pu.recordName = getRecordName(objectApiName, createdRecord);
        pu.blankFields = blankFields;
        return pu;
    }

    /** Build the follow-up HTML asking the user if they want to fill out blank fields. */
    private static String buildPendingUpdateHtml(AgentforceWorkspaceModels.PendingUpdate pu) {
        List<String> labels = new List<String>();
        for (AgentforceWorkspaceModels.FieldPromptItem item : pu.blankFields) {
            labels.add('<li>' + item.label + '</li>');
        }
        return '<hr/><p>Would you like to fill out a few more fields? These are currently empty:</p>'
            + '<ul>' + String.join(labels, '') + '</ul>'
            + '<p>Just tell me which ones to update and their values — or say <b>"skip"</b> if everything looks good.</p>';
    }

    /** Build contextual suggestions based on the object type just created. */
    private static List<String> buildCreateSuggestions(String objectApiName, Map<String, Object> fields) {
        if (objectApiName == 'Task') {
            String subtype = fields.containsKey('TaskSubtype') ? String.valueOf(fields.get('TaskSubtype')) : '';
            if ('Call'.equalsIgnoreCase(subtype)) {
                return new List<String>{ 'Log another call', 'Show my recent activities', 'Set a follow-up task' };
            }
            return new List<String>{ 'Log another task', 'Show my open tasks', 'Schedule a meeting' };
        }
        if (objectApiName == 'Event') {
            return new List<String>{ 'Schedule another meeting', 'Show my upcoming events', 'Log a follow-up task' };
        }
        if (objectApiName == 'Contact') {
            return new List<String>{ 'Show my contacts', 'Log a call with this contact', 'Create another contact' };
        }
        if (objectApiName == 'Case') {
            return new List<String>{ 'Show open cases', 'Create another case', 'Assign this case' };
        }
        if (objectApiName == 'Lead') {
            return new List<String>{ 'Show my leads', 'Create another lead', 'Convert this lead' };
        }
        if (objectApiName == 'Opportunity') {
            return new List<String>{ 'Show my pipeline', 'Create another opportunity', 'Update the stage' };
        }
        // Account default
        return new List<String>{ 'Show me all my accounts', 'Create another account' };
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
                'WhoId (Contact/Lead — who the call/task was with)',
                'WhatId (Account/Opportunity — what record to link it to)',
                'ActivityDate (when this happened)',
                'Description (notes or details)',
                'Status (Completed for past, Not Started for future)',
                'Priority (High, Normal, Low)'
            };
        } else if (objectApiName == 'Event') {
            parts.add('These are commonly used on Events/Meetings:\n');
            recommended = new List<String>{
                'WhoId (Contact/Lead — who is attending)',
                'WhatId (Account/Opportunity — what record to link it to)',
                'StartDateTime (date and time of the meeting)',
                'EndDateTime (when the meeting ends — default 30 min if not specified)',
                'Location (where the meeting is)',
                'Description (agenda or notes)'
            };
        } else if (objectApiName == 'Contact') {
            parts.add('These are commonly used on Contacts:\n');
            recommended = new List<String>{
                'AccountId (Company/Account name)', 'Email', 'Phone', 'MobilePhone', 'Title', 'Department'
            };
        } else if (objectApiName == 'Case') {
            parts.add('These are commonly used on Cases:\n');
            recommended = new List<String>{
                'Subject (brief description of the issue)',
                'Status (New, Working, Escalated, Closed)',
                'Priority (High, Medium, Low)',
                'Origin (Phone, Email, Web)',
                'AccountId (company/account name)',
                'ContactId (contact who reported it)',
                'Description (full details)'
            };
        } else if (objectApiName == 'Lead') {
            parts.add('These are commonly used on Leads:\n');
            recommended = new List<String>{
                'Company (required)', 'Email', 'Phone', 'Title', 'Industry', 'LeadSource', 'Description'
            };
        } else if (objectApiName == 'Opportunity') {
            parts.add('These are commonly used on Opportunities:\n');
            recommended = new List<String>{
                'StageName (required)', 'CloseDate (required — target close date)',
                'AccountId (company/account name)', 'Amount (deal value)',
                'Probability', 'NextStep', 'Description'
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
        parts.add('3. Asks for the most important 3-4 missing fields\n');
        parts.add('4. Makes it clear these are optional — the user can say "create it" whenever ready\n\n');

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
                record.put(fieldName, Datetime.valueOf(value.replace('T', ' ')));
            } else if (fieldType == Schema.DisplayType.REFERENCE) {
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
        } else if (objectApiName == 'Case') {
            String caseNum = populated.get('CaseNumber') != null ? String.valueOf(populated.get('CaseNumber')) : null;
            String subject = populated.get('Subject') != null ? String.valueOf(populated.get('Subject')) : null;
            recordName = caseNum != null ? 'Case ' + caseNum : 'Case';
            if (String.isNotBlank(subject)) recordName += ': ' + subject;
            heading = 'Case Created';
            verb = 'created';
        } else {
            recordName = String.valueOf(populated.get('Name'));
            heading = objectApiName + ' Created';
            verb = 'created';
        }
        if (recordName == null) recordName = 'Record';

        List<String> html = new List<String>();
        html.add('<h1>' + heading + '</h1>');
        html.add('<p>' + userName + ', I\'ve ' + verb + ' <a href="' + recordUrl + '"><b>' + recordName + '</b></a> successfully.</p>');

        // FirstName/LastName are shown as the record name in the heading — skip them in details
        Set<String> skipFields = new Set<String>{ 'Id', 'Name', 'Subject', 'OwnerId', 'TaskSubtype', 'CaseNumber', 'FirstName', 'LastName' };
        List<String> fieldItems = new List<String>();
        for (String fn : populated.keySet()) {
            if (skipFields.contains(fn)) continue;
            Object val = populated.get(fn);
            if (val == null || val instanceof SObject) continue;
            String displayVal = String.valueOf(val);
            if (String.isBlank(displayVal)) continue;

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

    /** Build structured record info for the frontend created-record sidebar card. */
    private static AgentforceWorkspaceModels.CreatedRecordInfo buildCreatedRecordInfo(
            String objectApiName, SObject created, Map<String, Schema.SObjectField> fieldMap) {
        Schema.SObjectType sObjType = Schema.getGlobalDescribe().get(objectApiName);
        Map<String, Object> populated = created.getPopulatedFieldsAsMap();

        AgentforceWorkspaceModels.CreatedRecordInfo info = new AgentforceWorkspaceModels.CreatedRecordInfo();
        info.objectApiName = objectApiName;
        info.objectLabel = sObjType.getDescribe().getLabel();
        info.iconName = AgentforceWorkspaceQueryService.OBJECT_ICONS.containsKey(objectApiName)
            ? AgentforceWorkspaceQueryService.OBJECT_ICONS.get(objectApiName) : 'standard:record';
        info.recordId = created.Id;
        info.recordName = getRecordName(objectApiName, created);
        info.recordUrl = '/lightning/r/' + objectApiName + '/' + created.Id + '/view';

        // For Task/Event, extract relationship names
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

        Set<String> skipFields = new Set<String>{ 'Id', 'Name', 'Subject', 'OwnerId', 'WhoId', 'WhatId', 'CaseNumber', 'FirstName', 'LastName' };
        for (String fn : populated.keySet()) {
            if (skipFields.contains(fn)) continue;
            Object val = populated.get(fn);
            if (val == null || val instanceof SObject) continue;

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

    /**
     * Get optional fields to prompt for after record creation.
     * Uses well-known overrides for standard objects; for custom objects,
     * dynamically discovers updateable non-required fields via SchemaService.
     */
    private static List<String> getOptionalFieldsForObject(String objectApiName) {
        if (KNOWN_OPTIONAL_FIELDS.containsKey(objectApiName)) {
            return KNOWN_OPTIONAL_FIELDS.get(objectApiName);
        }

        // Dynamic resolution for custom/unlisted objects
        AgentforceWorkspaceSchemaService.ObjectMeta meta = AgentforceWorkspaceSchemaService.describe(objectApiName);
        if (meta == null || meta.fields == null) return null;

        List<String> optFields = new List<String>();
        Set<String> skipFields = new Set<String>{ 'id', 'createddate', 'lastmodifieddate', 'systemmodstamp',
            'createdbyid', 'lastmodifiedbyid', 'isdeleted', 'ownerid' };

        for (AgentforceWorkspaceSchemaService.FieldMeta f : meta.fields) {
            if (optFields.size() >= 8) break;
            if (skipFields.contains(f.apiName.toLowerCase())) continue;
            if (f.isNameField) continue;
            if (!f.isUpdateable) continue;
            if (f.isRequired) continue;
            optFields.add(f.apiName);
        }
        return optFields.isEmpty() ? null : optFields;
    }
}
