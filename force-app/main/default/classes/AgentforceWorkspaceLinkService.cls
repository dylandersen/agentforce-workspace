/**
 * Record link collection and HTML injection for the Agentforce Workspace feature.
 * Collects record name → ID mappings from query results and injects <a> tags
 * into LLM-generated HTML responses.
 */
public with sharing class AgentforceWorkspaceLinkService {

    /**
     * Collect record names → IDs from query results for all core CRM objects
     * so we can hyperlink every record mention in the LLM's HTML response.
     * Uses pre-fetched oppAccountMap and supplementaryRecords to avoid duplicate queries.
     */
    public static Map<String, List<String>> collectRecordLinks(
            List<BusinessIntelligence.QueryExecution> executions,
            Map<Id, Opportunity> oppAccountMap,
            Map<String, List<SObject>> supplementaryRecords) {
        Map<String, List<String>> links = new Map<String, List<String>>();

        // Phase 1: Collect from individual record results
        Set<Id> eventWhatAccountIds = new Set<Id>();
        for (BusinessIntelligence.QueryExecution exec : executions) {
            if (exec.error != null || exec.results == null || exec.results.isEmpty()) continue;
            if (exec.countResult != null) continue;

            for (SObject record : exec.results) {
                String objType = String.valueOf(record.getSObjectType());

                // Add primary link + traverse relationship fields for any accessible object
                if (AgentforceWorkspaceSchemaService.isAccessible(objType)) {
                    addLink(links, record, objType);

                    Map<String, Object> fields = record.getPopulatedFieldsAsMap();
                    for (String fieldName : fields.keySet()) {
                        Object val = fields.get(fieldName);
                        if (val instanceof SObject) {
                            SObject rel = (SObject) val;
                            String relType = String.valueOf(rel.getSObjectType());
                            if (AgentforceWorkspaceSchemaService.isAccessible(relType)) {
                                addLink(links, rel, relType);
                            }
                        }
                    }
                }

                // For Event records: extract WhatId values that are Account IDs (prefix '001')
                if (objType == 'Event') {
                    Map<String, Object> eventFields = record.getPopulatedFieldsAsMap();
                    Object whatId = eventFields.get('WhatId');
                    if (whatId != null) {
                        String whatIdStr = String.valueOf(whatId);
                        if (whatIdStr.startsWith('001')) {
                            eventWhatAccountIds.add((Id) whatIdStr);
                        }
                    }
                }
            }
        }

        // Phase 1b: Look up Account names from Event.WhatId Account IDs
        if (!eventWhatAccountIds.isEmpty()) {
            try {
                for (Account acc : [SELECT Id, Name FROM Account WHERE Id IN :eventWhatAccountIds WITH USER_MODE LIMIT 200]) {
                    if (String.isNotBlank(acc.Name) && acc.Name.length() >= 4) {
                        links.put(acc.Name, new List<String>{ acc.Id, 'Account' });
                    }
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'Event account link lookup failed: ' + e.getMessage());
            }
        }

        // Phase 2: Use pre-fetched Account names for Opportunities
        for (Opportunity opp : oppAccountMap.values()) {
            if (opp.Account != null && String.isNotBlank(opp.Account.Name) && opp.Account.Name.length() >= 4) {
                links.put(opp.Account.Name, new List<String>{ opp.AccountId, 'Account' });
            }
        }

        // Phase 3: Use pre-fetched supplementary records for aggregate-only objects
        for (String objType : supplementaryRecords.keySet()) {
            for (SObject rec : supplementaryRecords.get(objType)) {
                addLink(links, rec, objType);
            }
        }

        return links;
    }

    /**
     * Safely inject record links by first stripping <CHART> and <SUGGESTIONS> blocks
     * (which contain JSON that would be corrupted by string replacement), running
     * injectRecordLinks on the HTML portion only, then re-appending the blocks.
     */
    public static String safeInjectRecordLinks(String raw, Map<String, List<String>> links) {
        if (links.isEmpty() || String.isBlank(raw)) return raw;

        String chartBlock = '';
        String suggestionsBlock = '';
        String htmlPortion = raw;

        Integer chartOpen = htmlPortion.indexOf('<CHART>');
        Integer chartClose = htmlPortion.indexOf('</CHART>');
        if (chartOpen != -1 && chartClose != -1 && chartClose > chartOpen) {
            chartBlock = htmlPortion.substring(chartOpen, chartClose + 8);
            htmlPortion = htmlPortion.substring(0, chartOpen) + htmlPortion.substring(chartClose + 8);
        }

        Integer sugOpen = htmlPortion.indexOf('<SUGGESTIONS>');
        Integer sugClose = htmlPortion.indexOf('</SUGGESTIONS>');
        if (sugOpen != -1 && sugClose != -1 && sugClose > sugOpen) {
            suggestionsBlock = htmlPortion.substring(sugOpen, sugClose + 14);
            htmlPortion = htmlPortion.substring(0, sugOpen);
        }

        htmlPortion = injectRecordLinks(htmlPortion, links);

        String result = htmlPortion.trim();
        if (String.isNotBlank(chartBlock)) result += '\n' + chartBlock;
        if (String.isNotBlank(suggestionsBlock)) result += '\n' + suggestionsBlock;
        return result;
    }

    private static void addLink(Map<String, List<String>> links, SObject record, String objType) {
        Map<String, Object> fields = record.getPopulatedFieldsAsMap();
        String nameField = AgentforceWorkspaceSchemaService.getNameField(objType);
        String name = (String) fields.get(nameField);
        if (String.isBlank(name)) name = (String) fields.get('Name');
        String recordId = record.Id;
        if (String.isBlank(name) || String.isBlank(recordId) || name.length() < 4) return;

        List<String> ref = new List<String>{ recordId, objType };
        links.put(name, ref);

        // Add alternate keys so injectRecordLinks matches common LLM phrasings
        if (objType == 'Case') {
            links.put('Case ' + name, ref);
        }
    }

    private static String injectRecordLinks(String html, Map<String, List<String>> links) {
        if (links.isEmpty() || String.isBlank(html)) return html;

        // Sort names by length descending so longer names match first
        List<AgentforceWorkspaceModels.NameLengthSorter> sorters = new List<AgentforceWorkspaceModels.NameLengthSorter>();
        for (String n : links.keySet()) {
            sorters.add(new AgentforceWorkspaceModels.NameLengthSorter(n));
        }
        sorters.sort();
        List<String> names = new List<String>();
        for (AgentforceWorkspaceModels.NameLengthSorter s : sorters) {
            names.add(s.name);
        }

        // Phase 1: Replace unlinked names with unique placeholders
        Map<String, String> placeholders = new Map<String, String>();
        for (Integer i = 0; i < names.size(); i++) {
            String name = names[i];
            if (!html.contains(name)) continue;

            // Skip if every occurrence of this name is already inside an <a> tag
            String alreadyLinked = '>' + name + '</a>';
            String alreadyLinkedBold = '><b>' + name + '</b></a>';
            String plainOccurrence = name;
            // Only inject if there's at least one occurrence NOT already inside an <a> tag
            String testHtml = html.replace(alreadyLinked, '');
            if (!testHtml.contains(plainOccurrence)) continue;

            String placeholder = '\u00AB' + i + '\u00BB';
            // Only replace occurrences that are NOT already linked
            // Replace already-linked versions with safe tokens first
            String safeToken = '\u00AC' + i + '\u00AE';
            String safeToken2 = '\u00AC' + i + 'b\u00AE';
            html = html.replace(alreadyLinkedBold, safeToken2);
            html = html.replace(alreadyLinked, safeToken);
            // Now replace remaining (unlinked) occurrences
            html = html.replace(name, placeholder);
            // Restore the already-linked versions
            html = html.replace(safeToken2, alreadyLinkedBold);
            html = html.replace(safeToken, alreadyLinked);
            placeholders.put(placeholder, name);
        }

        // Phase 2: Replace placeholders with <a> tags
        for (String placeholder : placeholders.keySet()) {
            String name = placeholders.get(placeholder);
            List<String> ref = links.get(name);
            String url = '/lightning/r/' + ref[1] + '/' + ref[0] + '/view';
            html = html.replace(placeholder, '<a href="' + url + '"><b>' + name + '</b></a>');
        }

        return html;
    }
}
