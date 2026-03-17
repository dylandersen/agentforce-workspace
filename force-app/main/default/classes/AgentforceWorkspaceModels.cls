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
        @AuraEnabled public ChartData chartData;
        public ChatResult() {
            this.suggestions = new List<String>();
            this.recordTabs = new List<RecordTab>();
            this.forceRecordUpdate = false;
        }
    }

    /** Chart data chosen by the LLM from the analysis results. */
    public class ChartData {
        @AuraEnabled public String chartType;     // bar, horizontalBar, donut
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
        public QueryResult() {
            this.recordTabs = new List<RecordTab>();
            this.hasResults = false;
        }
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
