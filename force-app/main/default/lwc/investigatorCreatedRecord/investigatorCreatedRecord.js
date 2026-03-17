import { LightningElement, api } from "lwc";
import { NavigationMixin } from "lightning/navigation";

export default class InvestigatorCreatedRecord extends NavigationMixin(
  LightningElement
) {
  @api createdRecord;

  get hasRecord() {
    return !!this.createdRecord;
  }

  get recordName() {
    return this.createdRecord?.recordName || "";
  }

  get objectLabel() {
    return this.createdRecord?.objectLabel || "Record";
  }

  get iconName() {
    return this.createdRecord?.iconName || "standard:record";
  }

  get fields() {
    return (this.createdRecord?.fields || []).map((f, i) => ({
      ...f,
      key: `field-${i}`
    }));
  }

  get hasFields() {
    return this.fields.length > 0;
  }

  handleViewRecord(event) {
    event.preventDefault();
    const recordId = this.createdRecord?.recordId;
    const objectApiName = this.createdRecord?.objectApiName;
    if (recordId) {
      this.dispatchEvent(new CustomEvent('viewrecord', {
        detail: { recordId, objectApiName },
        bubbles: true,
        composed: true
      }));
    }
  }

  handleNavigateToRecord(event) {
    event.preventDefault();
    const recordId = this.createdRecord?.recordId;
    const objectApiName = this.createdRecord?.objectApiName;
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
}