/**
 * Dynamic schema introspection service for the Agentforce Workspace.
 *
 * Replaces hardcoded object lists (icons, name fields, default columns,
 * sort fields) with metadata-driven lookups so the workspace can build
 * record tabs, generate SOQL context, and create records for ANY
 * accessible object — standard or custom.
 *
 * Results are cached in a static map for the duration of the transaction
 * to avoid repeated describe calls.
 */
public with sharing class AgentforceWorkspaceSchemaService {

    // ─── Well-Known Overrides ──────────────────────────────────────
    // Hand-tuned metadata for core CRM objects where the generic
    // describe-based defaults are suboptimal (e.g. Task uses Subject,
    // Case uses CaseNumber).  Everything NOT in these maps falls through
    // to dynamic resolution via DescribeSObjectResult.

    private static final Map<String, String> KNOWN_ICONS = new Map<String, String>{
        'Account'     => 'standard:account',
        'Opportunity' => 'standard:opportunity',
        'Contact'     => 'standard:contact',
        'Case'        => 'standard:case',
        'Lead'        => 'standard:lead',
        'Campaign'    => 'standard:campaign',
        'Task'        => 'standard:task',
        'Event'       => 'standard:event',
        'Contract'    => 'standard:contract',
        'Order'       => 'standard:orders',
        'Product2'    => 'standard:product',
        'Pricebook2'  => 'standard:pricebook',
        'User'        => 'standard:user',
        'Asset'       => 'standard:asset_object',
        'Incident'    => 'standard:incident',
        'Problem'     => 'standard:problem',
        'ChangeRequest' => 'standard:change_request'
    };

    private static final Map<String, String> KNOWN_NAME_FIELDS = new Map<String, String>{
        'Case'  => 'CaseNumber',
        'Task'  => 'Subject',
        'Event' => 'Subject'
    };

    /** Preferred display fields for supplementary queries on well-known objects. */
    private static final Map<String, String> KNOWN_LIST_FIELDS = new Map<String, String>{
        'Opportunity' => 'Id, Name, Account.Name, StageName, Amount, CloseDate',
        'Account'     => 'Id, Name, Industry, Type, LastActivityDate, Phone, BillingCity, BillingState, BillingStreet, BillingPostalCode',
        'Contact'     => 'Id, Name, Account.Name, Email, Phone, Title, MailingCity, MailingState, MailingStreet, MailingPostalCode',
        'Case'        => 'Id, CaseNumber, Subject, Status, Priority, CreatedDate',
        'Lead'        => 'Id, Name, Company, Status, Email, CreatedDate',
        'Campaign'    => 'Id, Name, Status, Type, StartDate',
        'Task'        => 'Id, Subject, Who.Name, What.Name, Status, ActivityDate, TaskSubtype',
        'Event'       => 'Id, Subject, Who.Name, What.Name, StartDateTime, EndDateTime, Location'
    };

    private static final Map<String, String> KNOWN_SORT_FIELDS = new Map<String, String>{
        'Opportunity' => 'CloseDate',
        'Case'        => 'CreatedDate',
        'Lead'        => 'CreatedDate',
        'Account'     => 'Name',
        'Contact'     => 'Name',
        'Campaign'    => 'StartDate',
        'Task'        => 'ActivityDate',
        'Event'       => 'StartDateTime'
    };

    private static final Set<String> KNOWN_SORT_DESC = new Set<String>{
        'Opportunity', 'Case', 'Lead', 'Campaign', 'Task', 'Event'
    };

    /** Preferred tab display order for well-known objects. Unknown objects sort after these. */
    private static final List<String> PREFERRED_TAB_ORDER = new List<String>{
        'Opportunity', 'Account', 'Contact', 'Lead', 'Case', 'Campaign',
        'Task', 'Event', 'Contract', 'Order', 'Incident', 'Problem', 'ChangeRequest'
    };

    // ─── Platform Cache (persists across transactions, 1-hour TTL) ──
    private static final String CACHE_PARTITION = 'local.AgentforceWorkspace';
    private static final Integer CACHE_TTL = 3600;
    private static final String CACHE_VER = 'v1';

    // ─── Transaction-Scoped Cache ──────────────────────────────────

    private static Map<String, Schema.SObjectType> cachedGlobalDescribe;
    private static Map<String, ObjectMeta> cachedMeta = new Map<String, ObjectMeta>();

    // ─── Public DTO ────────────────────────────────────────────────

    /**
     * Everything the QueryService / RecordCreator / BusinessIntelligence
     * needs to know about an SObject for display, querying, and creation.
     */
    public class ObjectMeta {
        public String apiName;
        public String label;
        public String labelPlural;
        public String iconName;
        public String nameField;
        public String defaultListFields;
        public String defaultSortField;
        public Boolean sortDescending;
        public Boolean isAccessible;
        public Boolean isQueryable;
        public Boolean isCreateable;
        public Boolean isUpdateable;
        public Boolean isCustom;
        public List<FieldMeta> fields;
    }

    public class FieldMeta {
        public String apiName;
        public String label;
        public String type;
        public Boolean isRequired;
        public Boolean isCreateable;
        public Boolean isUpdateable;
        public Boolean isNameField;
        public Boolean isAccessible;
        public String referenceTo;
        public List<String> picklistValues;
    }

    // ─── Core API ──────────────────────────────────────────────────

    /** Resolve metadata for a single object. Returns null if not accessible. */
    public static ObjectMeta describe(String objectApiName) {
        if (String.isBlank(objectApiName)) return null;

        if (cachedMeta.containsKey(objectApiName)) {
            return cachedMeta.get(objectApiName);
        }

        ObjectMeta fromPlatformCache = getPlatformCachedMeta(objectApiName);
        if (fromPlatformCache != null) {
            cachedMeta.put(objectApiName, fromPlatformCache);
            return fromPlatformCache;
        }

        Map<String, Schema.SObjectType> gd = getGlobalDescribe();
        Schema.SObjectType sot = gd.get(objectApiName.toLowerCase());
        if (sot == null) return null;

        Schema.DescribeSObjectResult dsr = sot.getDescribe();
        if (!dsr.isAccessible()) return null;

        ObjectMeta meta = buildMeta(objectApiName, dsr);
        cachedMeta.put(objectApiName, meta);
        putPlatformCachedMeta(objectApiName, meta);
        return meta;
    }

    /** Get the icon name for any object. Falls back to 'standard:custom' for custom objects. */
    public static String getIcon(String objectApiName) {
        if (KNOWN_ICONS.containsKey(objectApiName)) {
            return KNOWN_ICONS.get(objectApiName);
        }
        if (objectApiName != null && objectApiName.endsWith('__c')) {
            return 'standard:custom';
        }
        return 'standard:record';
    }

    /** Get the name field for any object (the field used as the record's primary label). */
    public static String getNameField(String objectApiName) {
        if (KNOWN_NAME_FIELDS.containsKey(objectApiName)) {
            return KNOWN_NAME_FIELDS.get(objectApiName);
        }

        Map<String, Schema.SObjectType> gd = getGlobalDescribe();
        Schema.SObjectType sot = gd.get(objectApiName.toLowerCase());
        if (sot == null) return 'Name';

        Map<String, Schema.SObjectField> fieldMap = sot.getDescribe().fields.getMap();
        for (Schema.SObjectField f : fieldMap.values()) {
            Schema.DescribeFieldResult dfr = f.getDescribe();
            if (dfr.isNameField()) {
                return dfr.getName();
            }
        }
        return 'Name';
    }

    /** Get default list fields for supplementary queries. Dynamic fallback for unknown objects. */
    public static String getDefaultListFields(String objectApiName) {
        if (KNOWN_LIST_FIELDS.containsKey(objectApiName)) {
            return KNOWN_LIST_FIELDS.get(objectApiName);
        }
        return buildDynamicListFields(objectApiName);
    }

    /** Get default sort field. Falls back to CreatedDate for unknown objects. */
    public static String getDefaultSortField(String objectApiName) {
        if (KNOWN_SORT_FIELDS.containsKey(objectApiName)) {
            return KNOWN_SORT_FIELDS.get(objectApiName);
        }
        return 'CreatedDate';
    }

    /** Whether the default sort for this object should be descending. */
    public static Boolean isSortDescending(String objectApiName) {
        if (KNOWN_SORT_DESC.contains(objectApiName)) return true;
        // Custom objects default to descending (newest first)
        if (objectApiName != null && objectApiName.endsWith('__c')) return true;
        return false;
    }

    /**
     * Sort a list of object API names in preferred display order.
     * Known objects maintain their preferred position; unknown objects
     * are appended alphabetically by label.
     */
    public static List<String> sortTabOrder(Set<String> objectNames) {
        List<String> ordered = new List<String>();
        Set<String> remaining = new Set<String>(objectNames);

        for (String preferred : PREFERRED_TAB_ORDER) {
            if (remaining.contains(preferred)) {
                ordered.add(preferred);
                remaining.remove(preferred);
            }
        }

        // Sort remaining by label
        Map<String, String> labelMap = new Map<String, String>();
        Map<String, Schema.SObjectType> gd = getGlobalDescribe();
        for (String objName : remaining) {
            Schema.SObjectType sot = gd.get(objName.toLowerCase());
            if (sot != null) {
                labelMap.put(sot.getDescribe().getLabelPlural(), objName);
            } else {
                labelMap.put(objName, objName);
            }
        }
        List<String> sortedLabels = new List<String>(labelMap.keySet());
        sortedLabels.sort();
        for (String lbl : sortedLabels) {
            ordered.add(labelMap.get(lbl));
        }
        return ordered;
    }

    /** Check if an object is accessible to the running user. */
    public static Boolean isAccessible(String objectApiName) {
        Map<String, Schema.SObjectType> gd = getGlobalDescribe();
        Schema.SObjectType sot = gd.get(objectApiName.toLowerCase());
        return sot != null && sot.getDescribe().isAccessible();
    }

    /** Check if an object is createable by the running user. */
    public static Boolean isCreateable(String objectApiName) {
        Map<String, Schema.SObjectType> gd = getGlobalDescribe();
        Schema.SObjectType sot = gd.get(objectApiName.toLowerCase());
        return sot != null && sot.getDescribe().isCreateable();
    }

    /**
     * Build a rich schema context string for custom objects mentioned
     * in the user message. Includes field names, types, and relationships
     * so the LLM can generate accurate SOQL.
     */
    public static String buildCustomObjectSchemaContext(String objectApiName) {
        ObjectMeta meta = describe(objectApiName);
        if (meta == null) return '';

        List<String> parts = new List<String>();
        parts.add('**' + objectApiName + '** — ' + meta.label + '\n');

        List<String> fieldParts = new List<String>();
        List<String> relationshipParts = new List<String>();

        for (FieldMeta f : meta.fields) {
            if (!f.isAccessible) continue;
            fieldParts.add(f.apiName);
            if (String.isNotBlank(f.referenceTo)) {
                relationshipParts.add(f.apiName + ' -> ' + f.referenceTo);
            }
        }

        if (!fieldParts.isEmpty()) {
            parts.add('Key fields: ' + String.join(fieldParts, ', ') + '\n');
        }
        if (!relationshipParts.isEmpty()) {
            parts.add('Relationships: ' + String.join(relationshipParts, ', ') + '\n');
        }
        parts.add('\n');
        return String.join(parts, '');
    }

    /**
     * Return all accessible custom objects as a list of ObjectMeta (lightweight — no field details).
     * Used by BusinessIntelligence.buildSchemaContext() for the custom objects catalog.
     */
    public static List<ObjectMeta> listAccessibleCustomObjects(Integer maxCount) {
        List<ObjectMeta> fromCache = getPlatformCachedObjList(maxCount);
        if (fromCache != null) return fromCache;

        List<ObjectMeta> result = new List<ObjectMeta>();
        Map<String, Schema.SObjectType> gd = getGlobalDescribe();

        List<String> customObjNames = new List<String>();
        for (String objName : gd.keySet()) {
            if (objName.endsWith('__c')) {
                customObjNames.add(objName);
            }
        }
        customObjNames.sort();

        Integer count = 0;
        for (String objName : customObjNames) {
            if (count >= maxCount) break;
            Schema.DescribeSObjectResult dsr = gd.get(objName).getDescribe();
            if (dsr.isQueryable() && dsr.isAccessible()) {
                ObjectMeta meta = new ObjectMeta();
                meta.apiName = dsr.getName();
                meta.label = dsr.getLabel();
                meta.labelPlural = dsr.getLabelPlural();
                meta.isCustom = true;
                meta.isAccessible = true;
                meta.isQueryable = true;
                meta.isCreateable = dsr.isCreateable();
                result.add(meta);
                count++;
            }
        }
        putPlatformCachedObjList(maxCount, result);
        return result;
    }

    // ─── Platform Cache Helpers ────────────────────────────────────
    // All cache operations are wrapped in try/catch — if the partition
    // is not provisioned or has no allocation, we silently fall back
    // to live describes (same behavior as before caching was added).

    private static Cache.OrgPartition getOrgPartition() {
        try {
            return Cache.Org.getPartition(CACHE_PARTITION);
        } catch (Exception e) {
            return null;
        }
    }

    private static ObjectMeta getPlatformCachedMeta(String objectApiName) {
        Cache.OrgPartition p = getOrgPartition();
        if (p == null) return null;
        try {
            String data = (String) p.get(CACHE_VER + '_obj_' + objectApiName.toLowerCase());
            return data != null ? (ObjectMeta) JSON.deserialize(data, ObjectMeta.class) : null;
        } catch (Exception e) { return null; }
    }

    private static void putPlatformCachedMeta(String objectApiName, ObjectMeta meta) {
        Cache.OrgPartition p = getOrgPartition();
        if (p == null) return;
        try {
            p.put(CACHE_VER + '_obj_' + objectApiName.toLowerCase(), JSON.serialize(meta), CACHE_TTL);
        } catch (Exception e) { /* non-critical */ }
    }

    private static List<ObjectMeta> getPlatformCachedObjList(Integer maxCount) {
        Cache.OrgPartition p = getOrgPartition();
        if (p == null) return null;
        try {
            String data = (String) p.get(CACHE_VER + '_list_' + maxCount);
            return data != null ? (List<ObjectMeta>) JSON.deserialize(data, List<ObjectMeta>.class) : null;
        } catch (Exception e) { return null; }
    }

    private static void putPlatformCachedObjList(Integer maxCount, List<ObjectMeta> items) {
        Cache.OrgPartition p = getOrgPartition();
        if (p == null) return;
        try {
            p.put(CACHE_VER + '_list_' + maxCount, JSON.serialize(items), CACHE_TTL);
        } catch (Exception e) { /* non-critical */ }
    }

    // ─── Internal Helpers ──────────────────────────────────────────

    private static Map<String, Schema.SObjectType> getGlobalDescribe() {
        if (cachedGlobalDescribe == null) {
            cachedGlobalDescribe = Schema.getGlobalDescribe();
        }
        return cachedGlobalDescribe;
    }

    private static ObjectMeta buildMeta(String objectApiName, Schema.DescribeSObjectResult dsr) {
        ObjectMeta meta = new ObjectMeta();
        meta.apiName = dsr.getName();
        meta.label = dsr.getLabel();
        meta.labelPlural = dsr.getLabelPlural();
        meta.iconName = getIcon(objectApiName);
        meta.nameField = getNameField(objectApiName);
        meta.defaultListFields = getDefaultListFields(objectApiName);
        meta.defaultSortField = getDefaultSortField(objectApiName);
        meta.sortDescending = isSortDescending(objectApiName);
        meta.isAccessible = dsr.isAccessible();
        meta.isQueryable = dsr.isQueryable();
        meta.isCreateable = dsr.isCreateable();
        meta.isUpdateable = dsr.isUpdateable();
        meta.isCustom = dsr.isCustom();
        meta.fields = describeFields(dsr);
        return meta;
    }

    private static List<FieldMeta> describeFields(Schema.DescribeSObjectResult dsr) {
        List<FieldMeta> result = new List<FieldMeta>();
        Map<String, Schema.SObjectField> fieldMap = dsr.fields.getMap();

        for (Schema.SObjectField f : fieldMap.values()) {
            Schema.DescribeFieldResult dfr = f.getDescribe();
            if (!dfr.isAccessible()) continue;

            FieldMeta fm = new FieldMeta();
            fm.apiName = dfr.getName();
            fm.label = dfr.getLabel();
            fm.type = dfr.getType().name();
            fm.isRequired = !dfr.isNillable() && dfr.isCreateable();
            fm.isCreateable = dfr.isCreateable();
            fm.isUpdateable = dfr.isUpdateable();
            fm.isNameField = dfr.isNameField();
            fm.isAccessible = true;

            List<Schema.SObjectType> refs = dfr.getReferenceTo();
            if (refs != null && !refs.isEmpty()) {
                fm.referenceTo = refs[0].getDescribe().getName();
            }

            if (dfr.getType() == Schema.DisplayType.PICKLIST || dfr.getType() == Schema.DisplayType.MULTIPICKLIST) {
                fm.picklistValues = new List<String>();
                for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
                    if (pe.isActive()) {
                        fm.picklistValues.add(pe.getValue());
                    }
                }
            }

            result.add(fm);
        }
        return result;
    }

    /**
     * Build a dynamic list of fields for an unknown object.
     * Picks: Id, nameField, then up to 6 important accessible fields
     * (prioritizing common patterns: Status, Type, CreatedDate, OwnerId, etc.)
     */
    private static String buildDynamicListFields(String objectApiName) {
        Map<String, Schema.SObjectType> gd = getGlobalDescribe();
        Schema.SObjectType sot = gd.get(objectApiName.toLowerCase());
        if (sot == null) return 'Id, Name';

        Schema.DescribeSObjectResult dsr = sot.getDescribe();
        Map<String, Schema.SObjectField> fieldMap = dsr.fields.getMap();

        List<String> fields = new List<String>();
        fields.add('Id');

        String nameField = getNameField(objectApiName);
        if (fieldMap.containsKey(nameField.toLowerCase())) {
            fields.add(nameField);
        }

        // Priority fields to look for (in order)
        List<String> priorityFields = new List<String>{
            'Status__c', 'Status', 'StageName', 'Type__c', 'Type',
            'Priority__c', 'Priority', 'Amount__c', 'Amount',
            'CreatedDate', 'LastModifiedDate', 'OwnerId'
        };

        Set<String> added = new Set<String>();
        added.add('id');
        added.add(nameField.toLowerCase());

        for (String pf : priorityFields) {
            if (fields.size() >= 8) break;
            if (fieldMap.containsKey(pf.toLowerCase()) && !added.contains(pf.toLowerCase())) {
                Schema.DescribeFieldResult dfr = fieldMap.get(pf.toLowerCase()).getDescribe();
                if (dfr.isAccessible()) {
                    fields.add(dfr.getName());
                    added.add(pf.toLowerCase());
                }
            }
        }

        // Fill remaining slots with accessible custom fields
        if (fields.size() < 8) {
            for (Schema.SObjectField f : fieldMap.values()) {
                if (fields.size() >= 8) break;
                Schema.DescribeFieldResult dfr = f.getDescribe();
                String fn = dfr.getName();
                if (!added.contains(fn.toLowerCase()) && dfr.isAccessible()
                    && fn.endsWith('__c') && dfr.getType() != Schema.DisplayType.TEXTAREA
                    && dfr.getType() != Schema.DisplayType.BASE64) {
                    fields.add(fn);
                    added.add(fn.toLowerCase());
                }
            }
        }

        return String.join(fields, ', ');
    }
}
