/**
 * Enriches Agentforce Workspace queries with Data Cloud credit usage data
 * from the Daily_Credit_Usage__dll Data Lake Object.
 *
 * Integration pattern:
 *   1. Detect consumption/usage intent in the user message
 *   2. Resolve the account's external_account_id__c via Account.DC_External_Account_ID__c
 *   3. Query Daily_Credit_Usage__dll for that account
 *   4. Return formatted results for injection into the Pass 2 analysis prompt
 */
public with sharing class A8_DataCloudCreditUsageService {

    private static final String DLO_API_NAME   = 'Daily_Credit_Usage__dll';
    // Record ID of the DataLakeObjectInstance — used to navigate to the DLO detail page in the console
    private static final String DLO_RECORD_ID  = '1dlHu000000Qe7kIAC';
    private static final Integer DEFAULT_LOOKBACK_DAYS = 120;
    private static final Integer MAX_RECORDS = 90;

    // Keywords that signal the user is asking about consumption/usage
    private static final List<String> CONSUMPTION_KEYWORDS = new List<String>{
        'consumption', 'consume', 'credits', 'credit usage', 'credit used',
        'usage', 'data quality', 'monitor', 'monitoring', 'freshness',
        'volume', 'schema check', 'dlo', 'data lake', 'daily usage',
        'how much', 'spending', 'spend', 'burned'
    };

    /** Container for the enrichment output. */
    public class EnrichmentResult {
        public String  formattedResults;
        public String  accountName;
        public String  externalAccountId;
        public Integer recordCount = 0;
        public Boolean hasData = false;
        /** One RecordTab per resolved account — may contain multiple for comparison queries. */
        public List<AgentforceWorkspaceModels.RecordTab> recordTabs = new List<AgentforceWorkspaceModels.RecordTab>();
    }

    // ─── Public API ──────────────────────────────────────────────

    /**
     * Main entry point called from AgentforceWorkspaceController.buildQueries.
     * Supports single-account and multi-account (comparison) queries.
     * Returns null when no enrichment is needed or possible.
     */
    public static EnrichmentResult enrich(String userMessage, List<BusinessIntelligence.QueryExecution> crmExecutions) {
        if (!isConsumptionQuery(userMessage)) return null;

        // Collect all relevant accounts (may be 2+ for comparison queries)
        Map<String, String> accounts = resolveAllAccounts(userMessage, crmExecutions);
        if (accounts.isEmpty()) return null;

        EnrichmentResult combined = new EnrichmentResult();
        List<String> promptParts = new List<String>();

        for (String extId : accounts.keySet()) {
            String name = accounts.get(extId);
            EnrichmentResult single = queryDlo(extId, name, DEFAULT_LOOKBACK_DAYS);
            if (single != null && single.hasData) {
                combined.hasData = true;
                combined.recordCount += single.recordCount;
                if (String.isNotBlank(single.formattedResults)) promptParts.add(single.formattedResults);
                combined.recordTabs.addAll(single.recordTabs);
            }
        }

        if (!combined.hasData) return null;
        combined.formattedResults = String.join(promptParts, '\n\n---\n\n');
        return combined;
    }

    // ─── Intent Detection ─────────────────────────────────────────

    public static Boolean isConsumptionQuery(String userMessage) {
        if (String.isBlank(userMessage)) return false;
        String lower = userMessage.toLowerCase();
        for (String keyword : CONSUMPTION_KEYWORDS) {
            if (lower.contains(keyword)) return true;
        }
        return false;
    }

    // ─── Account Resolution ───────────────────────────────────────

    /**
     * Collect all accounts relevant to this query (supports 1 or 2+ for comparison queries).
     * Returns Map<externalAccountId, accountName>.
     *
     * Strategy 1: Scan every Account row in CRM executions — Pass 1 generates one Account
     *             SOQL per company mentioned, so all are available here.
     * Strategy 2: If < 2 accounts found and multiple names appear in the message, look up
     *             each name hint directly so comparison queries always resolve both sides.
     */
    private static Map<String, String> resolveAllAccounts(String userMessage,
                                                          List<BusinessIntelligence.QueryExecution> crmExecutions) {
        Map<String, String> result = new Map<String, String>(); // extId → name

        // Strategy 1 — harvest every Account from CRM executions
        if (crmExecutions != null) {
            for (BusinessIntelligence.QueryExecution exec : crmExecutions) {
                if (exec.error != null || exec.results == null || exec.countResult != null) continue;
                for (SObject rec : exec.results) {
                    if (String.valueOf(rec.getSObjectType()) != 'Account') continue;
                    Object extId = rec.get('External_Account_ID__c');
                    if (extId == null || String.isBlank(String.valueOf(extId))) continue;
                    String id   = String.valueOf(extId);
                    String name = rec.get('Name') != null ? String.valueOf(rec.get('Name')) : id;
                    if (!result.containsKey(id)) result.put(id, name);
                }
            }
        }

        // Strategy 2 — fill gaps from name hints in the message
        List<String> nameHints = extractAllAccountNameHints(userMessage);
        for (String nameHint : nameHints) {
            if (String.isBlank(nameHint)) continue;
            try {
                String nameFilter = '%' + nameHint + '%';
                List<Account> accs = [
                    SELECT Id, Name, External_Account_ID__c
                    FROM Account
                    WHERE External_Account_ID__c != null
                      AND Name LIKE :nameFilter
                    WITH USER_MODE
                    LIMIT 1
                ];
                if (!accs.isEmpty()) {
                    String extId2 = accs[0].External_Account_ID__c;
                    if (!result.containsKey(extId2)) result.put(extId2, accs[0].Name);
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'DC account hint lookup failed for "' + nameHint + '": ' + e.getMessage());
            }
        }

        return result;
    }

    /**
     * Extract ALL probable account name fragments from a natural language message.
     * Returns deduplicated list — handles single and comparison queries alike.
     */
    @TestVisible
    private static List<String> extractAllAccountNameHints(String userMessage) {
        List<String> hints = new List<String>();
        Set<String> seen  = new Set<String>();
        if (String.isBlank(userMessage)) return hints;

        // Possessive: "Summit Commerce Group's"
        Pattern possessive = Pattern.compile('([A-Z][a-zA-Z]+(?:\\s+[A-Z][a-zA-Z]+){0,5})\'s');
        Matcher m1 = possessive.matcher(userMessage);
        while (m1.find()) {
            String h = m1.group(1).trim();
            if (!seen.contains(h)) { seen.add(h); hints.add(h); }
        }

        // After comparison words: "compare X to Y", "X vs Y"
        Pattern afterCompare = Pattern.compile('(?:compare|comparing|versus|vs\\.?)\\s+([A-Z][a-zA-Z]+(?:\\s+[A-Z][a-zA-Z]+){0,5})');
        Matcher m2 = afterCompare.matcher(userMessage);
        while (m2.find()) {
            String h = m2.group(1).trim();
            if (!seen.contains(h)) { seen.add(h); hints.add(h); }
        }

        // After prepositions: "for/of/about/to X"
        Pattern forOf = Pattern.compile('(?:for|of|about|to)\\s+([A-Z][a-zA-Z]+(?:\\s+[A-Z][a-zA-Z]+){0,5})');
        Matcher m3 = forOf.matcher(userMessage);
        while (m3.find()) {
            String h = m3.group(1).trim();
            if (!seen.contains(h)) { seen.add(h); hints.add(h); }
        }

        return hints;
    }

    /** @deprecated — kept for test backwards-compatibility. Use extractAllAccountNameHints instead. */
    @TestVisible
    private static String extractAccountNameHint(String userMessage) {
        List<String> hints = extractAllAccountNameHints(userMessage);
        return hints.isEmpty() ? null : hints[0];
    }

    // ─── DLO Query ────────────────────────────────────────────────

    private static EnrichmentResult queryDlo(String externalAccountId, String accountName, Integer lookbackDays) {
        EnrichmentResult result = new EnrichmentResult();
        result.externalAccountId = externalAccountId;
        result.accountName = accountName;
        result.hasData = false;

        try {
            Date cutoffDate = Date.today().addDays(-lookbackDays);

            // DataSource__c omitted — not needed for analysis and may not be selectable
            String soql = 'SELECT usage_date__c, monitor_type__c, credits_consumed__c, '
                + 'monitor_count__c, tier__c '
                + 'FROM ' + DLO_API_NAME + ' '
                + 'WHERE external_account_id__c = :externalAccountId '
                + 'AND usage_date__c >= :cutoffDate '
                + 'ORDER BY usage_date__c DESC '
                + 'LIMIT ' + MAX_RECORDS;

            List<SObject> records = Database.query(soql);

            result.recordCount = records.size();

            if (records.isEmpty()) {
                result.formattedResults = 'No credit usage records found for this account in the last '
                    + lookbackDays + ' days.';
                return result;
            }

            result.hasData = true;

            // Formatting and tab building are isolated so one failure doesn't kill the other
            try {
                result.formattedResults = formatDloResults(records, accountName, externalAccountId, lookbackDays);
            } catch (Exception fe) {
                System.debug(LoggingLevel.WARN, 'DLO format failed: ' + fe.getMessage());
                result.formattedResults = 'Data Cloud credit usage data retrieved (' + records.size() + ' records).';
            }
            try {
                result.recordTabs.add(buildRecordTab(records, accountName, externalAccountId));
            } catch (Exception te) {
                System.debug(LoggingLevel.WARN, 'DLO tab build failed: ' + te.getMessage());
                // recordTabs stays empty — non-fatal, Related Records just won't show DC tab
            }

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'DLO query failed: ' + e.getMessage());
            result.formattedResults = 'Data Cloud query encountered an error: ' + e.getMessage();
        }

        return result;
    }

    // ─── Record Tab Builder ───────────────────────────────────────

    /**
     * Build a sidebar RecordTab from DLO records so the Related Records panel
     * shows daily credit usage data alongside the CRM records.
     * Shows the most recent 30 days as individual rows.
     */
    private static AgentforceWorkspaceModels.RecordTab buildRecordTab(
            List<SObject> records, String accountName, String externalAccountId) {

        AgentforceWorkspaceModels.RecordTab tab = new AgentforceWorkspaceModels.RecordTab();
        tab.objectApiName = '__DataCloud__Daily_Credit_Usage__dll';
        // Include account name in label so comparison tabs are distinguishable in the sidebar
        tab.objectLabel   = String.isNotBlank(accountName)
            ? accountName.abbreviate(28) + ' Credits'
            : 'Daily Credit Usage';
        tab.iconName      = 'utility:database';
        tab.recordCount   = Math.min(records.size(), 30);
        tab.totalCount    = records.size();
        tab.dataCloudSource   = DLO_API_NAME;
        tab.dataCloudRecordId = DLO_RECORD_ID;

        // Column definitions — isNameField=false on all: DLO rows have no real Salesforce record IDs
        AgentforceWorkspaceModels.ColumnDef dateCol = new AgentforceWorkspaceModels.ColumnDef();
        dateCol.fieldName   = 'usage_date';
        dateCol.label       = 'Date';
        dateCol.type        = 'TEXT';   // TEXT so it sorts as string (already ISO format)
        dateCol.isNameField = false;

        AgentforceWorkspaceModels.ColumnDef typeCol = new AgentforceWorkspaceModels.ColumnDef();
        typeCol.fieldName   = 'monitor_type';
        typeCol.label       = 'Monitor Type';
        typeCol.type        = 'TEXT';
        typeCol.isNameField = false;

        AgentforceWorkspaceModels.ColumnDef creditsCol = new AgentforceWorkspaceModels.ColumnDef();
        creditsCol.fieldName   = 'credits_consumed';
        creditsCol.label       = 'Credits';
        creditsCol.type        = 'DOUBLE';
        creditsCol.isNameField = false;

        AgentforceWorkspaceModels.ColumnDef monitorCountCol = new AgentforceWorkspaceModels.ColumnDef();
        monitorCountCol.fieldName   = 'monitor_count';
        monitorCountCol.label       = 'Monitors';
        monitorCountCol.type        = 'INTEGER';
        monitorCountCol.isNameField = false;

        AgentforceWorkspaceModels.ColumnDef tierCol = new AgentforceWorkspaceModels.ColumnDef();
        tierCol.fieldName   = 'tier';
        tierCol.label       = 'Tier';
        tierCol.type        = 'TEXT';
        tierCol.isNameField = false;

        tab.columns.add(dateCol);
        tab.columns.add(typeCol);
        tab.columns.add(creditsCol);
        tab.columns.add(monitorCountCol);
        tab.columns.add(tierCol);

        // Build rows (most recent 30)
        Integer maxRows = Math.min(records.size(), 30);
        for (Integer i = 0; i < maxRows; i++) {
            SObject rec = records[i];
            Map<String, String> row = new Map<String, String>();

            // DLOs may return date fields as Date, DateTime, or String — handle all three
            String usageDateStr = '';
            Object rawDate = rec.get('usage_date__c');
            if (rawDate instanceof Date) {
                usageDateStr = String.valueOf((Date) rawDate);  // ISO: yyyy-MM-dd
            } else if (rawDate instanceof DateTime) {
                usageDateStr = String.valueOf(((DateTime) rawDate).date());
            } else if (rawDate != null) {
                usageDateStr = String.valueOf(rawDate).left(10);  // trim time portion if present
            }

            Decimal credits = rec.get('credits_consumed__c') != null
                ? (Decimal) rec.get('credits_consumed__c') : 0;
            Decimal monitorCount = rec.get('monitor_count__c') != null
                ? (Decimal) rec.get('monitor_count__c') : 0;

            row.put('_id', externalAccountId + '-' + i);
            row.put('_sortKey', usageDateStr);
            row.put('usage_date', usageDateStr);
            row.put('monitor_type', rec.get('monitor_type__c') != null
                ? String.valueOf(rec.get('monitor_type__c')) : '');
            row.put('credits_consumed', credits.setScale(0).format());
            row.put('monitor_count', String.valueOf((Integer) monitorCount));
            row.put('tier', rec.get('tier__c') != null
                ? String.valueOf(rec.get('tier__c')) : '');

            tab.rows.add(row);
        }

        return tab;
    }

    // ─── Formatting ───────────────────────────────────────────────

    private static String formatDloResults(List<SObject> records, String accountName,
                                           String externalAccountId, Integer lookbackDays) {
        Decimal totalCredits = 0;
        Decimal maxDailyCredits = 0;
        Map<String, Decimal> byMonitorType = new Map<String, Decimal>();
        // weekKey → {credits, monday (Date)}
        Map<String, Decimal>  byWeekCredits = new Map<String, Decimal>();
        Map<String, Date>     byWeekMonday  = new Map<String, Date>();
        Date mostRecentDate = null;
        Date oldestDate = null;
        Integer totalMonitors = 0;

        List<String> rows = new List<String>();
        for (SObject rec : records) {
            // Defensive date resolution: handle Date, DateTime, or String from DLO
            Date usageDate;
            Object rawDate = rec.get('usage_date__c');
            if (rawDate instanceof Date) {
                usageDate = (Date) rawDate;
            } else if (rawDate instanceof DateTime) {
                usageDate = ((DateTime) rawDate).date();
            } else if (rawDate != null) {
                try { usageDate = Date.valueOf(String.valueOf(rawDate).left(10)); } catch (Exception e) {}
            }

            Decimal credits = rec.get('credits_consumed__c') != null
                ? (Decimal) rec.get('credits_consumed__c') : 0;
            String monitorType = rec.get('monitor_type__c') != null
                ? String.valueOf(rec.get('monitor_type__c')) : 'Unknown';
            Decimal monitorCount = rec.get('monitor_count__c') != null
                ? (Decimal) rec.get('monitor_count__c') : 0;
            String tier = rec.get('tier__c') != null
                ? String.valueOf(rec.get('tier__c')) : '';

            totalCredits += credits;
            if (credits > maxDailyCredits) maxDailyCredits = credits;
            if (usageDate != null) {
                if (mostRecentDate == null || usageDate > mostRecentDate) mostRecentDate = usageDate;
                if (oldestDate == null || usageDate < oldestDate) oldestDate = usageDate;
            }
            totalMonitors += (Integer) monitorCount;

            // Aggregate by monitor type
            if (!byMonitorType.containsKey(monitorType)) byMonitorType.put(monitorType, 0);
            byMonitorType.put(monitorType, byMonitorType.get(monitorType) + credits);

            // Aggregate by calendar week — key is ISO week string for sorting, store Monday for labels
            if (usageDate != null) {
                Date monday = mondayOf(usageDate);
                Integer woy = weekOfYear(usageDate);
                String weekKey = usageDate.year() + '-W' + String.valueOf(woy).leftPad(2, '0');
                if (!byWeekCredits.containsKey(weekKey)) {
                    byWeekCredits.put(weekKey, 0);
                    byWeekMonday.put(weekKey, monday);
                }
                byWeekCredits.put(weekKey, byWeekCredits.get(weekKey) + credits);
            }

            String dateStr = usageDate != null ? String.valueOf(usageDate) : 'Unknown';
            rows.add(dateStr + ' | ' + monitorType + ' | Credits: '
                + credits.setScale(2).format() + ' | Monitors: ' + (Integer) monitorCount + ' | Tier: ' + tier);
        }

        String periodStr = (oldestDate != null && mostRecentDate != null)
            ? String.valueOf(oldestDate) + ' to ' + String.valueOf(mostRecentDate)
            : 'Last ' + lookbackDays + ' days';

        // Format the output for the AI analysis prompt
        List<String> parts = new List<String>();
        parts.add('### DATA CLOUD — Credit Usage: ' + accountName + ' (ID: ' + externalAccountId + ')');
        parts.add('**Period:** ' + periodStr + ' (' + lookbackDays + '-day window)');
        parts.add('**Records found:** ' + records.size());
        parts.add('');
        parts.add('**Summary Statistics:**');
        parts.add('- Total credits consumed: ' + totalCredits.setScale(2).format());
        if (!records.isEmpty()) {
            parts.add('- Daily average: ' + (totalCredits / records.size()).setScale(2).format() + ' credits');
        }
        parts.add('- Peak single day: ' + maxDailyCredits.setScale(2).format() + ' credits');
        parts.add('- Total monitor runs: ' + totalMonitors);
        parts.add('');
        parts.add('**Credits by Monitor Type:**');
        for (String mt : byMonitorType.keySet()) {
            Decimal typeTotal = byMonitorType.get(mt);
            Decimal pct = totalCredits > 0 ? (typeTotal / totalCredits * 100).setScale(1) : 0;
            parts.add('- ' + mt + ': ' + typeTotal.setScale(2).format() + ' (' + pct + '%)');
        }
        parts.add('');
        parts.add('**Weekly Credit Breakdown (most recent 6 weeks, newest first):**');
        List<String> weekKeys = new List<String>(byWeekCredits.keySet());
        weekKeys.sort();
        for (Integer wi = weekKeys.size() - 1; wi >= 0 && wi >= weekKeys.size() - 6; wi--) {
            String wk = weekKeys.get(wi);
            Date mon = byWeekMonday.get(wk);
            Date sun = (mon != null) ? mon.addDays(6) : null;
            String label = (mon != null)
                ? formatDate(mon) + ' – ' + formatDate(sun) + ' (' + wk + ')'
                : wk;
            parts.add('- ' + label + ': ' + byWeekCredits.get(wk).setScale(2).format() + ' credits');
        }
        parts.add('');
        parts.add('**Daily Detail (most recent first, use exact dates when referencing specific days):**');
        for (String row : rows) {
            parts.add('- ' + row);
        }

        return String.join(parts, '\n');
    }

    /** Returns the Monday of the calendar week containing d. */
    private static Date mondayOf(Date d) {
        // Jan 6, 2025 is a Monday — use as epoch anchor
        Date anchor = Date.newInstance(2025, 1, 6);
        Integer diff = anchor.daysBetween(d);
        Integer dayOfWeek = Math.mod(diff, 7);   // 0=Mon, 1=Tue, … 6=Sun
        return d.addDays(-dayOfWeek);
    }

    /** Approximate ISO week number for a given date (used as sort key). */
    private static Integer weekOfYear(Date d) {
        Date jan1 = Date.newInstance(d.year(), 1, 1);
        Integer dayOfYear = jan1.daysBetween(d) + 1;
        return (Integer) Math.ceil(dayOfYear / 7.0);
    }

    /** Format a date as "Mar 9, 2026". */
    private static String formatDate(Date d) {
        if (d == null) return '';
        String[] months = new String[]{ 'Jan','Feb','Mar','Apr','May','Jun',
                                        'Jul','Aug','Sep','Oct','Nov','Dec' };
        return months[d.month() - 1] + ' ' + d.day() + ', ' + d.year();
    }
}
