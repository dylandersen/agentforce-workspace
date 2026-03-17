@isTest
public class AgentforceWorkspaceModelsTest {

    @isTest
    static void testChatResultDefaults() {
        AgentforceWorkspaceModels.ChatResult cr = new AgentforceWorkspaceModels.ChatResult();
        System.assertNotEquals(null, cr.suggestions);
        System.assertEquals(0, cr.suggestions.size());
        System.assertNotEquals(null, cr.recordTabs);
        System.assertEquals(false, cr.forceRecordUpdate);
        System.assertEquals(null, cr.response);
        System.assertEquals(null, cr.createdRecord);
        System.assertEquals(null, cr.chartData);
    }

    @isTest
    static void testChartDataDefaults() {
        AgentforceWorkspaceModels.ChartData cd = new AgentforceWorkspaceModels.ChartData();
        System.assertNotEquals(null, cd.items);
        System.assertEquals(0, cd.items.size());
        cd.chartType = 'bar';
        cd.title = 'Test';
        cd.valueLabel = 'Amount';
        cd.valuePrefix = '$';
        cd.valueSuffix = 'K';
        System.assertEquals('bar', cd.chartType);
    }

    @isTest
    static void testChartItem() {
        AgentforceWorkspaceModels.ChartItem ci = new AgentforceWorkspaceModels.ChartItem();
        ci.label = 'Test';
        ci.value = 100;
        ci.color = '#FF0000';
        System.assertEquals('Test', ci.label);
        System.assertEquals(100, ci.value);
    }

    @isTest
    static void testCreatedRecordInfoDefaults() {
        AgentforceWorkspaceModels.CreatedRecordInfo info = new AgentforceWorkspaceModels.CreatedRecordInfo();
        System.assertNotEquals(null, info.fields);
        System.assertEquals(0, info.fields.size());
        info.objectApiName = 'Account';
        info.objectLabel = 'Account';
        info.iconName = 'standard:account';
        info.recordId = '001000000000001';
        info.recordName = 'Test';
        info.recordUrl = '/test';
        System.assertEquals('Account', info.objectApiName);
    }

    @isTest
    static void testRecordField() {
        AgentforceWorkspaceModels.RecordField rf = new AgentforceWorkspaceModels.RecordField();
        rf.label = 'Industry';
        rf.value = 'Technology';
        rf.type = 'STRING';
        System.assertEquals('Industry', rf.label);
    }

    @isTest
    static void testQueryResultDefaults() {
        AgentforceWorkspaceModels.QueryResult qr = new AgentforceWorkspaceModels.QueryResult();
        System.assertNotEquals(null, qr.recordTabs);
        System.assertEquals(false, qr.hasResults);
        System.assertEquals(null, qr.executionDataJson);
        System.assertEquals(null, qr.querySummary);
    }

    @isTest
    static void testRecordTabDefaults() {
        AgentforceWorkspaceModels.RecordTab tab = new AgentforceWorkspaceModels.RecordTab();
        System.assertNotEquals(null, tab.columns);
        System.assertNotEquals(null, tab.rows);
        tab.objectApiName = 'Account';
        tab.objectLabel = 'Accounts';
        tab.iconName = 'standard:account';
        tab.recordCount = 5;
        tab.totalCount = 10;
        System.assertEquals('Account', tab.objectApiName);
    }

    @isTest
    static void testColumnDef() {
        AgentforceWorkspaceModels.ColumnDef col = new AgentforceWorkspaceModels.ColumnDef();
        col.label = 'Name';
        col.fieldName = 'Name';
        col.type = 'STRING';
        col.isNameField = true;
        col.linkObjectApiName = 'Account';
        col.linkIdField = '_accountId';
        System.assertEquals('Name', col.label);
        System.assertEquals(true, col.isNameField);
    }

    @isTest
    static void testRowSorterNumericAscending() {
        Map<String, String> row1 = new Map<String, String>{ 'Amount' => '100' };
        Map<String, String> row2 = new Map<String, String>{ 'Amount' => '200' };
        AgentforceWorkspaceModels.RowSorter s1 = new AgentforceWorkspaceModels.RowSorter(row1, 'Amount', false);
        AgentforceWorkspaceModels.RowSorter s2 = new AgentforceWorkspaceModels.RowSorter(row2, 'Amount', false);
        System.assert(s1.compareTo(s2) < 0, 'row1 should sort before row2');
    }

    @isTest
    static void testRowSorterNumericDescending() {
        Map<String, String> row1 = new Map<String, String>{ 'Amount' => '100' };
        Map<String, String> row2 = new Map<String, String>{ 'Amount' => '200' };
        AgentforceWorkspaceModels.RowSorter s1 = new AgentforceWorkspaceModels.RowSorter(row1, 'Amount', true);
        AgentforceWorkspaceModels.RowSorter s2 = new AgentforceWorkspaceModels.RowSorter(row2, 'Amount', true);
        System.assert(s1.compareTo(s2) > 0, 'row1 should sort after row2 in descending');
    }

    @isTest
    static void testRowSorterStringComparison() {
        Map<String, String> row1 = new Map<String, String>{ 'Name' => 'Alpha' };
        Map<String, String> row2 = new Map<String, String>{ 'Name' => 'Beta' };
        AgentforceWorkspaceModels.RowSorter s1 = new AgentforceWorkspaceModels.RowSorter(row1, 'Name', false);
        AgentforceWorkspaceModels.RowSorter s2 = new AgentforceWorkspaceModels.RowSorter(row2, 'Name', false);
        System.assert(s1.compareTo(s2) < 0);
    }

    @isTest
    static void testRowSorterNullAndMissingKeys() {
        Map<String, String> row1 = new Map<String, String>{ 'Name' => null };
        Map<String, String> row2 = new Map<String, String>();
        AgentforceWorkspaceModels.RowSorter s1 = new AgentforceWorkspaceModels.RowSorter(row1, 'Name', false);
        AgentforceWorkspaceModels.RowSorter s2 = new AgentforceWorkspaceModels.RowSorter(row2, 'Name', false);
        System.assertEquals(0, s1.compareTo(s2));
    }

    @isTest
    static void testRowSorterEqualValues() {
        Map<String, String> row1 = new Map<String, String>{ 'Amount' => '100' };
        Map<String, String> row2 = new Map<String, String>{ 'Amount' => '100' };
        AgentforceWorkspaceModels.RowSorter s1 = new AgentforceWorkspaceModels.RowSorter(row1, 'Amount', false);
        AgentforceWorkspaceModels.RowSorter s2 = new AgentforceWorkspaceModels.RowSorter(row2, 'Amount', false);
        System.assertEquals(0, s1.compareTo(s2));
    }

    @isTest
    static void testNameLengthSorter() {
        AgentforceWorkspaceModels.NameLengthSorter short1 = new AgentforceWorkspaceModels.NameLengthSorter('AB');
        AgentforceWorkspaceModels.NameLengthSorter long1 = new AgentforceWorkspaceModels.NameLengthSorter('ABCDEF');
        // Longer names should sort first (negative return means "this" comes first)
        System.assert(long1.compareTo(short1) < 0, 'Longer name should sort before shorter');
        System.assert(short1.compareTo(long1) > 0, 'Shorter name should sort after longer');
    }

    @isTest
    static void testExecutionData() {
        AgentforceWorkspaceModels.ExecutionData ed = new AgentforceWorkspaceModels.ExecutionData();
        ed.queryResultsText = 'test';
        ed.recordLinks = new Map<String, List<String>>();
        ed.userName = 'Dylan';
        ed.userFullName = 'Dylan Andersen';
        ed.hasAnyResults = true;
        System.assertEquals('test', ed.queryResultsText);
        System.assertEquals(true, ed.hasAnyResults);
    }
}
