/**
 * 列表页条目导出脚本（浏览器 Console 粘贴运行）
 *
 * 用途：在带 Cloudflare 验证 / 无限滚动的收藏夹、合集、列表页上，
 *      把全部条目的极简清单导出为 CSV，并顺带打印捕获到的 API 接口。
 *
 * 使用前：
 *   1. 在目标页手动通过人机验证，等列表首屏渲染完成
 *   2. F12 → Console → 粘贴本文件全部内容 → 回车
 *   3. 不要切走标签页（后台标签的定时器会被节流，滚动会停在半路）
 *
 * 适配新的站点时，只需改 CONFIG。
 */

(() => {
  const CONFIG = {
    itemSelector: 'a[href*="/p/"]',            // 指向详情页的 <a>
    idPattern: /\/p\/(\d+)/,                    // 从 href 提取唯一 id（第一个捕获组）
    detailPrefix: 'https://www.vikacg.com/p/',  // 详情页 URL 前缀
    totalPattern: /Total\s*(\d+)\s*items/i,     // 页面自报总数，留空则跳过核对
    settleMs: 1200,                             // 每次滚动后等待毫秒
    stableRounds: 8,                            // 连续多少次条目数不变判定到底
    maxRounds: 400,                             // 滚动轮数上限
  };

  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const qsa = sel => [...document.querySelectorAll(sel)];

  /* ---------- 1) 抓包：hook fetch 与 XHR ---------- */
  window.__CAP = [];
  const push = (url, json) => {
    if (url && url.includes('/api/')) window.__CAP.push({ url, json });
  };
  const _fetch = window.fetch;
  window.fetch = async function (input, init) {
    const res = await _fetch.apply(this, arguments);
    try {
      const url = typeof input === 'string' ? input : (input && input.url) || '';
      res.clone().json().then(j => push(url, j)).catch(() => {});
    } catch (e) {}
    return res;
  };
  const _open = XMLHttpRequest.prototype.open;
  const _send = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (m, u) { this.__u = u; return _open.apply(this, arguments); };
  XMLHttpRequest.prototype.send = function () {
    this.addEventListener('load', () => {
      try {
        const t = this.responseText || '';
        if (t.trim().startsWith('{') || t.trim().startsWith('[')) push(this.__u, JSON.parse(t));
      } catch (e) {}
    });
    return _send.apply(this, arguments);
  };

  (async () => {
    const count = () => new Set(qsa(CONFIG.itemSelector)
      .map(a => (a.href.match(CONFIG.idPattern) || [])[1]).filter(Boolean)).size;

    /* ---------- 2) 滚动加载 ---------- */
    let last = -1, same = 0, best = 0;
    for (let i = 0; i < CONFIG.maxRounds; i++) {
      window.scrollTo(0, document.documentElement.scrollHeight);
      qsa('button,a').forEach(b => {
        if (/^(更多|加载更多|查看更多|load more)$/i.test((b.innerText || '').trim())) b.click();
      });
      await sleep(CONFIG.settleMs);
      const n = count();
      best = Math.max(best, n);
      if (i % 5 === 0) console.log(`[滚动中] 当前条目 ${n}`);
      if (n === last) same++; else { same = 0; last = n; }
      if (same >= CONFIG.stableRounds) break;
    }
    console.log('滚动结束，唯一条目数 =', best);

    /* ---------- 3) 提取 ---------- */
    const map = new Map();
    for (const a of qsa(CONFIG.itemSelector)) {
      const m = (a.getAttribute('href') || '').match(CONFIG.idPattern);
      if (!m) continue;
      const id = m[1];
      let card = a;
      for (let i = 0; i < 7 && card.parentElement; i++) {
        if (card.querySelector('img') && (card.innerText || '').trim().length > 20) break;
        card = card.parentElement;
      }
      const h = card.querySelector('h1,h2,h3,h4');
      const o = {
        id,
        title: ((h && h.innerText) || a.innerText || '').replace(/\s+/g, ' ').trim(),
        text: (card.innerText || '').replace(/\s+/g, ' ').trim(),
        cover: (card.querySelector('img') || {}).src || '',
      };
      const prev = map.get(id);
      if (!prev || o.text.length > prev.text.length) map.set(id, o);
    }
    console.log('提取条目数 =', map.size);

    /* ---------- 4) 覆盖率核对 ---------- */
    const bodyTotal = (document.body.innerText.match(CONFIG.totalPattern) || [])[1];
    console.table({
      卡片链接总数: qsa(CONFIG.itemSelector).length,
      唯一帖子数: map.size,
      页面自报总数: bodyTotal || '未找到',
      差额: bodyTotal ? Number(bodyTotal) - map.size : '无法计算',
    });

    /* ---------- 5) 导出 CSV ---------- */
    const esc = v => '"' + String(v == null ? '' : v).replace(/"/g, '""') + '"';
    const csv = '\uFEFF' + ['id,url,title,card_text,cover']
      .concat([...map.values()].map(o =>
        [o.id, CONFIG.detailPrefix + o.id, o.title, o.text, o.cover].map(esc).join(',')))
      .join('\r\n');
    const a2 = document.createElement('a');
    a2.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' }));
    a2.download = `collection_${map.size}.csv`;
    a2.click();

    /* ---------- 6) 接口清单 ---------- */
    const seen = {};
    for (const c of window.__CAP) {
      const u = c.url.split('?')[0];
      const arr = c.json && typeof c.json === 'object'
        ? (Array.isArray(c.json) ? c.json.length
           : Math.max(0, ...Object.values(c.json).filter(Array.isArray).map(v => v.length)))
        : 0;
      seen[u] = seen[u] || { 调用次数: 0, 最大数组长度: 0 };
      seen[u].调用次数++;
      seen[u].最大数组长度 = Math.max(seen[u].最大数组长度, arr);
    }
    console.log('=== 捕获到的接口 ===');
    console.table(seen);
  })();
})();
