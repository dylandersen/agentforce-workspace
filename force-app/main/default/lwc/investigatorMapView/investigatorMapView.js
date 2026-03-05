import { LightningElement, api } from "lwc";

export default class InvestigatorMapView extends LightningElement {
  @api addresses = [];
  @api zoomLevel = 10;

  get hasAddresses() {
    return this.addresses && this.addresses.length > 0;
  }

  get markerCount() {
    return this.addresses ? this.addresses.length : 0;
  }

  get mapMarkers() {
    if (!this.addresses) return [];
    return this.addresses.map((addr) => ({
      location: {
        Street: addr.street || "",
        City: addr.city || "",
        State: addr.state || "",
        PostalCode: addr.postalCode || ""
      },
      title: addr.title || "Account",
      description: addr.description || "",
      icon: "standard:account"
    }));
  }

  get routeUrl() {
    if (!this.addresses || this.addresses.length === 0) return "#";
    const waypoints = this.addresses.map((addr) => {
      const parts = [addr.street, addr.city, addr.state, addr.postalCode].filter(Boolean);
      return encodeURIComponent(parts.join(", "));
    });
    return "https://www.google.com/maps/dir/" + waypoints.join("/");
  }
}
