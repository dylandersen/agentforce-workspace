import { LightningElement, api, track, wire } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import { EnclosingTabId, openSubtab } from "lightning/platformWorkspaceApi";
import data360Url from "@salesforce/resourceUrl/data360";

const PAGE_SIZE = 10;

export default class InvestigatorRecordList extends NavigationMixin(
  LightningElement
) {
  @track _processedTabs = [];
  @track _activeTabIndex = 0;
  @track _visibleCounts = {};
  @track _sortField = null;
  @track _sortDirection = null; // 'asc' or 'desc'
  @track _columnWidths = {};
  _recordTabs = [];
  @api loading = false;

  // Resize state (not tracked — only used during drag)
  _resizeField = null;
  _resizeStartX = 0;
  _resizeStartWidth = 0;
  _boundResizeMove = null;
  _boundResizeEnd = null;
  _widthsCaptured = false;

  get showSkeleton() {
    return this.loading && this._processedTabs.length === 0;
  }

  @api
  get recordTabs() {
    return this._recordTabs;
  }
  set recordTabs(value) {
    this._recordTabs = value || [];
    this._processedTabs = this._processTabs(this._recordTabs);
    this._activeTabIndex = 0;
    // Preserve _visibleCounts so "View more" state survives tab data updates
    this._columnWidths = {};
    this._widthsCaptured = false;
    this._setDefaultSort();
  }

  get hasTabs() {
    return this._processedTabs.length > 0;
  }

  get tabs() {
    return this._processedTabs.map((tab, i) => ({
      objectApiName: tab.objectApiName,
      tabLabel: tab.tabLabel,
      iconName: tab.iconName,
      index: i,
      isActive: i === this._activeTabIndex,
      tabClass:
        "tab-item" + (i === this._activeTabIndex ? " tab-active" : ""),
      useCustomImage: !!tab.dataCloudSource,
      customImageUrl: tab.dataCloudSource ? data360Url : null
    }));
  }

  get activeTab() {
    if (this._processedTabs.length === 0) return null;
    const tab =
      this._processedTabs[this._activeTabIndex] || this._processedTabs[0];
    const visibleCount =
      this._visibleCounts[tab.objectApiName] || PAGE_SIZE;

    // Apply sorting
    let sortedRows = [...tab.allRows];
    if (this._sortField) {
      const field = this._sortField;
      const dir = this._sortDirection === "asc" ? 1 : -1;
      const col = tab.columns.find((c) => c.fieldName === field);
      const isNumeric = col && this._isNumericType(col.type);
      const isDate = col && this._isDateType(col.type);

      sortedRows.sort((a, b) => {
        const cellA = a.cells.find((c) => c.key === field);
        const cellB = b.cells.find((c) => c.key === field);
        let valA = cellA ? cellA.rawValue : null;
        let valB = cellB ? cellB.rawValue : null;

        // Nulls last
        if (valA == null && valB == null) return 0;
        if (valA == null) return 1;
        if (valB == null) return -1;

        if (isNumeric) {
          const numA = this._parseNumeric(valA);
          const numB = this._parseNumeric(valB);
          return (numA - numB) * dir;
        }
        if (isDate) {
          const dateA = new Date(valA).getTime();
          const dateB = new Date(valB).getTime();
          return (dateA - dateB) * dir;
        }
        return String(valA).localeCompare(String(valB)) * dir;
      });
    }

    const visibleRows = sortedRows.slice(0, visibleCount);
    const hasMore = sortedRows.length > visibleCount;
    const remaining = sortedRows.length - visibleCount;

    // Decorate columns with sort state and width
    const columns = tab.columns.map((col) => {
      const width = this._columnWidths[col.fieldName];
      return {
        ...col,
        isSorted: this._sortField === col.fieldName,
        isSortedAsc:
          this._sortField === col.fieldName &&
          this._sortDirection === "asc",
        isSortedDesc:
          this._sortField === col.fieldName &&
          this._sortDirection === "desc",
        widthStyle: width ? `width:${width}px;min-width:${width}px;` : ""
      };
    });

    // Only show "refine your question" when we hit the 200-record cap (not for small discrepancies from dedup/supplementary logic)
    const limitReached = tab.totalCount && tab.totalCount > 200 && tab.totalCount > tab.recordCount;
    const limitMessage = limitReached
      ? `Showing ${tab.recordCount} of ${tab.totalCount} total. Refine your question to narrow results.`
      : null;

    // Compute table width: sum of all column pixel widths if available.
    // Once widths are locked we also switch to fixed layout so resize handles work correctly.
    const widthKeys = Object.keys(this._columnWidths);
    let tableStyle = '';
    if (widthKeys.length > 0 && widthKeys.length >= tab.columns.length) {
      const total = tab.columns.reduce((sum, col) => {
        return sum + (this._columnWidths[col.fieldName] || 0);
      }, 0);
      if (total > 0) {
        tableStyle = `table-layout:fixed;width:${total}px;min-width:${total}px;`;
      }
    }

    return {
      ...tab,
      columns,
      rows: visibleRows,
      hasMore,
      remainingCount: remaining,
      viewMoreLabel: `View more\u2026 (${remaining} remaining)`,
      columnCount: tab.columns.length,
      limitReached,
      limitMessage,
      tableStyle,
      hasDataCloudSource: !!tab.dataCloudSource,
      dataCloudSource: tab.dataCloudSource || null,
      dataCloudRecordId: tab.dataCloudRecordId || null
    };
  }

  // ─── Sort ────────────────────────────────────────

  handleSort(event) {
    const field = event.currentTarget.dataset.field;
    if (!field) return;
    if (this._sortField === field) {
      // Toggle between asc and desc only
      this._sortDirection = this._sortDirection === "asc" ? "desc" : "asc";
    } else {
      this._sortField = field;
      this._sortDirection = "desc";
    }
  }

  // ─── Resize ──────────────────────────────────────

  handleResizeStart(event) {
    event.preventDefault();
    event.stopPropagation();
    const field = event.currentTarget.dataset.field;
    if (!field) return;

    // Snapshot ALL column widths from the DOM so every column is locked
    const ths = this.template.querySelectorAll(".record-table thead th");
    const tab = this._processedTabs[this._activeTabIndex];
    if (ths && tab && tab.columns) {
      const snapped = {};
      ths.forEach((th, i) => {
        if (i < tab.columns.length) {
          snapped[tab.columns[i].fieldName] = th.offsetWidth;
        }
      });
      this._columnWidths = snapped;
    }

    const th = event.currentTarget.parentElement;
    this._resizeField = field;
    this._resizeStartX = event.clientX;
    this._resizeStartWidth = th.offsetWidth;

    this._boundResizeMove = this._handleResizeMove.bind(this);
    this._boundResizeEnd = this._handleResizeEnd.bind(this);

    // eslint-disable-next-line @lwc/lwc/no-document-query
    document.addEventListener("mousemove", this._boundResizeMove);
    // eslint-disable-next-line @lwc/lwc/no-document-query
    document.addEventListener("mouseup", this._boundResizeEnd);
    // eslint-disable-next-line @lwc/lwc/no-document-query
    document.body.style.cursor = "col-resize";
    document.body.style.userSelect = "none";
  }

  _handleResizeMove(event) {
    if (!this._resizeField) return;
    const diff = event.clientX - this._resizeStartX;
    const newWidth = Math.max(60, this._resizeStartWidth + diff);
    this._columnWidths = {
      ...this._columnWidths,
      [this._resizeField]: newWidth
    };
  }

  _handleResizeEnd() {
    this._resizeField = null;
    // eslint-disable-next-line @lwc/lwc/no-document-query
    document.removeEventListener("mousemove", this._boundResizeMove);
    // eslint-disable-next-line @lwc/lwc/no-document-query
    document.removeEventListener("mouseup", this._boundResizeEnd);
    document.body.style.cursor = "";
    document.body.style.userSelect = "";
  }

  renderedCallback() {
    if (!this._widthsCaptured && this._processedTabs.length > 0) {
      this._captureColumnWidths();
    }
  }

  _captureColumnWidths() {
    const ths = this.template.querySelectorAll(".record-table thead th");
    if (!ths || ths.length === 0) return;

    const tab = this._processedTabs[this._activeTabIndex];
    if (!tab || !tab.columns) return;

    const widths = {};
    ths.forEach((th, i) => {
      if (i < tab.columns.length) {
        widths[tab.columns[i].fieldName] = th.offsetWidth;
      }
    });

    // Only apply if we got real widths
    if (Object.keys(widths).length > 0) {
      this._columnWidths = widths;
      this._widthsCaptured = true;
    }
  }

  disconnectedCallback() {
    // Clean up in case component is removed mid-resize
    if (this._boundResizeMove) {
      // eslint-disable-next-line @lwc/lwc/no-document-query
      document.removeEventListener("mousemove", this._boundResizeMove);
    }
    if (this._boundResizeEnd) {
      // eslint-disable-next-line @lwc/lwc/no-document-query
      document.removeEventListener("mouseup", this._boundResizeEnd);
    }
  }

  // ─── Tab / View More ─────────────────────────────

  handleTabClick(event) {
    const idx = parseInt(event.currentTarget.dataset.index, 10);
    if (!isNaN(idx) && idx !== this._activeTabIndex) {
      this._activeTabIndex = idx;
      this._columnWidths = {};
      this._widthsCaptured = false;
      this._setDefaultSort();
    }
  }

  handleViewMore() {
    const tab = this._processedTabs[this._activeTabIndex];
    if (!tab) return;
    const current = this._visibleCounts[tab.objectApiName] || PAGE_SIZE;
    this._visibleCounts = {
      ...this._visibleCounts,
      [tab.objectApiName]: current + PAGE_SIZE
    };
  }

  handleExpandClick() {
    this.dispatchEvent(new CustomEvent('expandrecords'));
  }

  @wire(EnclosingTabId)
  _enclosingTabId;

  async handleDloNavigation(event) {
    event.stopPropagation();
    const recordId  = event.currentTarget.dataset.recordId;
    const dloApiName = event.currentTarget.dataset.dloName || this.activeTab?.dataCloudSource;
    if (!dloApiName && !recordId) return;

    // Navigate to the DLO's detail page when we have the record ID,
    // otherwise fall back to the standard object home.
    const pageRef = recordId
      ? {
          type: "standard__recordPage",
          attributes: {
            recordId,
            objectApiName: "DataLakeObjectInstance",
            actionName: "view"
          }
        }
      : {
          type: "standard__objectPage",
          attributes: { objectApiName: dloApiName, actionName: "home" }
        };

    try {
      const tabId = this._enclosingTabId;
      if (tabId) {
        await openSubtab(tabId, {
          pageReference: pageRef,
          label: dloApiName || "Data Lake Object",
          focus: true
        });
      } else {
        this[NavigationMixin.Navigate](pageRef);
      }
    } catch (_err) {
      this[NavigationMixin.Navigate](pageRef);
    }
  }

  handleRecordNav(event) {
    event.preventDefault();
    event.stopPropagation();
    const recordId = event.currentTarget.dataset.recordId;
    const objectApiName = event.currentTarget.dataset.objectName;
    if (recordId) {
      this[NavigationMixin.Navigate]({
        type: "standard__recordPage",
        attributes: {
          recordId,
          objectApiName,
          actionName: "view"
        }
      });
    }
  }

  // ─── Helpers ─────────────────────────────────────

  _setDefaultSort() {
    const tab = this._processedTabs[this._activeTabIndex];
    if (!tab || !tab.columns.length) {
      this._sortField = null;
      this._sortDirection = null;
      return;
    }
    // Prefer the first date column, then first numeric, then first column
    const dateCol = tab.columns.find((c) => this._isDateType(c.type));
    if (dateCol) {
      this._sortField = dateCol.fieldName;
      this._sortDirection = "desc";
      return;
    }
    const numCol = tab.columns.find((c) => this._isNumericType(c.type));
    if (numCol) {
      this._sortField = numCol.fieldName;
      this._sortDirection = "desc";
      return;
    }
    this._sortField = tab.columns[0].fieldName;
    this._sortDirection = "desc";
  }

  _isNumericType(type) {
    return ["CURRENCY", "DOUBLE", "INTEGER", "PERCENT", "LONG"].includes(
      type
    );
  }

  _isDateType(type) {
    return ["DATE", "DATETIME"].includes(type);
  }

  _parseNumeric(val) {
    if (typeof val === "number") return val;
    // Strip currency symbols, commas, whitespace — handle "$85,000", "85,000", etc.
    const cleaned = String(val).replace(/[^0-9.\-]/g, "");
    const num = parseFloat(cleaned);
    return isNaN(num) ? 0 : num;
  }

  _processTabs(tabs) {
    if (!tabs || !tabs.length) return [];

    return tabs.map((tab) => {
      const columns = tab.columns.map((col) => ({
        ...col,
        headerClass:
          "th-cell" + (this._isNumericType(col.type) ? " th-right" : "")
      }));

      const allRows = tab.rows.map((row) => ({
        id: row._id,
        cells: columns.map((col) => {
          const isLink =
            col.isNameField || !!col.linkObjectApiName;
          const linkRecordId = col.linkIdField
            ? row[col.linkIdField]
            : row._id;
          const linkObjectName =
            col.linkObjectApiName || tab.objectApiName;
          const rawValue = row[col.fieldName] ?? null;

          return {
            key: col.fieldName,
            value: row[col.fieldName] || "\u2014",
            rawValue,
            isLink,
            isPlain: !isLink,
            recordId: linkRecordId,
            objectApiName: linkObjectName,
            recordUrl: linkRecordId
              ? `/lightning/r/${linkObjectName}/${linkRecordId}/view`
              : null,
            cellClass:
              "td-cell" +
              (this._isNumericType(col.type) ? " td-right" : ""),
            valueClass: this._isNumericType(col.type)
              ? "numeric-value"
              : ""
          };
        })
      }));

      // Show "X of Y" when total count exceeds displayed count
      const hasMoreTotal = tab.totalCount && tab.totalCount > tab.recordCount;
      const tabLabel = hasMoreTotal
        ? `${tab.objectLabel} (${tab.recordCount} of ${tab.totalCount})`
        : `${tab.objectLabel} (${tab.recordCount})`;

      return {
        objectApiName: tab.objectApiName,
        objectLabel: tab.objectLabel,
        iconName: tab.iconName,
        recordCount: tab.recordCount,
        totalCount: tab.totalCount || null,
        tabLabel,
        columns,
        allRows,
        dataCloudSource: tab.dataCloudSource || null,
        dataCloudRecordId: tab.dataCloudRecordId || null
      };
    });
  }
}