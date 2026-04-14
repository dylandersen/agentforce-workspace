/**
 * Creates a native Salesforce Report filtered to a specific set of record IDs using the
 * Analytics REST API (POST /analytics/reports).
 *
 * WHY REPORT, NOT LIST VIEW:
 *   - Salesforce list views do not expose the Id field as a filter column, so there is no
 *     way to filter a list view to specific record IDs via the Metadata API.
 *   - The Salesforce Analytics REST API supports a single "Id equals id1,id2,...,idN" filter
 *     with no meaningful record limit, making it the correct native solution.
 *
 * SESSION ID:
 *   UserInfo.getSessionId() in Lightning @AuraEnabled Apex returns a UI-scoped token blocked
 *   from all REST API calls. The AgentforceSessionId Visualforce page provides a valid
 *   API-capable session via $Api.Session_Id.
 *
 * RESULT: Synchronous. Creates a saved report and returns its Id for navigation.
 */
public with sharing class AgentforceWorkspaceExportService {

    private static final String API_VERSION = '62.0';

    /**
     * Analytics report type and Id-column name per SObject.
     * Value[0] = Analytics reportType.type
     * Value[1] = filter column for the object's Id field
     */
    // ⚠️  ORG-SPECIFIC: These report type names were verified by querying the Analytics API
    //     (/services/data/v62.0/analytics/reportTypes) on Dylan's SDO org (sdo5).
    //     Report type developer names are NOT guaranteed to be identical across orgs —
    //     custom installs, managed packages, and edition differences can alter them.
    //     If this component is deployed to a different org, re-run the reportTypes query
    //     and update this map before use.
    //
    //     To re-derive: GET /services/data/v62.0/analytics/reportTypes and look for the
    //     simplest single-object type per SObject (e.g. type: "AccountList" for Accounts).
    //
    //     NOTE: Salesforce has no standalone "Contacts only" report type. ContactList
    //     ("Contacts & Accounts") is the only standard contact report type and inner-joins
    //     to Account, so contacts without an Account will not appear — this is a platform
    //     constraint, not a code issue.
    private static final Map<String, String[]> REPORT_TYPE_MAP =
        new Map<String, String[]>{
            'Account'      => new String[]{ 'AccountList',      'ACCOUNT_ID'      },
            'Contact'      => new String[]{ 'ContactList',      'CONTACT_ID'      },
            'Lead'         => new String[]{ 'LeadList',         'LEAD_ID'         },
            'Opportunity'  => new String[]{ 'Opportunity',      'OPPORTUNITY_ID'  },
            'Case'         => new String[]{ 'CaseList',         'CASE_ID'         },
            'Campaign'     => new String[]{ 'CampaignList',     'CAMPAIGN_ID'     },
            'Contract'     => new String[]{ 'ContractList',     'CONTRACT_ID'     }
        };

    /** Returned to the LWC after a successful (or failed) export attempt. */
    public class ExportResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String  reportId;
        @AuraEnabled public Integer totalCount;      // records included in the report
        @AuraEnabled public Integer requestedCount;  // total records originally requested
        @AuraEnabled public String  errorMessage;
        @AuraEnabled public String  warningMessage;  // set when report is created but truncated
    }

    // Analytics API filter values are capped at 1,333 characters.
    // At 18 chars/ID + 1 comma separator = 19 chars each → max ~70 IDs.
    // At 15 chars/ID + 1 comma = 16 chars each → max ~83 IDs.
    private static final Integer MAX_FILTER_CHARS = 1333;

    /**
     * Creates a tabular Salesforce report filtered to the supplied record IDs.
     * A single "Id equals id1,id2,...,idN" filter is used — no record limit.
     *
     * @param objectApiName  SObject API name (e.g. "Contact", "Account")
     * @param objectLabel    Human-readable label used in the report name
     * @param recordIds      List of 18-char record IDs to include
     */
    @AuraEnabled
    public static ExportResult createReport(
            String objectApiName,
            String objectLabel,
            List<String> recordIds) {

        ExportResult result = new ExportResult();
        result.success = false;

        if (String.isBlank(objectApiName) || recordIds == null || recordIds.isEmpty()) {
            result.errorMessage = 'Object API name and at least one record ID are required.';
            return result;
        }

        try {
            // ── 1. Get an API-capable session ID ─────────────────────────────
            String sessionId = getApiSessionId();
            if (String.isBlank(sessionId)) {
                result.errorMessage =
                    'Could not obtain an API session ID. '
                    + 'Ensure the AgentforceSessionId Visualforce page is deployed.';
                return result;
            }

            // ── 2. Resolve report type and Id column for this object ──────────
            String[] meta      = REPORT_TYPE_MAP.get(objectApiName);
            String reportType  = (meta != null) ? meta[0]
                               : objectApiName;                   // best-effort for unknowns
            String idColumn    = (meta != null) ? meta[1]
                               : objectApiName.toUpperCase().replace('__C', '') + '_ID';

            // ── 3. Build the Analytics API JSON payload ───────────────────────
            // Always start with 'AFWorkspace: ' and stay ≤ 40 chars total.
            // Date worst-case: ' (12/31)' = 8 chars.
            String namePrefix    = 'AFWorkspace: ';
            String nameTimestamp = ' (' + Datetime.now().format('M/d') + ')';
            Integer maxLabelLen  = 40 - namePrefix.length() - nameTimestamp.length();
            String labelPart     = objectLabel.length() > maxLabelLen
                                 ? objectLabel.substring(0, Math.max(0, maxLabelLen))
                                 : objectLabel;
            String reportName    = namePrefix + labelPart + nameTimestamp;

            // Comma-separated IDs — Analytics API caps filter values at 1,333 chars.
            // Walk the list and stop before we exceed the limit.
            List<String> safeIds    = new List<String>();
            Integer      charCount  = 0;
            for (String rid : recordIds) {
                Integer needed = rid.length() + (safeIds.isEmpty() ? 0 : 1); // +1 for comma
                if (charCount + needed > MAX_FILTER_CHARS) break;
                safeIds.add(rid);
                charCount += needed;
            }
            String idValues = String.join(safeIds, ',');

            Map<String, Object> payload = new Map<String, Object>{
                'reportMetadata' => new Map<String, Object>{
                    'name'         => reportName,
                    'reportType'   => new Map<String, Object>{ 'type' => reportType },
                    'reportFormat' => 'TABULAR',
                    'scope'        => 'organization',
                    'standardDateFilter' => new Map<String, Object>{
                        'column'        => 'CREATED_DATE',
                        'durationValue' => 'CUSTOM',
                        'startDate'     => '2000-01-01',
                        'endDate'       => '2099-12-31'
                    },
                    'reportFilters' => new List<Object>{
                        new Map<String, Object>{
                            'column'     => idColumn,
                            'filterType' => 'fieldValue',
                            'operator'   => 'equals',
                            'value'      => idValues
                        }
                    }
                }
            };

            // ── 4. POST to Analytics REST API ─────────────────────────────────
            String baseUrl = System.Url.getOrgDomainUrl().toExternalForm();
            HttpRequest req = new HttpRequest();
            req.setEndpoint(baseUrl + '/services/data/v' + API_VERSION + '/analytics/reports');
            req.setMethod('POST');
            req.setHeader('Authorization', 'Bearer ' + sessionId);
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('Accept', 'application/json');
            req.setBody(JSON.serialize(payload));
            req.setTimeout(30000);

            HttpResponse res = new Http().send(req);

            // ── 5. Parse response ─────────────────────────────────────────────
            Integer httpCode = res.getStatusCode();
            if (httpCode < 200 || httpCode >= 300) {
                result.errorMessage = parseAnalyticsError(res.getBody(), httpCode);
                return result;
            }

            Map<String, Object> responseMap =
                (Map<String, Object>) JSON.deserializeUntyped(res.getBody());

            // The report ID lives inside attributes.reportId
            Map<String, Object> attrs =
                (Map<String, Object>) responseMap.get('attributes');
            result.reportId   = (attrs != null) ? (String) attrs.get('reportId') : null;

            if (String.isBlank(result.reportId)) {
                result.errorMessage = 'Report created but could not read reportId from response.';
                return result;
            }

            result.totalCount      = safeIds.size();
            result.requestedCount  = recordIds.size();
            result.success         = true;
            if (safeIds.size() < recordIds.size()) {
                result.warningMessage =
                    'Report includes the first ' + safeIds.size() + ' of ' + recordIds.size()
                    + ' records. The Analytics API filter limit was reached ('
                    + MAX_FILTER_CHARS + ' chars). '
                    + 'Narrow your query or filter by a field like Stage or Close Date to export a smaller set.';
            }
            return result;

        } catch (Exception e) {
            result.errorMessage = e.getTypeName() + ': ' + e.getMessage();
            return result;
        }
    }

    // ── Visualforce session ID ────────────────────────────────────────────────

    @TestVisible
    private static String getApiSessionId() {
        if (Test.isRunningTest()) {
            return UserInfo.getSessionId();
        }
        String content = Page.AgentforceSessionId.getContent().toString();
        return content != null ? content.trim() : null;
    }

    // ── Analytics error parser ────────────────────────────────────────────────

    /**
     * The Analytics API returns errors as a JSON array:
     * [{"errorCode":"...", "message":"..."}]
     */
    private static String parseAnalyticsError(String body, Integer statusCode) {
        try {
            List<Object> errors = (List<Object>) JSON.deserializeUntyped(body);
            if (!errors.isEmpty()) {
                Map<String, Object> err = (Map<String, Object>) errors[0];
                String code = (String) err.get('errorCode');
                String msg  = (String) err.get('message');
                return (code != null ? '[' + code + '] ' : '')
                     + (msg  != null ? msg : 'Unknown Analytics API error.');
            }
        } catch (Exception e) { /* fall through */ }
        return 'Analytics API HTTP ' + statusCode + ': '
            + (body != null ? body.substring(0, Math.min(300, body.length())) : '');
    }
}
