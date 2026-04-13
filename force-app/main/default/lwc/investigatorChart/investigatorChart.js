import { LightningElement, api } from 'lwc';

const PALETTE = [
  '#17B0A4', '#4a51c9', '#e8a838', '#c23934',
  '#2e844a', '#7c5dc7', '#0d9dda', '#e06e52',
  '#969492', '#1ec8ba'
];

const SUPPORTED_CHART_TYPES = ['horizontalBar', 'bar', 'donut', 'line', 'funnel', 'metricStrip'];
const Y_LINES = 5;
const TIME_LABEL_PATTERN = /^(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec|q[1-4]|fy ?\d{2,4}|\d{4}|\d{4}-\d{2}|\d{1,2}[/-]\d{1,2}([/-]\d{2,4})?|week \d+|wk \d+|today|yesterday|monday|tuesday|wednesday|thursday|friday|saturday|sunday)/i;
const FUNNEL_STAGE_HINT_PATTERN = /(stage|step|prospect|prospecting|qualification|qualified|discovery|demo|proposal|quote|negotiat|contract|closed|won|lost|lead|mql|sql|opportunit|meeting|trial|engaged|contacted|responded|converted|new|working|pending|escalated|resolved|triage|assigned|in progress)/i;
const METRIC_LABEL_PATTERN = /(amount|value|days|revenue|probability|score|total|count|average|avg|arr|acv|size|velocity|health|risk|coverage|quota|goal|target|open deals|open cases|close date|days to close|%)/i;

export default class InvestigatorChart extends LightningElement {
  @api chartData;
  @api hideExpand = false;

  get showExpandBtn() {
    return !this.hideExpand;
  }

  get hasData() {
    return this.items.length > 0;
  }

  get items() {
    return this.chartData?.items || [];
  }

  get itemCount() {
    return this.items.length;
  }

  get requestedChartType() {
    return this._normalizeChartType(this.chartData?.chartType);
  }

  get normalizedChartType() {
    if (this._canRenderChartType(this.requestedChartType)) {
      return this.requestedChartType;
    }
    const alternates = this.availableChartTypes;
    return alternates.length > 0 ? alternates[0] : 'horizontalBar';
  }

  get isBarChart() {
    return this.normalizedChartType === 'bar';
  }

  get isHorizontalBar() {
    return this.normalizedChartType === 'horizontalBar';
  }

  get isDonutChart() {
    return this.normalizedChartType === 'donut';
  }

  get isLineChart() {
    return this.normalizedChartType === 'line';
  }

  get isFunnelChart() {
    return this.normalizedChartType === 'funnel';
  }

  get isMetricStrip() {
    return this.normalizedChartType === 'metricStrip';
  }

  get availableChartTypes() {
    const ordered = [];
    const add = (type) => {
      if (!type || ordered.includes(type) || !this._canRenderChartType(type)) return;
      ordered.push(type);
    };

    add(this.requestedChartType);

    if (this.isTimeSeriesData) {
      add('line');
      add('bar');
      add('horizontalBar');
      add('metricStrip');
      return ordered;
    }

    if (this.looksFunnelLikeData) {
      add('funnel');
    }
    add('metricStrip');
    add('horizontalBar');
    add('bar');
    add('donut');
    add('funnel');
    add('line');

    if (ordered.length === 0) {
      ordered.push('horizontalBar');
    }
    return ordered;
  }

  get cycleTitle() {
    return this.availableChartTypes.length > 1 ? 'Switch visualization' : 'Visualization locked';
  }

  get cycleDisabled() {
    return this.availableChartTypes.length <= 1;
  }

  get chartTypeLabel() {
    const labels = {
      horizontalBar: 'ranked view',
      bar: 'column view',
      donut: 'share view',
      line: 'trend view',
      funnel: 'funnel view',
      metricStrip: 'kpi view'
    };
    return labels[this.normalizedChartType] || 'chart view';
  }

  get showMetricShare() {
    return this.itemCount > 1;
  }

  get maxValue() {
    if (!this.hasData) return 0;
    return Math.max(...this.items.map((item) => Math.abs(Number(item.value) || 0)));
  }

  get totalValue() {
    if (!this.hasData) return 0;
    return this.items.reduce((sum, item) => sum + Math.abs(Number(item.value) || 0), 0);
  }

  get niceMaxValue() {
    return this.maxValue > 0 ? this._niceMax(this.maxValue) : 0;
  }

  get processedItems() {
    if (!this.hasData) return [];

    const max = this.maxValue;
    const total = this.totalValue;
    const defaultPrefix = this.chartData?.valuePrefix || '';
    const defaultSuffix = this.chartData?.valueSuffix || '';

    return this.items.map((item, idx) => {
      const label = this._coerceLabel(item.label, idx);
      const rawValue = Number(item.value) || 0;
      const magnitude = Math.abs(rawValue);
      const color = item.color || PALETTE[idx % PALETTE.length];
      const prefix = item.valuePrefix != null ? item.valuePrefix : defaultPrefix;
      const suffix = item.valueSuffix != null ? item.valueSuffix : defaultSuffix;
      const sharePct = total > 0 ? (magnitude / total) * 100 : 0;
      const relativePct = max > 0 ? (magnitude / max) * 100 : 0;
      const funnelWidth = max > 0 ? Math.max(relativePct, 28) : 28;

      return {
        key: `item-${idx}`,
        label,
        shortLabel: label.length > 12 ? `${label.substring(0, 11)}…` : label,
        shortLabelH: label.length > 22 ? `${label.substring(0, 21)}…` : label,
        rawValue,
        magnitude,
        formattedValue: `${prefix}${this._formatNumber(rawValue)}${suffix}`,
        valuePrefix: prefix,
        valueSuffix: suffix,
        pctLabel: `${sharePct.toFixed(1)}%`,
        sharePct,
        barStyle: `height: ${relativePct}%; background: ${color};`,
        hbarStyle: `width: ${Math.max(relativePct, 2)}%; background: ${color};`,
        swatchStyle: `background: ${color};`,
        funnelStyle: `width: ${funnelWidth}%; background: linear-gradient(135deg, ${color}, ${this._tintColor(color)});`,
        metricAccentStyle: `background: linear-gradient(135deg, ${color}, ${this._tintColor(color)});`,
        color
      };
    });
  }

  get hasMultipleChartTypes() {
    return this.availableChartTypes.length > 1;
  }

  get isTimeSeriesData() {
    if (this.itemCount < 3) return false;
    const labels = this.items.map((item) => String(item.label || '').trim()).filter(Boolean);
    if (labels.length < 3) return false;
    const matched = labels.filter((label) => TIME_LABEL_PATTERN.test(label)).length;
    return matched >= Math.max(2, Math.ceil(labels.length * 0.6));
  }

  get looksFunnelLikeData() {
    if (this.itemCount < 3 || this.itemCount > 8 || this.isTimeSeriesData) return false;
    const values = this.processedItems.map((item) => item.magnitude);
    let descendingPairs = 0;
    for (let idx = 1; idx < values.length; idx += 1) {
      if (values[idx] <= values[idx - 1]) descendingPairs += 1;
    }
    return descendingPairs >= values.length - 2;
  }

  get hasFunnelStageLabels() {
    if (this.itemCount < 3 || this.itemCount > 8) return false;
    const labels = this.processedItems.map((item) => item.label);
    const stageMatches = labels.filter((label) => FUNNEL_STAGE_HINT_PATTERN.test(label)).length;
    const metricMatches = labels.filter((label) => METRIC_LABEL_PATTERN.test(label)).length;
    return stageMatches >= Math.ceil(labels.length / 2) && metricMatches <= Math.floor(labels.length / 3);
  }

  get canRenderFunnel() {
    return this.looksFunnelLikeData && this.hasFunnelStageLabels;
  }

  get yAxisLabels() {
    if (this.niceMaxValue === 0) return [];

    const step = this.niceMaxValue / Y_LINES;
    const prefix = this.chartData?.valuePrefix || '';
    const suffix = this.chartData?.valueSuffix || '';
    const labels = [];

    for (let idx = Y_LINES; idx >= 0; idx -= 1) {
      const value = step * idx;
      const pct = this.niceMaxValue > 0 ? ((this.niceMaxValue - value) / this.niceMaxValue) * 100 : 0;
      labels.push({
        key: `y-${idx}`,
        text: `${prefix}${this._formatNumber(value)}${suffix}`,
        style: `top: ${pct}%;`,
        positionPct: pct
      });
    }
    return labels;
  }

  get donutSegments() {
    if (!this.isDonutChart || this.totalValue === 0) return [];

    const circumference = 2 * Math.PI * 35;
    let offset = circumference * 0.25;

    return this.processedItems.map((item) => {
      const pct = item.magnitude / this.totalValue;
      const dash = pct * circumference;
      const gap = circumference - dash;
      const segment = {
        key: `seg-${item.key}`,
        color: item.color,
        dashArray: `${dash} ${gap}`,
        dashOffset: `${-offset}`
      };
      offset += dash;
      return segment;
    });
  }

  get donutTotal() {
    const prefix = this.chartData?.valuePrefix || '';
    const suffix = this.chartData?.valueSuffix || '';
    return `${prefix}${this._formatNumber(this.totalValue)}${suffix}`;
  }

  get linePoints() {
    if (!this.isLineChart || this.itemCount < 2 || this.niceMaxValue === 0) return '';
    return this.linePointNodes.map((point) => `${point.x},${point.y}`).join(' ');
  }

  get lineAreaPoints() {
    if (!this.linePoints || this.linePointNodes.length === 0) return '';
    const first = this.linePointNodes[0];
    const last = this.linePointNodes[this.linePointNodes.length - 1];
    return `0,100 ${first.x},${first.y} ${this.linePoints} ${last.x},100`;
  }

  get linePointNodes() {
    if (!this.hasData || this.niceMaxValue === 0) return [];

    const count = this.processedItems.length;
    return this.processedItems.map((item, idx) => {
      const x = count === 1 ? 50 : (idx / (count - 1)) * 100;
      const y = 100 - ((item.magnitude / this.niceMaxValue) * 100);
      return {
        ...item,
        x,
        y,
        style: `left: ${x}%; top: ${y}%;`
      };
    });
  }

  get funnelItems() {
    if (!this.isFunnelChart) return [];

    const firstValue = this.processedItems.length > 0 ? this.processedItems[0].magnitude : 0;
    let previousValue = firstValue;

    return this.processedItems.map((item, idx) => {
      const fromStartPct = firstValue > 0 ? (item.magnitude / firstValue) * 100 : 0;
      const fromPreviousPct = idx === 0 || previousValue === 0
        ? 100
        : (item.magnitude / previousValue) * 100;
      previousValue = item.magnitude;

      return {
        ...item,
        fromStartLabel: `${fromStartPct.toFixed(0)}% of start`,
        fromPreviousLabel: idx === 0 ? 'Starting volume' : `${fromPreviousPct.toFixed(0)}% of prior step`
      };
    });
  }

  get funnelSegments() {
    if (!this.canRenderFunnel) return [];

    const segments = [];
    const height = 100 / this.processedItems.length;

    for (let idx = 0; idx < this.processedItems.length; idx += 1) {
      const item = this.processedItems[idx];
      const nextItem = this.processedItems[idx + 1];
      const topWidth = this._funnelWidthForMagnitude(item.magnitude);
      const bottomWidth = nextItem
        ? this._funnelWidthForMagnitude(nextItem.magnitude)
        : Math.max(topWidth * 0.62, 16);
      const topY = idx * height;
      const bottomY = (idx + 1) * height;
      const topLeft = 50 - (topWidth / 2);
      const topRight = 50 + (topWidth / 2);
      const bottomLeft = 50 - (bottomWidth / 2);
      const bottomRight = 50 + (bottomWidth / 2);

      segments.push({
        ...item,
        key: `funnel-${item.key}`,
        fill: item.color,
        points: `${topLeft},${topY} ${topRight},${topY} ${bottomRight},${bottomY} ${bottomLeft},${bottomY}`,
        centerY: topY + (height / 2),
        valueY: topY + (height / 2) - 1,
        labelY: topY + (height / 2) + 7
      });
    }

    return segments;
  }

  handleCycleType() {
    const order = this.availableChartTypes;
    if (order.length <= 1) return;

    const current = this.normalizedChartType;
    const currentIndex = order.indexOf(current);
    const next = order[(currentIndex + 1) % order.length];
    this.dispatchEvent(new CustomEvent('cyclechart', { detail: { chartType: next } }));
  }

  handleExpand() {
    this.dispatchEvent(new CustomEvent('expandchart'));
  }

  _canRenderChartType(chartType) {
    if (!SUPPORTED_CHART_TYPES.includes(chartType)) return false;
    if (chartType === 'metricStrip') return this.itemCount > 0 && this.itemCount <= 4;
    if (chartType === 'line') return this.itemCount >= 3 && (this.isTimeSeriesData || this.requestedChartType === 'line');
    if (chartType === 'funnel') return this.canRenderFunnel;
    if (chartType === 'donut') return this.itemCount >= 2 && this.itemCount <= 6 && !this.isTimeSeriesData;
    return this.itemCount > 0;
  }

  _normalizeChartType(chartType) {
    return SUPPORTED_CHART_TYPES.includes(chartType) ? chartType : 'horizontalBar';
  }

  _coerceLabel(label, idx) {
    const safeLabel = String(label || '').trim();
    return safeLabel || `Item ${idx + 1}`;
  }

  _formatNumber(value) {
    const numeric = Number(value) || 0;
    const abs = Math.abs(numeric);
    const sign = numeric < 0 ? '-' : '';

    if (abs >= 1000000) return `${sign}${(abs / 1000000).toFixed(1).replace(/\.0$/, '')}M`;
    if (abs >= 1000) return `${sign}${(abs / 1000).toFixed(1).replace(/\.0$/, '')}K`;
    if (abs % 1 !== 0) return `${sign}${abs.toFixed(1)}`;
    return `${sign}${abs}`;
  }

  _niceMax(max) {
    if (!max) return 0;
    const magnitude = Math.pow(10, Math.floor(Math.log10(max)));
    const residual = max / magnitude;
    let nice;
    if (residual <= 1) nice = 1;
    else if (residual <= 2) nice = 2;
    else if (residual <= 5) nice = 5;
    else nice = 10;
    return nice * magnitude;
  }

  _tintColor(hex) {
    if (!hex || !hex.startsWith('#') || hex.length !== 7) {
      return hex || '#7fd7d0';
    }

    const red = parseInt(hex.substring(1, 3), 16);
    const green = parseInt(hex.substring(3, 5), 16);
    const blue = parseInt(hex.substring(5, 7), 16);

    const mix = (channel) => Math.round(channel + (255 - channel) * 0.24);
    return `rgb(${mix(red)}, ${mix(green)}, ${mix(blue)})`;
  }

  _funnelWidthForMagnitude(magnitude) {
    const max = this.maxValue || 1;
    const pct = (magnitude / max) * 100;
    return Math.max(pct, 18);
  }
}
