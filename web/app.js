const ENDPOINT = '/api/servers';

function fmtBytes(n){
  if (n === null || n === undefined) return '—';
  const u = ['B','K','M','G','T','P']; let i = 0, v = n;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return (v >= 100 ? v.toFixed(0) : v.toFixed(1)).replace(/\.0$/, '') + u[i];
}
function pct(used, total){ return total > 0 ? Math.min(100, Math.round(used / total * 100)) : 0; }

function esc(s){
  return String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

function num(v, d=0){
  const n = Number(v);
  return Number.isFinite(n) ? n : d;
}

function shortCpu(name){
  if (!name) return '—';
  return String(name)
    .replace(/^(Intel|AMD)\(R\)\s*/i, '')
    .replace(/\s*(CPU|Processor)\s*@.*$/i, '')
    .replace(/\(R\)|\(TM\)/gi, '')
    .replace(/\s+/g, ' ')
    .trim();
}

function bar(value, tip){
  value = Math.max(0, Math.min(100, num(value)));
  const cls = value >= 85 ? 'high' : value >= 60 ? 'mid' : 'low';
  const t = tip ? ` title="${esc(tip)}"` : '';
  return `<span class="bar ${cls}"${t}><span class="track"><i class="fill" style="width:${value}%"></i></span>` +
         `<span class="num">${value}%</span></span>`;
}
function daysLeft(dateStr){
  const d = new Date(dateStr + 'T00:00:00');
  if (isNaN(d)) return null;
  return Math.ceil((d - new Date()) / 86400000);
}

function render(data){
  const servers = Array.isArray(data) ? data : (data.servers || []);
  const tbody = document.querySelector('#tbl tbody');
  if (!servers.length){
    tbody.innerHTML = '<tr class="empty"><td colspan="10">还没有节点上报。' +
      '装一台探针（<code>bash status.sh c</code>）就会出现在这里——' +
      '添加账号只是发通行证，不代表已经有机器。</td></tr>';
    document.querySelector('#chips').innerHTML = '<span class="chip">节点 0</span>';
    return;
  }
  tbody.innerHTML = servers.map(s => {
    const hasFlags = ('online4' in s) || ('online6' in s);
    const reachable = hasFlags ? !!(s.online4 || s.online6) : true;
    const age = num(s.age, 0);
    const fresh = !s.stale;
    const state = fresh ? 'on' : 'off';
    const stateText = fresh ? '运行中' : '失联中';
    const dl = daysLeft(s.type);
    const ram = pct(s.memory_used, s.memory_total);
    const rom = pct(s.hdd_used, s.hdd_total);
    return `<tr>
      <td class="c-status" data-k="状态"><span class="state ${state}" title="最后上报 ${age} 秒前"><i class="dot"></i>${stateText}</span></td>
      <td class="c-name" data-k="节点"><div class="name">${esc(s.name)}</div><div class="loc">${esc(s.location||'')}</div></td>
      <td class="c-date" data-k="到期"><span class="date ${dl !== null && dl <= 30 ? 'warn':''}">${s.type||'—'}</span><span class="loc">${dl === null ? '' : dl < 0 ? '已过期' : '剩 ' + dl + ' 天'}</span></td>
      <td class="c-uptime" data-k="在线"><span class="mono">${s.uptime||'—'}</span></td>
      <td class="c-load" data-k="负载"><span class="mono">${num(s.load).toFixed(2)}</span></td>
      <td class="c-net" data-k="网络"><span class="mono">↓ ${fmtBytes(num(s.network_rx))}/s &nbsp; ↑ ${fmtBytes(num(s.network_tx))}/s</span></td>
      <td class="c-traffic" data-k="流量"><span class="mono">↓ ${fmtBytes(num(s.network_in))} &nbsp; ↑ ${fmtBytes(num(s.network_out))}</span></td>
      <td class="c-bar" data-k="CPU">${bar(s.cpu, num(s.cpu_cores) ? num(s.cpu_cores) + ' 核 · ' + (s.cpu_model || '未知型号') : (s.cpu_model || ''))}</td>
      <td class="c-bar" data-k="RAM">${bar(ram, `内存 已用 ${fmtBytes(num(s.memory_used))}，共 ${fmtBytes(num(s.memory_total))}　SWAP 已用 ${fmtBytes(num(s.swap_used))}/共 ${fmtBytes(num(s.swap_total))}`)}</td>
      <td class="c-bar" data-k="硬盘">${bar(rom, `已用 ${fmtBytes(num(s.hdd_used)*1024*1024)}，共 ${fmtBytes(num(s.hdd_total)*1024*1024)}`)}</td>
    </tr>`;
  }).join('');

  const total = servers.length;
  const live = servers.filter(s => !s.stale).length;
  document.querySelector('#chips').innerHTML =
    `<span class="chip">节点 <b>${total}</b></span>` +
    `<span class="chip on">在线 <b>${live}</b></span>` +
    `<span class="chip off">失联 <b>${total - live}</b></span>`;
}

async function load(){
  try{
    const r = await fetch(ENDPOINT + '?t=' + Date.now(), {cache:'no-store'});
    if(!r.ok) throw new Error('HTTP ' + r.status);
    const data = await r.json();
    render(data);
    document.querySelector('#updated').textContent = '最后更新 ' + new Date().toLocaleTimeString('zh-CN');
  }catch(e){
    document.querySelector('#updated').textContent = '读取失败：' + e.message;
  }
}

document.querySelector('#refresh').onclick = load;
load();
setInterval(load, 5000);
