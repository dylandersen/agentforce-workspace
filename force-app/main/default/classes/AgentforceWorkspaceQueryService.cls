/**
 * Query execution, supplementary queries, record tab building, and SOQL parsing
 * for the Agentforce Workspace feature.
 */
public with sharing class AgentforceWorkspaceQueryService {

    /**
     * Objects eligible for record tab display. Now dynamic — any accessible
     * object with query results gets a tab. This set serves as a fast-path
     * for well-known CRM objects (supplementary queries, OCR enrichment, etc.)
     * but is NOT a gate: objects absent from this set still get tabs via the
     * dynamic path in buildRecordTabs().
     */
    public static final Set<String> WELL_KNOWN_OBJECTS = new Set<String>{
        'Account', 'Opportunity', 'Contact', 'Case', 'Lead', 'Campaign',
        'Task', 'Event'
    };

    // Delegates to SchemaService — kept as convenience accessors for callers
    // that still reference these. New code should use SchemaService directly.
    public static final Map<String, String> OBJECT_ICONS = new Map<String, String>{
        'Account' => 'standard:account',
        'Opportunity' => 'standard:opportunity',
        'Contact' => 'standard:contact',
        'Case' => 'standard:case',
        'Lead' => 'standard:lead',
        'Campaign' => 'standard:campaign',
        'Task' => 'standard:task',
        'Event' => 'standard:event'
    };

    // Default fields for supplementary detail queries (well-known objects).
    // For unknown objects, SchemaService.getDefaultListFields() builds this dynamically.
    public static final Map<String, String> DEFAULT_LIST_FIELDS = new Map<String, String>{
        'Opportunity' => 'Id, Name, Account.Name, StageName, Amount, CloseDate',
        'Account' => 'Id, Name, Industry, Type, LastActivityDate, Phone, BillingCity, BillingState, BillingStreet, BillingPostalCode',
        'Contact' => 'Id, Name, Account.Name, Email, Phone, Title, MailingCity, MailingState, MailingStreet, MailingPostalCode',
        'Case' => 'Id, CaseNumber, Subject, Status, Priority, CreatedDate',
        'Lead' => 'Id, Name, Company, Status, Email, CreatedDate',
        'Campaign' => 'Id, Name, Status, Type, StartDate',
        'Task' => 'Id, Subject, Who.Name, What.Name, Status, ActivityDate, TaskSubtype',
        'Event' => 'Id, Subject, Who.Name, What.Name, StartDateTime, EndDateTime, Location'
    };

    /** Collect all Opportunity IDs from execution results. */
    public static Set<Id> collectAllOppIds(List<BusinessIntelligence.QueryExecution> executions) {
        Set<Id> oppIds = new Set<Id>();
        for (BusinessIntelligence.QueryExecution exec : executions) {
            if (exec.error != null || exec.results == null || exec.results.isEmpty()) continue;
            if (exec.countResult != null) continue;
            for (SObject record : exec.results) {
                if (String.valueOf(record.getSObjectType()) == 'Opportunity' && record.Id != null) {
                    oppIds.add(record.Id);
                }
            }
        }
        return oppIds;
    }

    /** Lookup Account info for a set of Opportunity IDs (single consolidated query). */
    public static Map<Id, Opportunity> lookupOppAccounts(Set<Id> oppIds) {
        if (oppIds.isEmpty()) return new Map<Id, Opportunity>();
        return new Map<Id, Opportunity>(
            [SELECT Id, AccountId, Account.Name FROM Opportunity
             WHERE Id IN :oppIds AND AccountId != null
             WITH USER_MODE]
        );
    }

    /** Find which objects have individual (non-aggregate, non-count) records.
     *  Now dynamic — returns ANY accessible object type, not just well-known ones. */
    public static Set<String> findObjectsWithRecords(List<BusinessIntelligence.QueryExecution> executions) {
        Set<String> objects = new Set<String>();
        for (BusinessIntelligence.QueryExecution exec : executions) {
            if (exec.error != null || exec.results == null || exec.results.isEmpty()) continue;
            if (exec.countResult != null) continue;
            for (SObject record : exec.results) {
                String objType = String.valueOf(record.getSObjectType());
                if (AgentforceWorkspaceSchemaService.isAccessible(objType)) {
                    objects.add(objType);
                }
            }
        }
        return objects;
    }

    /** Run supplementary detail queries for objects that only appeared in aggregates/counts.
     *  Now supports ANY accessible object — uses SchemaService for dynamic field resolution. */
    public static Map<String, List<SObject>> runSupplementaryQueries(
            List<BusinessIntelligence.QueryExecution> executions, Set<String> objectsWithRecords) {
        Map<String, List<SObject>> results = new Map<String, List<SObject>>();
        Set<String> queriedObjects = new Set<String>();
        Set<Id> eventWhatAccountIds = new Set<Id>();
        Set<Id> ocrContactIds = new Set<Id>();
        Set<Id> ocrOpportunityIds = new Set<Id>();

        for (BusinessIntelligence.QueryExecution exec : executions) {
            if (exec.error != null) continue;
            String objName = parseObjectFromSOQL(exec.soql);
            if (objName != null && AgentforceWorkspaceSchemaService.isAccessible(objName)) {
                queriedObjects.add(objName);
            }
            if (objName == 'Event' && exec.results != null) {
                for (SObject rec : exec.results) {
                    Object whatId = rec.get('WhatId');
                    if (whatId != null) {
                        String whatIdStr = String.valueOf(whatId);
                        if (whatIdStr.startsWith('001')) {
                            eventWhatAccountIds.add((Id) whatIdStr);
                        }
                    }
                }
            }
            if (objName == 'OpportunityContactRole' && exec.results != null && exec.countResult == null) {
                for (SObject rec : exec.results) {
                    Object contactId = rec.get('ContactId');
                    Object oppId = rec.get('OpportunityId');
                    if (contactId != null) ocrContactIds.add((Id) contactId);
                    if (oppId != null) ocrOpportunityIds.add((Id) oppId);
                }
            }
        }

        // OpportunityContactRole enrichment
        if (!ocrContactIds.isEmpty() || !ocrOpportunityIds.isEmpty()) {
            if (!ocrContactIds.isEmpty() && !objectsWithRecords.contains('Contact')) {
                try {
                    List<SObject> contactResults = Database.query(
                        'SELECT ' + AgentforceWorkspaceSchemaService.getDefaultListFields('Contact') + ' FROM Contact WHERE Id IN :ocrContactIds WITH USER_MODE ORDER BY Name LIMIT 200'
                    );
                    if (!contactResults.isEmpty()) {
                        results.put('Contact', contactResults);
                        objectsWithRecords.add('Contact');
                    }
                } catch (Exception e) {
                    System.debug(LoggingLevel.WARN, 'OCR supplementary Contact query failed: ' + e.getMessage());
                }
            }
            if (!ocrOpportunityIds.isEmpty() && !objectsWithRecords.contains('Opportunity')) {
                try {
                    List<SObject> oppResults = Database.query(
                        'SELECT ' + AgentforceWorkspaceSchemaService.getDefaultListFields('Opportunity') + ' FROM Opportunity WHERE Id IN :ocrOpportunityIds WITH USER_MODE ORDER BY Amount DESC NULLS LAST, CloseDate LIMIT 200'
                    );
                    if (!oppResults.isEmpty()) {
                        results.put('Opportunity', oppResults);
                        objectsWithRecords.add('Opportunity');
                    }
                } catch (Exception e) {
                    System.debug(LoggingLevel.WARN, 'OCR supplementary Opportunity query failed: ' + e.getMessage());
                }
            }
        }

        // Event → Account/Case enrichment
        if (!eventWhatAccountIds.isEmpty()) {
            if (!objectsWithRecords.contains('Account')) {
                try {
                    List<SObject> accResults = Database.query(
                        'SELECT ' + AgentforceWorkspaceSchemaService.getDefaultListFields('Account') + ' FROM Account WHERE Id IN :eventWhatAccountIds WITH USER_MODE LIMIT 200'
                    );
                    if (!accResults.isEmpty()) {
                        results.put('Account', accResults);
                        objectsWithRecords.add('Account');
                    }
                } catch (Exception e) {
                    System.debug(LoggingLevel.WARN, 'Event supplementary Account query failed: ' + e.getMessage());
                }
            }
            if (!objectsWithRecords.contains('Case')) {
                try {
                    List<SObject> caseResults = Database.query(
                        'SELECT ' + AgentforceWorkspaceSchemaService.getDefaultListFields('Case') + ' FROM Case WHERE AccountId IN :eventWhatAccountIds AND IsClosed = false WITH USER_MODE ORDER BY Priority ASC, CreatedDate DESC NULLS LAST LIMIT 200'
                    );
                    if (!caseResults.isEmpty()) {
                        results.put('Case', caseResults);
                        objectsWithRecords.add('Case');
                    }
                } catch (Exception e) {
                    System.debug(LoggingLevel.WARN, 'Event supplementary Case query failed: ' + e.getMessage());
                }
            }
        }

        // Generic supplementary queries for ANY queried object (dynamic field resolution)
        for (String objType : queriedObjects) {
            if (objectsWithRecords.contains(objType)) continue;
            try {
                String fields = AgentforceWorkspaceSchemaService.getDefaultListFields(objType);
                if (fields == null) continue;
                String whereClause = extractBestWhereClause(executions, objType);
                String soql = 'SELECT ' + fields + ' FROM ' + objType;
                if (String.isNotBlank(whereClause)) soql += ' WHERE ' + whereClause;
                String supSort = AgentforceWorkspaceSchemaService.getDefaultSortField(objType);
                if (supSort != null) {
                    soql += ' ORDER BY ' + supSort;
                    if (AgentforceWorkspaceSchemaService.isSortDescending(objType)) soql += ' DESC';
                    soql += ' NULLS LAST';
                }
                soql += ' LIMIT 200';
                List<SObject> supResults = Database.query(soql);
                if (!supResults.isEmpty()) {
                    results.put(objType, supResults);
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'Supplementary query failed for ' + objType + ': ' + e.getMessage());
            }
        }
        return results;
    }

    /** Format execution results as text for the analysis prompt. */
    public static String formatQueryResults(List<BusinessIntelligence.QueryExecution> executions) {
        List<String> parts = new List<String>();
        for (BusinessIntelligence.QueryExecution exec : executions) {
            parts.add('### ' + exec.purpose + '\n');
            parts.add('**Query:** `' + exec.soql + '`\n');
            if (String.isNotBlank(exec.error)) {
                parts.add('**Error:** ' + exec.error + '\n\n');
                continue;
            }
            if (exec.countResult != null) {
                parts.add('**Total Count:** ' + exec.countResult + '\n\n');
                continue;
            }
            if (exec.results == null || exec.results.isEmpty()) {
                parts.add('**Results:** No records found.\n\n');
                continue;
            }
            if (exec.limitReached) {
                parts.add('**Results:** ' + exec.results.size() + ' record(s) shown (display cap reached — use the COUNT query above for the accurate total)\n');
            } else {
                parts.add('**Results:** ' + exec.results.size() + ' record(s)\n');
            }
            for (Integer i = 0; i < Math.min(exec.results.size(), 200); i++) {
                Map<String, Object> fields = exec.results[i].getPopulatedFieldsAsMap();
                List<String> fieldParts = new List<String>();
                for (String fieldName : fields.keySet()) {
                    Object val = fields.get(fieldName);
                    if (val instanceof SObject) {
                        Map<String, Object> relFields = ((SObject) val).getPopulatedFieldsAsMap();
                        for (String relField : relFields.keySet()) {
                            fieldParts.add(fieldName + '.' + relField + ': ' + String.valueOf(relFields.get(relField)));
                        }
                    } else {
                        fieldParts.add(fieldName + ': ' + String.valueOf(val));
                    }
                }
                parts.add((i + 1) + '. ' + String.join(fieldParts, ' | ') + '\n');
            }
            parts.add('\n');
        }
        return String.join(parts, '');
    }

    /** Check if any execution has real results (not just errors). */
    public static Boolean checkHasAnyResults(List<BusinessIntelligence.QueryExecution> executions) {
        for (BusinessIntelligence.QueryExecution exec : executions) {
            if (exec.error != null) continue;
            if (exec.countResult != null) return true;
            if (exec.results != null && !exec.results.isEmpty()) return true;
        }
        return false;
    }

    /**
     * Build record tabs from query results for the list view.
     * Groups records by object type, deduplicates by Id,
     * and determines columns from the SOQL-selected fields.
     * Now supports ANY accessible object — not just well-known CRM objects.
     */
    public static List<AgentforceWorkspaceModels.RecordTab> buildRecordTabs(
            List<BusinessIntelligence.QueryExecution> executions,
            Map<Id, Opportunity> oppAccountMap,
            Map<String, List<SObject>> supplementaryRecords) {
        // Collect COUNT() results per object type (take the max if multiple counts)
        Map<String, Integer> countsByObject = new Map<String, Integer>();
        for (BusinessIntelligence.QueryExecution exec : executions) {
            if (exec.countResult == null) continue;
            String objName = parseObjectFromSOQL(exec.soql);
            if (objName != null && AgentforceWorkspaceSchemaService.isAccessible(objName)) {
                Integer existing = countsByObject.get(objName);
                if (existing == null || exec.countResult > existing) {
                    countsByObject.put(objName, exec.countResult);
                }
            }
        }

        // Group records by object type, deduplicating by Id — accept ANY accessible object
        Map<String, Map<Id, SObject>> recordsByObject = new Map<String, Map<Id, SObject>>();

        for (BusinessIntelligence.QueryExecution exec : executions) {
            if (exec.error != null || exec.results == null || exec.results.isEmpty()) continue;
            if (exec.countResult != null) continue;

            for (SObject record : exec.results) {
                String objType = String.valueOf(record.getSObjectType());
                if (!AgentforceWorkspaceSchemaService.isAccessible(objType)) continue;
                if (record.Id == null) continue;

                if (!recordsByObject.containsKey(objType)) {
                    recordsByObject.put(objType, new Map<Id, SObject>());
                }
                recordsByObject.get(objType).put(record.Id, record);
            }
        }

        // Use pre-fetched supplementary records for aggregate-only objects
        for (String supObjType : supplementaryRecords.keySet()) {
            if (recordsByObject.containsKey(supObjType)) continue;
            Map<Id, SObject> recMap = new Map<Id, SObject>();
            for (SObject rec : supplementaryRecords.get(supObjType)) {
                if (rec.Id != null) recMap.put(rec.Id, rec);
            }
            if (!recMap.isEmpty()) {
                recordsByObject.put(supObjType, recMap);
            }
        }

        if (recordsByObject.isEmpty()) return new List<AgentforceWorkspaceModels.RecordTab>();

        // Detect ORDER BY from original non-aggregate queries to override default sort
        Map<String, String> querySortField = new Map<String, String>();
        Map<String, Boolean> querySortDesc = new Map<String, Boolean>();
        for (BusinessIntelligence.QueryExecution exec : executions) {
            if (exec.error != null || String.isBlank(exec.soql)) continue;
            if (exec.countResult != null) continue;
            if (exec.soql.toUpperCase().contains(' GROUP BY ')) continue;
            String objName = parseObjectFromSOQL(exec.soql);
            if (objName == null) continue;
            String orderField = parseOrderByField(exec.soql);
            if (orderField != null && !querySortField.containsKey(objName)) {
                querySortField.put(objName, orderField);
                querySortDesc.put(objName, isOrderByDescending(exec.soql));
            }
        }

        List<AgentforceWorkspaceModels.RecordTab> tabs = new List<AgentforceWorkspaceModels.RecordTab>();
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();

        // Iterate in smart order: well-known objects first, then custom/other alphabetically
        List<String> tabOrder = AgentforceWorkspaceSchemaService.sortTabOrder(recordsByObject.keySet());

        for (String objType : tabOrder) {
            if (!recordsByObject.containsKey(objType)) continue;

            Map<Id, SObject> records = recordsByObject.get(objType);
            Schema.SObjectType sot = globalDescribe.get(objType.toLowerCase());
            if (sot == null) continue;

            AgentforceWorkspaceModels.RecordTab tab = new AgentforceWorkspaceModels.RecordTab();
            tab.objectApiName = objType;
            tab.objectLabel = sot.getDescribe().getLabelPlural();
            tab.iconName = AgentforceWorkspaceSchemaService.getIcon(objType);
            tab.recordCount = records.size();
            tab.totalCount = countsByObject.containsKey(objType) ? countsByObject.get(objType) : null;

            String nameField = AgentforceWorkspaceSchemaService.getNameField(objType);
            Map<String, Schema.SObjectField> fieldMap = sot.getDescribe().fields.getMap();

            // Collect all field names from the records (union across all records)
            Set<String> allFieldNames = new Set<String>();
            for (SObject rec : records.values()) {
                Map<String, Object> populated = rec.getPopulatedFieldsAsMap();
                for (String fn : populated.keySet()) {
                    Object val = populated.get(fn);
                    if (val instanceof SObject) {
                        // Relationship field — flatten (e.g., Account → Account.Name)
                        SObject rel = (SObject) val;
                        Map<String, Object> relFields = rel.getPopulatedFieldsAsMap();
                        for (String rf : relFields.keySet()) {
                            if (rf != 'Id') {
                                allFieldNames.add(fn + '.' + rf);
                            }
                        }
                    } else if (fn != 'Id') {
                        // Skip reference/lookup fields (raw IDs aren't useful in the table)
                        if (fieldMap.containsKey(fn.toLowerCase())) {
                            Schema.DisplayType dt = fieldMap.get(fn.toLowerCase()).getDescribe().getType();
                            if (dt == Schema.DisplayType.REFERENCE) {
                                continue;
                            }
                        }
                        allFieldNames.add(fn);
                    }
                }
            }

            // Address fields: include in row data for map panel but hide from table columns
            Set<String> addressFields = new Set<String>{
                'BillingStreet', 'BillingCity', 'BillingState', 'BillingPostalCode',
                'MailingStreet', 'MailingCity', 'MailingState', 'MailingPostalCode'
            };

            // Build ordered field list — name field first, then remaining sorted
            List<String> orderedFields = new List<String>();
            if (allFieldNames.contains(nameField)) {
                orderedFields.add(nameField);
                allFieldNames.remove(nameField);
            }
            List<String> remaining = new List<String>(allFieldNames);
            remaining.sort();
            orderedFields.addAll(remaining);

            // Build column definitions (exclude address fields from visible columns)
            for (String fn : orderedFields) {
                if (addressFields.contains(fn)) continue;
                AgentforceWorkspaceModels.ColumnDef col = new AgentforceWorkspaceModels.ColumnDef();
                col.fieldName = fn;
                col.isNameField = (fn == nameField);

                if (fn.contains('.')) {
                    col.label = fn.replace('.', ' ');
                    col.type = 'TEXT';
                    // Opportunity: make Account.Name a clickable link to the Account
                    if (fn == 'Account.Name' && objType == 'Opportunity') {
                        col.label = 'Account';
                        col.linkObjectApiName = 'Account';
                        col.linkIdField = '_accountId';
                    }
                } else if (fieldMap.containsKey(fn.toLowerCase())) {
                    Schema.DescribeFieldResult dfr = fieldMap.get(fn.toLowerCase()).getDescribe();
                    col.label = dfr.getLabel();
                    col.type = dfr.getType().name();
                } else {
                    col.label = fn;
                    col.type = 'TEXT';
                }

                tab.columns.add(col);
            }

            // Build rows
            for (SObject rec : records.values()) {
                Map<String, String> row = new Map<String, String>();
                row.put('_id', rec.Id);

                Map<String, Object> populated = rec.getPopulatedFieldsAsMap();

                // Store sort key — use query ORDER BY if present, else SchemaService default
                String sortFieldName = querySortField.containsKey(objType)
                    ? querySortField.get(objType)
                    : AgentforceWorkspaceSchemaService.getDefaultSortField(objType);
                if (sortFieldName != null) {
                    Object rawSortVal = populated.get(sortFieldName);
                    row.put('_sortKey', rawSortVal != null ? String.valueOf(rawSortVal) : '');
                }

                // Opportunity: always capture Account ID for linking
                if (objType == 'Opportunity') {
                    Object acctRel = populated.get('Account');
                    if (acctRel instanceof SObject) {
                        Map<String, Object> acctFields = ((SObject) acctRel).getPopulatedFieldsAsMap();
                        if (acctFields.containsKey('Id')) {
                            row.put('_accountId', String.valueOf(acctFields.get('Id')));
                        }
                    }
                    if (!row.containsKey('_accountId')) {
                        Object acctId = populated.get('AccountId');
                        if (acctId != null) {
                            row.put('_accountId', String.valueOf(acctId));
                        }
                    }
                }

                for (String fn : orderedFields) {
                    if (fn.contains('.')) {
                        // Relationship field (e.g., Account.Name)
                        String[] parts = fn.split('\\.');
                        Object relObj = populated.get(parts[0]);
                        if (relObj instanceof SObject) {
                            Map<String, Object> relFields = ((SObject) relObj).getPopulatedFieldsAsMap();
                            Object val = relFields.get(parts[1]);
                            row.put(fn, val != null ? String.valueOf(val) : '');
                        } else {
                            row.put(fn, '');
                        }
                    } else {
                        Object val = populated.get(fn);
                        String fieldType = 'STRING';
                        if (fieldMap.containsKey(fn.toLowerCase())) {
                            fieldType = fieldMap.get(fn.toLowerCase()).getDescribe().getType().name();
                        }
                        row.put(fn, val != null ? formatFieldValue(val, fieldType) : '');
                    }
                }

                tab.rows.add(row);
            }

            // -- Opportunity: ensure Account column always exists --
            if (objType == 'Opportunity') {
                Boolean hasAccountCol = false;
                for (AgentforceWorkspaceModels.ColumnDef col : tab.columns) {
                    if (col.fieldName == 'Account.Name') {
                        hasAccountCol = true;
                        break;
                    }
                }

                if (!hasAccountCol && !oppAccountMap.isEmpty()) {
                    for (Map<String, String> row : tab.rows) {
                        String oppId = row.get('_id');
                        if (String.isNotBlank(oppId)) {
                            try {
                                Opportunity opp = oppAccountMap.get(Id.valueOf(oppId));
                                if (opp != null) {
                                    row.put('_accountId', String.valueOf(opp.AccountId));
                                    row.put('_accountName', opp.Account != null ? opp.Account.Name : '');
                                } else {
                                    row.put('_accountName', '');
                                }
                            } catch (Exception e) {
                                row.put('_accountName', '');
                            }
                        }
                    }

                    AgentforceWorkspaceModels.ColumnDef acctCol = new AgentforceWorkspaceModels.ColumnDef();
                    acctCol.fieldName = '_accountName';
                    acctCol.label = 'Account';
                    acctCol.type = 'TEXT';
                    acctCol.isNameField = false;
                    acctCol.linkObjectApiName = 'Account';
                    acctCol.linkIdField = '_accountId';

                    Integer insertIdx = 1;
                    for (Integer i = 0; i < tab.columns.size(); i++) {
                        if (tab.columns[i].isNameField) {
                            insertIdx = i + 1;
                            break;
                        }
                    }
                    tab.columns.add(insertIdx, acctCol);
                }
            }

            // -- Sort rows --
            String sortField = querySortField.containsKey(objType)
                ? querySortField.get(objType)
                : AgentforceWorkspaceSchemaService.getDefaultSortField(objType);
            Boolean sortDesc = querySortDesc.containsKey(objType)
                ? querySortDesc.get(objType)
                : AgentforceWorkspaceSchemaService.isSortDescending(objType);
            if (sortField != null && !tab.rows.isEmpty()) {
                sortRows(tab.rows, '_sortKey', sortDesc);
            }

            tabs.add(tab);
        }

        return tabs;
    }

    /** Sort a list of row maps by a given field key. */
    private static void sortRows(List<Map<String, String>> rows, String sortField, Boolean descending) {
        if (rows.size() <= 1) return;
        List<AgentforceWorkspaceModels.RowSorter> sorters = new List<AgentforceWorkspaceModels.RowSorter>();
        for (Map<String, String> row : rows) {
            sorters.add(new AgentforceWorkspaceModels.RowSorter(row, sortField, descending));
        }
        sorters.sort();
        rows.clear();
        for (AgentforceWorkspaceModels.RowSorter s : sorters) {
            rows.add(s.row);
        }
    }

    /** Extract the object name from a SOQL query (the word after FROM). */
    private static String parseObjectFromSOQL(String soql) {
        if (String.isBlank(soql)) return null;
        String upper = soql.toUpperCase().trim();
        Integer fromIdx = upper.indexOf(' FROM ');
        if (fromIdx == -1) return null;
        String afterFrom = soql.substring(fromIdx + 6).trim();
        Integer spaceIdx = afterFrom.indexOf(' ');
        String objName = spaceIdx > 0 ? afterFrom.substring(0, spaceIdx) : afterFrom;
        return objName.trim();
    }

    /** Find the best (longest) WHERE clause targeting a specific object across all executions. */
    private static String extractBestWhereClause(List<BusinessIntelligence.QueryExecution> executions, String objType) {
        String bestWhere = null;
        for (BusinessIntelligence.QueryExecution exec : executions) {
            if (exec.error != null || String.isBlank(exec.soql)) continue;
            String parsedObj = parseObjectFromSOQL(exec.soql);
            if (parsedObj != objType) continue;
            String upper = exec.soql.toUpperCase();
            Integer whereIdx = upper.indexOf(' WHERE ');
            if (whereIdx == -1) continue;
            String afterWhere = exec.soql.substring(whereIdx + 7);
            for (String kw : new List<String>{' GROUP BY ', ' ORDER BY ', ' HAVING ', ' LIMIT ', ' WITH '}) {
                Integer kwIdx = afterWhere.toUpperCase().indexOf(kw);
                if (kwIdx != -1) {
                    afterWhere = afterWhere.substring(0, kwIdx);
                }
            }
            afterWhere = afterWhere.trim();
            if (String.isNotBlank(afterWhere) && (bestWhere == null || afterWhere.length() > bestWhere.length())) {
                bestWhere = afterWhere;
            }
        }
        return bestWhere;
    }

    /** Extract the primary ORDER BY field name from a SOQL query. */
    private static String parseOrderByField(String soql) {
        if (String.isBlank(soql)) return null;
        String upper = soql.toUpperCase();
        Integer idx = upper.indexOf(' ORDER BY ');
        if (idx == -1) return null;
        String afterOB = soql.substring(idx + 10).trim();
        String firstToken = afterOB.split('\\s+')[0];
        if (firstToken.contains(',')) firstToken = firstToken.split(',')[0];
        // Unwrap aggregate functions like SUM(Amount)
        if (firstToken.contains('(') && firstToken.contains(')')) {
            firstToken = firstToken.substring(firstToken.indexOf('(') + 1, firstToken.indexOf(')'));
        }
        return String.isNotBlank(firstToken) ? firstToken : null;
    }

    /** Check if the ORDER BY clause specifies descending order. */
    private static Boolean isOrderByDescending(String soql) {
        if (String.isBlank(soql)) return false;
        String upper = soql.toUpperCase();
        Integer idx = upper.indexOf(' ORDER BY ');
        if (idx == -1) return false;
        String afterOB = upper.substring(idx + 10);
        Integer limitIdx = afterOB.indexOf(' LIMIT ');
        String orderClause = limitIdx > 0 ? afterOB.substring(0, limitIdx) : afterOB;
        Integer commaIdx = orderClause.indexOf(',');
        if (commaIdx > 0) orderClause = orderClause.substring(0, commaIdx);
        return orderClause.contains(' DESC');
    }

    /** Format a field value for display in the record list view. */
    public static String formatFieldValue(Object val, String fieldType) {
        if (val == null) return '';

        if (val instanceof Decimal) {
            Decimal d = (Decimal) val;
            if (fieldType == 'CURRENCY') {
                return '$' + d.setScale(0).format();
            }
            if (fieldType == 'PERCENT') {
                return d.setScale(1) + '%';
            }
            return d.format();
        }

        if (val instanceof Date) {
            return ((Date) val).format();
        }

        if (val instanceof Datetime) {
            return ((Datetime) val).format('MMM d, yyyy');
        }

        if (val instanceof Boolean) {
            return (Boolean) val ? 'Yes' : 'No';
        }

        return String.valueOf(val);
    }
}
