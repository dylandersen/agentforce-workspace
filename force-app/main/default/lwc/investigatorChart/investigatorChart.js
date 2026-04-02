import { LightningElement, api } from 'lwc';

const PALETTE = [
  '#17B0A4', '#4a51c9', '#e8a838', '#c23934',
  '#2e844a', '#7c5dc7', '#0d9dda', '#e06e52',
  '#969492', '#1ec8ba'
];

const Y_LINES = 5;

export default class InvestigatorChart extends LightningElement {
  @api chartData;
  @api hideExpand = false;

  get showExpandBtn() {
    return !this.hideExpand;
  }

  get hasData() {
    return this.chartData && this.chartData.items && this.chartData.items.length > 0;
  }

  get isBarChart() {
    return this.chartData?.chartType === 'bar';
  }

  get isHorizontalBar() {
    return this.chartData?.chartType === 'horizontalBar';
  }

  get isDonutChart() {
    return this.chartData?.chartType === 'donut';
  }

  get maxValue() {
    if (!this.hasData) return 0;
    return Math.max(...this.chartData.items.map(i => Math.abs(i.value || 0)));
  }

  get totalValue() {
    if (!this.hasData) return 0;
    return this.chartData.items.reduce((s, i) => s + Math.abs(i.value || 0), 0);
  }

  get processedItems() {
    if (!this.hasData) return [];
    const max = this.maxValue;
    const total = this.totalValue;
    const prefix = this.chartData.valuePrefix || '';
    const suffix = this.chartData.valueSuffix || '';

    return this.chartData.items.map((item, idx) => {
      const val = Math.abs(item.value || 0);
      const color = item.color || PALETTE[idx % PALETTE.length];
      const barPct = max > 0 ? (val / max) * 100 : 0;
      const hbarPct = max > 0 ? Math.max((val / max) * 100, 2) : 2;
      const pct = total > 0 ? ((val / total) * 100).toFixed(1) : '0.0';

      return {
        key: `item-${idx}`,
        label: item.label,
        shortLabel: item.label.length > 12 ? item.label.substring(0, 11) + '…' : item.label,
        shortLabelH: item.label.length > 22 ? item.label.substring(0, 21) + '…' : item.label,
        formattedValue: prefix + this._formatNumber(val) + suffix,
        pctLabel: pct + '%',
        barStyle: `height: ${barPct}%; background: ${color};`,
        hbarStyle: `width: ${hbarPct}%; background: ${color};`,
        swatchStyle: `background: ${color};`,
        color
      };
    });
  }

  // ── Bar chart Y-axis ──

  get yAxisLabels() {
    const max = this.maxValue;
    if (max === 0) return [];
    const niceMax = this._niceMax(max);
    const step = niceMax / Y_LINES;
    const prefix = this.chartData.valuePrefix || '';
    const suffix = this.chartData.valueSuffix || '';
    const labels = [];
    for (let i = Y_LINES; i >= 0; i--) {
      const val = step * i;
      const pct = niceMax > 0 ? ((niceMax - val) / niceMax) * 100 : 0;
      labels.push({
        key: `y-${i}`,
        text: prefix + this._formatNumber(val) + suffix,
        style: `top: ${pct}%;`
      });
    }
    return labels;
  }

  // ── Donut segments ──

  get donutSegments() {
    if (!this.hasData) return [];
    const total = this.totalValue;
    if (total === 0) return [];
    const circumference = 2 * Math.PI * 35; // r=35
    let offset = circumference * 0.25; // start at 12 o'clock
    return this.chartData.items.map((item, idx) => {
      const val = Math.abs(item.value || 0);
      const pct = val / total;
      const dash = pct * circumference;
      const gap = circumference - dash;
      const seg = {
        key: `seg-${idx}`,
        color: item.color || PALETTE[idx % PALETTE.length],
        dashArray: `${dash} ${gap}`,
        dashOffset: `${-offset}`
      };
      offset += dash;
      return seg;
    });
  }

  get donutTotal() {
    const prefix = this.chartData?.valuePrefix || '';
    const suffix = this.chartData?.valueSuffix || '';
    return prefix + this._formatNumber(this.totalValue) + suffix;
  }

  // ── Chart actions ──

  handleCycleType() {
    const order = ['horizontalBar', 'bar', 'donut'];
    const current = this.chartData?.chartType || 'horizontalBar';
    const next = order[(order.indexOf(current) + 1) % order.length];
    this.dispatchEvent(new CustomEvent('cyclechart', { detail: { chartType: next } }));
  }

  handleExpand() {
    this.dispatchEvent(new CustomEvent('expandchart'));
  }

  // ── Helpers ──

  _formatNumber(n) {
    if (n >= 1000000) return (n / 1000000).toFixed(1).replace(/\.0$/, '') + 'M';
    if (n >= 1000) return (n / 1000).toFixed(1).replace(/\.0$/, '') + 'K';
    if (n % 1 !== 0) return n.toFixed(1);
    return String(n);
  }

  _niceMax(max) {
    const magnitude = Math.pow(10, Math.floor(Math.log10(max)));
    const residual = max / magnitude;
    let nice;
    if (residual <= 1) nice = 1;
    else if (residual <= 2) nice = 2;
    else if (residual <= 5) nice = 5;
    else nice = 10;
    return nice * magnitude;
  }
}
