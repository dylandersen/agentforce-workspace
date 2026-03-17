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

  get mapTitle() {
    if (!this.addresses || this.addresses.length === 0) return "Locations";
    const types = new Set(this.addresses.map((a) => a.type || "Account"));
    if (types.size === 1) {
      const t = [...types][0];
      return t === "Contact" ? "Contact Locations" : "Account Locations";
    }
    return "Account & Contact Locations";
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
      title: addr.title || "Record",
      description: addr.description || "",
      icon: addr.type === "Contact" ? "standard:contact" : "standard:account",
      mapIcon: {
        path: "M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7z",
        fillColor: addr.type === "Contact" ? "#E67300" : "#17B0A4",
        fillOpacity: 1,
        strokeWeight: 1,
        strokeColor: "#ffffff",
        scale: 1.4
      }
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

  get hasLegend() {
    if (!this.addresses) return false;
    const types = new Set(this.addresses.map((a) => a.type || "Account"));
    return types.size > 1;
  }
}
