/* Offline report charts: SVG and embedded numeric data, with no network requests. */
(() => {
  'use strict';
  const data = JSON.parse(document.getElementById('chart-data').textContent);
  const ns = 'http://www.w3.org/2000/svg';
  const colors = ['#3581d8', '#d87516'];
  const phaseColors = {idle:'#94a3b8',cpu:'#9b7bd5','cpu-single':'#b38cdb',gpu:'#e5a04b',combo:'#49a99c',cool1:'#cbd5e1',cool2:'#cbd5e1'};
  const timeline = [];
  const charts = [];
  const finite = value => typeof value === 'number' && Number.isFinite(value);
  const num = value => finite(value) ? value.toLocaleString('ru-RU', {maximumFractionDigits:1}) : '—';
  const time = value => {
    const seconds = Math.max(0, Math.round(value));
    return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
  };
  function element(tag, attributes = {}, text) {
    const node = document.createElementNS(ns, tag);
    Object.entries(attributes).forEach(([key, value]) => node.setAttribute(key, value));
    if (text !== undefined) node.textContent = text;
    return node;
  }
  function legend(parent, items) {
    const row = document.createElement('div');
    row.className = 'chart-legend';
    items.forEach(item => {
      const span = document.createElement('span');
      const key = document.createElement('i');
      key.className = 'chart-key';
      key.style.background = item.color;
      span.append(key, document.createTextNode(item.label));
      row.append(span);
    });
    parent.append(row);
  }
  // Binary search avoids scanning an entire run on every pointer movement.
  function nearest(points, x) {
    if (!points.length) return null;
    let low = 0, high = points.length;
    while (low < high) {
      const middle = (low + high) >>> 1;
      if (points[middle][0] < x) low = middle + 1;
      else high = middle;
    }
    const before = points[Math.max(0, low - 1)];
    const after = points[Math.min(points.length - 1, low)];
    return Math.abs(before[0] - x) <= Math.abs(after[0] - x) ? before : after;
  }
  function createChart(parentId, options) {
    const card = document.createElement('article');
    card.className = 'chart-card';
    const heading = document.createElement('h3');
    heading.textContent = options.title;
    card.append(heading);
    if (options.series.length > 1) legend(card, options.series.map((s, i) => ({label:s.label, color:s.color || colors[i % colors.length]})));
    const plot = element('svg', {viewBox:'0 0 720 245', role:'img', tabindex:'0', 'aria-label':`${options.title}. Стрелки влево и вправо перемещают курсор.`});
    const empty = document.createElement('p');
    empty.className = 'chart-empty';
    empty.textContent = options.empty || 'Нет пригодных показаний за выбранный этап.';
    const readout = document.createElement('p');
    readout.className = 'chart-readout';
    card.append(plot, empty, readout);
    document.getElementById(parentId).append(card);
    const chart = {options, plot, empty, readout, series:[], cursor:null, min:0, max:1, x:0};
    charts.push(chart);
    if (options.timeline) timeline.push(chart);
    function move(x) {
      if (options.timeline) timeline.forEach(c => updateCursor(c, x));
      else updateCursor(chart, x);
    }
    plot.addEventListener('pointermove', event => {
      const bounds = plot.getBoundingClientRect();
      const fraction = ((event.clientX - bounds.left) * 720 / bounds.width - 64) / 638;
      move(chart.min + Math.max(0, Math.min(1, fraction)) * (chart.max - chart.min));
    });
    plot.addEventListener('pointerleave', () => {
      (options.timeline ? timeline : [chart]).forEach(c => updateCursor(c, null));
    });
    plot.addEventListener('keydown', event => {
      if (!['ArrowLeft','ArrowRight','Home','End','Escape'].includes(event.key)) return;
      event.preventDefault();
      if (event.key === 'Escape') return (options.timeline ? timeline : [chart]).forEach(c => updateCursor(c, null));
      let x = chart.x;
      if (event.key === 'Home') x = chart.min;
      else if (event.key === 'End') x = chart.max;
      else x += (event.key === 'ArrowLeft' ? -1 : 1) * (chart.max - chart.min) / 100;
      move(Math.max(chart.min, Math.min(chart.max, x)));
    });
    return chart;
  }
  function updateCursor(chart, x) {
    if (!chart.cursor) return;
    chart.cursor.setAttribute('visibility', x === null ? 'hidden' : 'visible');
    if (x === null) {
      chart.readout.textContent = chart.summary;
      return;
    }
    chart.x = x;
    const pixel = 64 + (x - chart.min) / (chart.max - chart.min) * 638;
    chart.cursor.setAttribute('x1', pixel);
    chart.cursor.setAttribute('x2', pixel);
    const parts = chart.series.map(s => {
      const point = nearest(s.points, x);
      const valid = point && finite(point[1]) && Math.abs(point[0] - x) <= (chart.options.maxGap || 5);
      return `${s.label}: ${valid ? num(point[1]) : '—'} ${chart.options.unit}`;
    });
    chart.readout.textContent = `${chart.options.passAxis ? `Проход ${Math.round(x)}` : time(x)} · ${parts.join(' · ')}`;
  }
  function render(chart, min, max) {
    const {options, plot, empty, readout} = chart;
    plot.replaceChildren();
    chart.cursor = null;
    chart.min = min;
    chart.max = Math.max(min + 1, max);
    chart.x = min;
    chart.series = options.series.map(s => ({...s, points:s.points.filter(p => finite(p[0]) && p[0] >= min && p[0] <= chart.max).sort((a,b) => a[0]-b[0])}));
    const values = chart.series.flatMap(s => s.points.filter(p => finite(p[1])).map(p => p[1]));
    const hasValues = values.length > 0;
    plot.toggleAttribute('hidden', !hasValues);
    empty.hidden = hasValues;
    readout.hidden = !hasValues;
    if (!hasValues) return;
    const left = 64, right = 702, top = 26, bottom = 194;
    const x = value => left + (value - min) / (chart.max - min) * (right - left);
    const peak = Math.max(options.floorMax || 1, ...values);
    const step = 10 ** Math.floor(Math.log10(peak / 4));
    const tick = [1, 2, 2.5, 5, 10].map(n => n * step).find(n => n >= peak / 4);
    const ceiling = Math.ceil(peak / tick) * tick;
    const y = value => bottom - value / ceiling * (bottom - top);
    if (options.timeline) {
      (data.phases || []).forEach(phase => {
        const a = Math.max(min, phase.start), b = Math.min(chart.max, phase.end);
        if (b <= a) return;
        plot.append(element('rect', {x:x(a), y:top, width:x(b)-x(a), height:bottom-top, fill:phaseColors[phase.id] || '#94a3b8', opacity:'.10'}));
        if (x(b)-x(a) > 62) plot.append(element('text', {x:(x(a)+x(b))/2, y:top-8, 'text-anchor':'middle', class:'chart-tick'}, phase.label));
      });
    }
    for (let i = 0; i <= 4; i++) {
      const value = ceiling * i / 4, yy = y(value);
      plot.append(element('line', {x1:left,x2:right,y1:yy,y2:yy,class:'chart-gridline'}));
      plot.append(element('text', {x:left-9,y:yy+5,'text-anchor':'end',class:'chart-tick'},num(value)));
      const xx = left + i / 4 * (right - left);
      const axisValue = min + i / 4 * (chart.max - min);
      if (!options.passAxis || Number.isInteger(axisValue)) {
        plot.append(element('text', {x:xx,y:bottom+23,'text-anchor':'middle',class:'chart-tick'},options.passAxis ? String(axisValue) : time(axisValue)));
      }
    }
    plot.append(element('text',{x:left,y:240,class:'chart-tick'},options.passAxis ? 'Номер прохода' : (options.timeline ? 'Время от начала записи, мин:сек' : 'Время рендеринга, мин:сек')));
    if (options.thermal) {
      const rows = (data.gpu || []).filter(p => p[0] >= min && p[0] <= chart.max);
      const segments = [];
      rows.forEach((p, i) => {
        if (p[5] !== 1) return;
        const end = Math.min(chart.max, rows[i+1] ? Math.min(p[0]+3, rows[i+1][0]) : p[0]+1);
        const previous = segments[segments.length-1];
        if (previous && p[0] <= previous[1]) previous[1] = end;
        else segments.push([p[0],end]);
      });
      segments.forEach(([a,b]) => plot.append(element('rect',{x:x(a),y:bottom-5,width:Math.max(1,x(b)-x(a)),height:5,fill:'#dc4444',opacity:'.8'})));
    }
    chart.series.forEach((series, index) => {
      const color = series.color || colors[index % colors.length];
      let path = '', previous = null;
      const points = series.points;
      points.forEach(point => {
        if (!finite(point[1])) { previous = null; return; }
        const connected = previous && point[0] - previous[0] <= (options.maxGap || 5);
        path += `${connected ? 'L' : 'M'}${x(point[0]).toFixed(2)},${y(point[1]).toFixed(2)} `;
        if (options.passAxis || points.length < 4 || !connected) plot.append(element('circle',{cx:x(point[0]),cy:y(point[1]),r:options.passAxis ? 3.5 : 2,fill:color}));
        previous = point;
      });
      plot.append(element('path',{d:path,fill:'none',stroke:color,'stroke-width':2,'stroke-dasharray':series.dashed ? '6 4' : 'none','vector-effect':'non-scaling-stroke'}));
    });
    chart.cursor = element('line',{x1:left,x2:left,y1:top,y2:bottom,class:'chart-cursor',visibility:'hidden'});
    plot.append(chart.cursor);
    chart.summary = chart.series.map(series => {
      const values = series.points.filter(p => finite(p[1])).map(p => p[1]);
      return `${series.label}: ${values.length ? `${num(Math.min(...values))}–${num(Math.max(...values))} ${options.unit}` : 'нет данных'}`;
    }).join(' · ');
    readout.textContent = chart.summary;
  }
  function sensor(parent, title, rows, index, label, unit, extra = {}) {
    return createChart(parent,{title,unit,timeline:true,series:[{label,points:(rows || []).map(p => [p[0],p[index]])}],...extra});
  }
  sensor('cpu-charts','Температура ACPI, °C',data.cpu,3,'ACPI','°C');
  sensor('cpu-charts','Частота CPU, МГц',data.cpu,1,'CPU','МГц');
  sensor('cpu-charts','Загрузка CPU, %',data.cpu,2,'CPU','%',{floorMax:100});
  sensor('gpu-charts','Температура GPU, °C',data.gpu,1,'GPU','°C',{thermal:true});
  sensor('gpu-charts','Частота GPU, МГц',data.gpu,2,'GPU','МГц',{thermal:true});
  createChart('gpu-charts',{title:'Потребление и лимит GPU, Вт',unit:'Вт',timeline:true,thermal:true,series:[
    {label:'Потребление',points:(data.gpu || []).map(p => [p[0],p[3]])},
    {label:'Лимит',points:(data.gpu || []).map(p => [p[0],p[6]]),dashed:true}
  ]});
  sensor('gpu-charts','Загрузка GPU, %',data.gpu,4,'GPU','%',{floorMax:100,thermal:true});
  const fps = createChart('performance-charts',{title:'FPS FurMark: GPU и CPU+GPU',unit:'FPS',series:data.fps || [],empty:'FPS в этом прогоне не записывался.'});
  const cb = createChart('performance-charts',{title:'Cinebench R23 по проходам',unit:'баллов',series:data.cinebench || [],passAxis:true,maxGap:1.1,empty:'Нет результатов Cinebench по проходам.'});
  [fps, cb].forEach(chart => {
    const xs = chart.options.series.flatMap(s => s.points.map(p => p[0])).filter(finite);
    render(chart,chart.options.passAxis ? 1 : 0,xs.length ? Math.max(...xs) : 1);
  });
  const select = document.getElementById('chart-phase');
  (data.phases || []).forEach((phase, index) => {
    const option = document.createElement('option');
    option.value = String(index);
    option.textContent = `${phase.label} · ${time(phase.start)}–${time(phase.end)}`;
    select.append(option);
  });
  const phaseLegend = document.getElementById('chart-phase-legend');
  const unique = [...new Map((data.phases || []).map(p => [p.label,p])).values()];
  legend(phaseLegend,[...unique.map(p => ({label:p.label,color:phaseColors[p.id] || '#94a3b8'})),{label:'Тепловое ограничение GPU',color:'#dc4444'}]);
  function renderTimeline() {
    const phase = select.value === 'all' ? null : data.phases[Number(select.value)];
    timeline.forEach(chart => render(chart,phase ? phase.start : 0,phase ? phase.end : data.duration));
  }
  select.addEventListener('change',renderTimeline);
  renderTimeline();
  const tabs = Array.from(document.querySelectorAll('[role=tab]'));
  function activate(tab) {
    tabs.forEach(t => {
      const selected = t === tab;
      t.setAttribute('aria-selected',String(selected));
      t.tabIndex = selected ? 0 : -1;
      document.getElementById(t.getAttribute('aria-controls')).hidden = !selected;
    });
  }
  tabs.forEach((tab,index) => {
    tab.addEventListener('click',() => activate(tab));
    tab.addEventListener('keydown',event => {
      if (!['ArrowLeft','ArrowRight','Home','End'].includes(event.key)) return;
      event.preventDefault();
      const next = event.key === 'Home' ? tabs[0] : event.key === 'End' ? tabs[tabs.length-1] : tabs[(index+(event.key === 'ArrowRight' ? 1 : tabs.length-1))%tabs.length];
      activate(next);
      next.focus();
    });
  });
  document.querySelector('.report-tabs').hidden = false;
})();
