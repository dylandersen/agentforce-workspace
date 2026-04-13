/**
 * Shared DTOs and inner classes for the Agentforce Workspace feature.
 * Referenced by AgentforceWorkspaceController and all service classes.
 */
public with sharing class AgentforceWorkspaceModels {

    /** Wire-friendly result wrapper returned to the LWC. */
    public class ChatResult {
        @AuraEnabled public String response;
        @AuraEnabled public List<String> suggestions;
        @AuraEnabled public List<RecordTab> recordTabs;
        @AuraEnabled public Boolean forceRecordUpdate;
        @AuraEnabled public CreatedRecordInfo createdRecord;
        @AuraEnabled public CreatedRecordInfo updatedRecord;
        @AuraEnabled public List<CreatedRecordInfo> allCreatedRecords;
        @AuraEnabled public ChartData chartData;
        @AuraEnabled public PendingUpdate pendingUpdate;
        @AuraEnabled public PendingBulkUpdate pendingBulkUpdate;
        @AuraEnabled public Boolean pendingUpdateCleared;
        @AuraEnabled public Boolean pendingBulkUpdateCleared;
        public ChatResult() {
            this.suggestions = new List<String>();
            this.recordTabs = new List<RecordTab>();
            this.forceRecordUpdate = false;
            this.pendingUpdateCleared = false;
            this.pendingBulkUpdateCleared = false;
        }
    }

    /** Pending field-completion prompt surfaced after record creation. */
    public class PendingUpdate {
        @AuraEnabled public String recordId;
        @AuraEnabled public String objectApiName;
        @AuraEnabled public String recordName;
        @AuraEnabled public List<FieldPromptItem> blankFields;
        public PendingUpdate() { this.blankFields = new List<FieldPromptItem>(); }
    }

    /** Pending bulk update preview surfaced before executing a multi-record update. */
    public class PendingBulkUpdate {
        @AuraEnabled public String objectApiName;
        @AuraEnabled public Integer matchedCount;
        @AuraEnabled public List<String> recordIds;
        @AuraEnabled public List<BulkUpdateRecordRef> records;
        @AuraEnabled public Map<String, String> fields;
        public PendingBulkUpdate() {
            this.matchedCount = 0;
            this.recordIds = new List<String>();
            this.records = new List<BulkUpdateRecordRef>();
            this.fields = new Map<String, String>();
        }
    }

    /** Lightweight record reference used by the pending bulk update preview. */
    public class BulkUpdateRecordRef {
        @AuraEnabled public String recordId;
        @AuraEnabled public String recordName;
    }

    /** A single blank field offered to the user for follow-up completion. */
    public class FieldPromptItem {
        @AuraEnabled public String apiName;
        @AuraEnabled public String label;
    }

    /** Chart data chosen by the LLM from the analysis results. */
    public class ChartData {
        @AuraEnabled public String chartType;     // horizontalBar, bar, donut, line, funnel, metricStrip
        @AuraEnabled public String title;
        @AuraEnabled public String valueLabel;    // e.g. "Amount", "Count"
        @AuraEnabled public String valuePrefix;   // e.g. "$"
        @AuraEnabled public String valueSuffix;   // e.g. "%", "K"
        @AuraEnabled public List<ChartItem> items;
        public ChartData() { this.items = new List<ChartItem>(); }
    }

    public class ChartItem {
        @AuraEnabled public String label;
        @AuraEnabled public Decimal value;
        @AuraEnabled public String color;         // optional hex color
        @AuraEnabled public String valuePrefix;   // optional per-item prefix for mixed-unit KPI strips
        @AuraEnabled public String valueSuffix;   // optional per-item suffix for mixed-unit KPI strips
    }

    /** Structured info about a newly created record for the frontend card. */
    public class CreatedRecordInfo {
        @AuraEnabled public String objectApiName;
        @AuraEnabled public String objectLabel;
        @AuraEnabled public String iconName;
        @AuraEnabled public String recordId;
        @AuraEnabled public String recordName;
        @AuraEnabled public String recordUrl;
        @AuraEnabled public List<RecordField> fields;
        public CreatedRecordInfo() {
            this.fields = new List<RecordField>();
        }
    }

    /** A single field label + value pair for the created record card. */
    public class RecordField {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        @AuraEnabled public String type;
    }

    /** Result from buildQueries() — enables two-stage frontend flow. */
    public class QueryResult {
        @AuraEnabled public List<RecordTab> recordTabs;
        @AuraEnabled public String executionDataJson;
        @AuraEnabled public String querySummary;
        @AuraEnabled public Boolean hasResults;
        @AuraEnabled public String intentLabel;
        @AuraEnabled public Integer reasoningAttempts;
        public QueryResult() {
            this.recordTabs = new List<RecordTab>();
            this.hasResults = false;
            this.reasoningAttempts = 0;
        }
    }

    /** Result of the lightweight intent classification call (Pass 0). */
    public class IntentResult {
        @AuraEnabled public String intent;        // QUERY, CREATE, UPDATE, COMPARE, COMPOSE, CLARIFY, FOLLOWUP
        @AuraEnabled public String plan;          // One-sentence description of what to do
        @AuraEnabled public Decimal confidence;   // 0.0–1.0
        @AuraEnabled public String clarification; // If intent=CLARIFY, the question to ask the user
    }

    /** Internal result from the reasoning engine — not sent to LWC directly. */
    public class ReasoningResult {
        public Boolean success = false;
        public List<BusinessIntelligence.QueryExecution> executions;
        public Map<String, Object> createAction;
        public IntentResult classifiedIntent;
        public String failureExplanation;
        public List<String> alternativeSuggestions;
        public Integer attemptsUsed = 0;
    }

    /** Tab of records for a single object type in the list view. */
    public class RecordTab {
        @AuraEnabled public String objectApiName;
        @AuraEnabled public String objectLabel;
        @AuraEnabled public String iconName;
        @AuraEnabled public Integer recordCount;
        @AuraEnabled public Integer totalCount;  // from COUNT() query — null if not available
        @AuraEnabled public List<ColumnDef> columns;
        @AuraEnabled public List<Map<String, String>> rows;
        /** When set, the LWC shows a "Salesforce Data 360 · <source>" badge below the table. */
        @AuraEnabled public String dataCloudSource;
        /** Salesforce record ID of the DataLakeObject — used to navigate to its detail page. */
        @AuraEnabled public String dataCloudRecordId;
        public RecordTab() {
            this.columns = new List<ColumnDef>();
            this.rows = new List<Map<String, String>>();
        }
    }

    /** Column definition for the record list view. */
    public class ColumnDef {
        @AuraEnabled public String label;
        @AuraEnabled public String fieldName;
        @AuraEnabled public String type;
        @AuraEnabled public Boolean isNameField;
        @AuraEnabled public String linkObjectApiName;  // if set, cell links to this object
        @AuraEnabled public String linkIdField;         // row key holding the linked record's ID
    }

    /** Row sort wrapper for ordering list view records. */
    public class RowSorter implements Comparable {
        public Map<String, String> row;
        private String sortKey;
        private Boolean descending;

        public RowSorter(Map<String, String> r, String sortField, Boolean isDescending) {
            this.row = r;
            this.sortKey = r.containsKey(sortField) ? r.get(sortField) : '';
            if (this.sortKey == null) this.sortKey = '';
            this.descending = isDescending;
        }

        public Integer compareTo(Object other) {
            RowSorter o = (RowSorter) other;
            Integer result;
            // Use numeric comparison when both values are numbers (Amount, etc.)
            if (String.isNotBlank(this.sortKey) && String.isNotBlank(o.sortKey)) {
                try {
                    Decimal d1 = Decimal.valueOf(this.sortKey);
                    Decimal d2 = Decimal.valueOf(o.sortKey);
                    if (d1 > d2) result = 1;
                    else if (d1 < d2) result = -1;
                    else result = 0;
                } catch (Exception e) {
                    result = this.sortKey.compareTo(o.sortKey);
                }
            } else {
                result = this.sortKey.compareTo(o.sortKey);
            }
            return descending ? -result : result;
        }
    }

    /** Sort strings by length descending for record link injection. */
    public class NameLengthSorter implements Comparable {
        public String name;
        public NameLengthSorter(String n) { this.name = n; }
        public Integer compareTo(Object other) {
            return ((NameLengthSorter) other).name.length() - this.name.length();
        }
    }

    /** Serializable wrapper for passing execution data between buildQueries and analyzeResults. */
    public class ExecutionData {
        public String queryResultsText;
        public Map<String, List<String>> recordLinks;
        public String userName;
        public String userFullName;
        public Boolean hasAnyResults;
    }
}
