// Exact port of NflJerseyPainter & NbaJerseyPainter from app/lib/card/jersey_painter.dart
function renderJerseySvg(card, width = 136) {
  const isNfl = card.league === 'nfl';
  const w = 100;
  const h = isNfl ? 92 : 112;
  const c = card.colorway;
  const gradId = `fabric-${card.id}-${Math.random().toString(36).slice(2, 7)}`;
  const clipId = `clip-${card.id}-${Math.random().toString(36).slice(2, 7)}`;

  let bodyPath = '';
  let trimMarkup = '';
  let numY = isNfl ? h * 0.63 : h * 0.60;
  let numSize = isNfl ? h * 0.38 : h * 0.40;
  if (String(card.number).length > 1) numSize *= 0.92;

  if (isNfl) {
    bodyPath = [
      `M ${w * 0.36} ${h * 0.03}`,
      `L ${w * 0.50} ${h * 0.17}`,
      `L ${w * 0.64} ${h * 0.03}`,
      `L ${w * 0.84} ${h * 0.08}`,
      `Q ${w * 0.96} ${h * 0.16} ${w * 1.0} ${h * 0.40}`,
      `L ${w * 0.83} ${h * 0.46}`,
      `L ${w * 0.81} ${h}`,
      `L ${w * 0.19} ${h}`,
      `L ${w * 0.17} ${h * 0.46}`,
      `L 0 ${h * 0.40}`,
      `Q ${w * 0.04} ${h * 0.16} ${w * 0.16} ${h * 0.08}`,
      'Z'
    ].join(' ');

    const bands = [
      [0.27, c.trim],
      [0.31, c.accent],
      [0.35, c.trim]
    ];
    let stripes = '';
    for (const [y, color] of bands) {
      // Left sleeve stripe
      stripes += `<polygon points="${w * 0.02},${h * (y - 0.03)} ${w * 0.19},${h * (y + 0.01)} ${w * 0.19},${h * (y + 0.035)} ${w * 0.01},${h * (y + 0.005)}" fill="${color}"/>`;
      // Right sleeve stripe
      stripes += `<polygon points="${w * 0.98},${h * (y - 0.03)} ${w * 0.81},${h * (y + 0.01)} ${w * 0.81},${h * (y + 0.035)} ${w * 0.99},${h * (y + 0.005)}" fill="${color}"/>`;
    }

    trimMarkup = `
      ${stripes}
      <polygon points="0,${h * 0.40} ${w * 0.17},${h * 0.46} ${w * 0.17},${h * 0.43} ${w * 0.005},${h * 0.37}" fill="${c.trim}"/>
      <polygon points="${w},${h * 0.40} ${w * 0.83},${h * 0.46} ${w * 0.83},${h * 0.43} ${w * 0.995},${h * 0.37}" fill="${c.trim}"/>
      <path d="M ${w * 0.34} ${h * 0.02} L ${w * 0.50} ${h * 0.19} L ${w * 0.66} ${h * 0.02}" fill="none" stroke="${c.trim}" stroke-width="${w * 0.045}" stroke-linejoin="miter"/>
    `;
  } else {
    bodyPath = [
      `M ${w * 0.27} 0`,
      `Q ${w * 0.30} ${h * 0.20} ${w * 0.50} ${h * 0.21}`,
      `Q ${w * 0.70} ${h * 0.20} ${w * 0.73} 0`,
      `L ${w * 0.86} 0`,
      `Q ${w * 0.84} ${h * 0.26} ${w * 0.98} ${h * 0.36}`,
      `L ${w * 0.96} ${h}`,
      `L ${w * 0.04} ${h}`,
      `L ${w * 0.02} ${h * 0.36}`,
      `Q ${w * 0.16} ${h * 0.26} ${w * 0.14} 0`,
      'Z'
    ].join(' ');

    const neck = `M ${w * 0.27} 0 Q ${w * 0.30} ${h * 0.20} ${w * 0.50} ${h * 0.21} Q ${w * 0.70} ${h * 0.20} ${w * 0.73} 0`;
    const leftArm = `M ${w * 0.14} 0 Q ${w * 0.16} ${h * 0.26} ${w * 0.02} ${h * 0.36}`;
    const rightArm = `M ${w * 0.86} 0 Q ${w * 0.84} ${h * 0.26} ${w * 0.98} ${h * 0.36}`;

    trimMarkup = `
      <rect x="${w * 0.04}" y="${h * 0.40}" width="${w * 0.025}" height="${h * 0.60}" fill="${c.trim}" opacity="0.9"/>
      <rect x="${w * 0.935}" y="${h * 0.40}" width="${w * 0.025}" height="${h * 0.60}" fill="${c.trim}" opacity="0.9"/>
      <path d="${neck}" fill="none" stroke="${c.trim}" stroke-width="${w * 0.06}"/>
      <path d="${leftArm}" fill="none" stroke="${c.trim}" stroke-width="${w * 0.06}"/>
      <path d="${rightArm}" fill="none" stroke="${c.trim}" stroke-width="${w * 0.06}"/>
      <path d="${neck}" transform="translate(0, 3.2)" fill="none" stroke="${c.accent}" stroke-width="${w * 0.02}"/>
    `;
  }

  return `
    <svg viewBox="0 0 ${w} ${h}" width="${width}" height="${Math.round(width * (h / w))}" aria-label="${card.team} jersey #${card.number}">
      <defs>
        <clipPath id="${clipId}">
          <path d="${bodyPath}"/>
        </clipPath>
        <linearGradient id="${gradId}" x1="0%" y1="0%" x2="100%" y2="100%">
          <stop offset="0%" stop-color="#FFFFFF" stop-opacity="0.11"/>
          <stop offset="50%" stop-color="#FFFFFF" stop-opacity="0"/>
          <stop offset="100%" stop-color="#000000" stop-opacity="0.22"/>
        </linearGradient>
      </defs>
      <path d="${bodyPath}" fill="${c.base}"/>
      <g clip-path="url(#${clipId})">
        ${trimMarkup}
        <rect x="0" y="0" width="${w}" height="${h}" fill="url(#${gradId})"/>
      </g>
      <text x="${w * 0.5}" y="${numY}" text-anchor="middle" dominant-baseline="central"
        font-family="'Barlow Condensed', sans-serif" font-weight="800" font-size="${numSize}"
        fill="${c.numberFill}" stroke="${c.numberOutline}" stroke-width="2.2" paint-order="stroke fill">
        ${card.number}
      </text>
    </svg>
  `;
}

// Render diagonal hero stripes matching _HeroBackdrop in sport_card.dart
function renderHeroStripesSvg(c) {
  return `
    <svg class="sc-stripes" viewBox="0 0 340 156" preserveAspectRatio="none">
      <polygon points="304,0 358,0 241,156 187,156" fill="${c.base}"/>
      <polygon points="358,0 382,0 265,156 241,156" fill="${c.accent}" fill-opacity="0.85"/>
      <polygon points="382,0 399,0 282,156 265,156" fill="${c.base}" fill-opacity="0.75"/>
    </svg>
  `;
}

// Synthesized subtle card swipe swoosh matching app/assets/audio/swoosh.wav
let audioCtx = null;
function playSwooshSound() {
  try {
    const AudioContextClass = window.AudioContext || window.webkitAudioContext;
    if (!AudioContextClass) return;
    if (!audioCtx) audioCtx = new AudioContextClass();
    if (audioCtx.state === 'suspended') audioCtx.resume();

    const duration = 0.13;
    const bufferSize = Math.floor(audioCtx.sampleRate * duration);
    const buffer = audioCtx.createBuffer(1, bufferSize, audioCtx.sampleRate);
    const data = buffer.getChannelData(0);
    for (let i = 0; i < bufferSize; i++) {
      const t = i / bufferSize;
      const env = Math.sin(Math.PI * Math.pow(t, 0.72));
      data[i] = (Math.random() * 2 - 1) * env * 0.24;
    }

    const noise = audioCtx.createBufferSource();
    noise.buffer = buffer;

    const filter = audioCtx.createBiquadFilter();
    filter.type = 'bandpass';
    filter.Q.value = 1.6;
    filter.frequency.setValueAtTime(360, audioCtx.currentTime);
    filter.frequency.exponentialRampToValueAtTime(1450, audioCtx.currentTime + duration * 0.55);
    filter.frequency.exponentialRampToValueAtTime(520, audioCtx.currentTime + duration);

    const gain = audioCtx.createGain();
    gain.gain.setValueAtTime(0.18, audioCtx.currentTime);
    gain.gain.exponentialRampToValueAtTime(0.01, audioCtx.currentTime + duration);

    noise.connect(filter);
    filter.connect(gain);
    gain.connect(audioCtx.destination);
    noise.start();
  } catch (_) {}
}

// Deck catalog matching real NFL & NBA colorways from colorway.rs
const DECK_CARDS = [
  {
    id: 'allen-17',
    firstName: 'Josh',
    lastName: 'Allen',
    fullName: 'Josh Allen',
    team: 'BUF',
    league: 'nfl',
    leagueLabel: 'NFL',
    position: 'QB',
    number: '17',
    series: 'BASE SERIES',
    matchup: 'BUF at KC · Sun 4:25 PM',
    line: 264.5,
    statShort: 'PASSING YARDS',
    statLabel: 'Passing Yards',
    lockText: 'Locks Sun 4:25 PM',
    recent: [241, 280, 312, 255, 289],
    finish: 'gold',
    footerLeft: 'GOLD',
    footerRight: '218/400 · Earn Diamond',
    colorway: {
      base: '#00338D',
      trim: '#C60C30',
      accent: '#DA6178',
      numberFill: '#FFFFFF',
      numberOutline: '#C60C30'
    }
  },
  {
    id: 'tatum-0',
    firstName: 'Jayson',
    lastName: 'Tatum',
    fullName: 'Jayson Tatum',
    team: 'BOS',
    league: 'nba',
    leagueLabel: 'NBA',
    position: 'SF',
    number: '0',
    series: 'BASE SERIES',
    matchup: 'NYK at BOS · Tonight 7:30 PM',
    line: 29.5,
    statShort: 'POINTS',
    statLabel: 'Points',
    lockText: 'Locks Tonight 7:30 PM',
    recent: [27, 34, 31, 26, 33],
    finish: 'silver',
    footerLeft: 'SILVER',
    footerRight: '112/200 · Earn Gold',
    colorway: {
      base: '#007A33',
      trim: '#BA9653',
      accent: '#D2BB8F',
      numberFill: '#FFFFFF',
      numberOutline: '#BA9653'
    }
  },
  {
    id: 'jefferson-18',
    firstName: 'Justin',
    lastName: 'Jefferson',
    fullName: 'Justin Jefferson',
    team: 'MIN',
    league: 'nfl',
    leagueLabel: 'NFL',
    position: 'WR',
    number: '18',
    series: 'BASE SERIES',
    matchup: 'MIN at DET · Sun 1:00 PM',
    line: 92.5,
    statShort: 'RECEIVING YARDS',
    statLabel: 'Receiving Yards',
    lockText: 'Locks Sun 1:00 PM',
    recent: [84, 115, 98, 132, 106],
    finish: 'diamond',
    footerLeft: 'DIAMOND',
    footerRight: '400/400 · Unlocked',
    colorway: {
      base: '#4F2683',
      trim: '#FFC62F',
      accent: '#FFDA78',
      numberFill: '#FFFFFF',
      numberOutline: '#FFC62F'
    }
  },
  {
    id: 'curry-30',
    firstName: 'Stephen',
    lastName: 'Curry',
    fullName: 'Stephen Curry',
    team: 'GSW',
    league: 'nba',
    leagueLabel: 'NBA',
    position: 'PG',
    number: '30',
    series: 'BASE SERIES',
    matchup: 'LAL at GSW · Tonight 10:00 PM',
    line: 4.5,
    statShort: '3-PT MADE',
    statLabel: '3-Pointers Made',
    lockText: 'Locks Tonight 10:00 PM',
    recent: [4, 6, 5, 3, 7],
    finish: 'bronze',
    footerLeft: 'BRONZE',
    footerRight: '46/80 · Earn Silver',
    colorway: {
      base: '#1D428A',
      trim: '#FFC72C',
      accent: '#FFDB76',
      numberFill: '#FFFFFF',
      numberOutline: '#FFC72C'
    }
  },
  {
    id: 'jackson-8',
    firstName: 'Lamar',
    lastName: 'Jackson',
    fullName: 'Lamar Jackson',
    team: 'BAL',
    league: 'nfl',
    leagueLabel: 'NFL',
    position: 'QB',
    number: '8',
    series: 'BASE SERIES',
    matchup: 'CIN at BAL · Thu 8:15 PM',
    line: 54.5,
    statShort: 'RUSHING YARDS',
    statLabel: 'Rushing Yards',
    lockText: 'Locks Thu 8:15 PM',
    recent: [48, 64, 59, 78, 52],
    finish: 'base',
    footerLeft: 'BASE',
    footerRight: '9/20 · Earn Bronze',
    colorway: {
      base: '#241773',
      trim: '#9E7C0C',
      accent: '#C0AA61',
      numberFill: '#FFFFFF',
      numberOutline: '#9E7C0C'
    }
  }
];

function buildSportCardHtml(card, customFinish = null, customFooterLeft = null, customFooterRight = null) {
  const finish = customFinish || card.finish;
  const fLeft = customFooterLeft || card.footerLeft;
  const fRight = customFooterRight || card.footerRight;

  return `
    <div class="sport-card" data-finish="${finish}">
      <div class="swipe-stamp over">OVER ${card.line}</div>
      <div class="swipe-stamp under">UNDER ${card.line}</div>
      <div class="sport-card-face">
        <div class="sc-topbar">
          <span class="sc-team-skew" style="background:${card.colorway.base}"></span>
          <span>${card.team} / ${card.leagueLabel}</span>
          <span class="sc-topbar-right">${card.position}</span>
        </div>
        <div class="sc-hero">
          ${renderHeroStripesSvg(card.colorway)}
          <div class="sc-ghost-num">${card.number}</div>
          <div class="sc-chrome-tag">CHROME SPORT</div>
          <div class="sc-jersey-wrap">
            ${renderJerseySvg(card, card.league === 'nfl' ? 142 : 122)}
          </div>
          <svg class="sc-diamond-facets" viewBox="0 0 340 156" preserveAspectRatio="none">
            <polygon points="0,156 143,0 228,0 68,156" fill="#B1E7FF" fill-opacity="0.26"/>
            <polygon points="238,0 340,31 187,156 129,156" fill="#E6BCFF" fill-opacity="0.24"/>
            <line x1="143" y1="0" x2="0" y2="156" stroke="#FFFFFF" stroke-opacity="0.55" stroke-width="1"/>
          </svg>
        </div>
        <div class="sc-color-rule" style="background:${card.colorway.base}"></div>
        <div class="sc-name-block">
          <div class="sc-name-left">
            <div class="sc-first-name">${card.firstName}</div>
            <div class="sc-last-name">${card.lastName}</div>
          </div>
          <div class="sc-name-divider"></div>
          <div class="sc-no-col">
            <span class="sc-no-label">NO.</span>
            <span class="sc-no-val">${card.number}</span>
            <span class="sc-series">${card.series}</span>
          </div>
        </div>
        <div class="sc-matchup">${card.matchup}</div>
        <div class="sc-divider"></div>
        <div class="sc-line-row">
          <div class="sc-line-num">${card.line}</div>
          <div class="sc-line-sep"></div>
          <div>
            <div class="sc-stat-title">${card.statShort}</div>
            <div class="sc-lock-meta">${card.lockText}</div>
          </div>
        </div>
        <div class="sc-recent-form">
          <span>Last 5</span>
          <div class="sc-form-vals">
            ${card.recent.map(v => `<span>${v}</span>`).join('')}
          </div>
        </div>
        <div class="sc-footer">
          <span class="sc-team-skew" style="background:${card.colorway.base};width:8px;height:10px"></span>
          <span class="sc-footer-tier">${fLeft}</span>
          <span class="sc-footer-right">${fRight}</span>
          <span class="sc-share-icon" title="Head-to-Head challenge">↗</span>
        </div>
      </div>
    </div>
  `;
}

document.addEventListener('DOMContentLoaded', () => {
  // 1. HERO INTERACTIVE DECK
  let currentSport = 'all';
  let deckIndex = 0;
  let wager = 50;
  let balance = 1250;

  const deckContainer = document.getElementById('hero-card-mount');
  const wagerValueEl = document.getElementById('deck-wager-val');
  const balanceValueEl = document.getElementById('header-coin-balance');
  const frameBalanceEl = document.getElementById('frame-coin-balance');
  const receiptEl = document.getElementById('swipe-receipt');

  function filteredDeck() {
    return currentSport === 'all'
      ? DECK_CARDS
      : DECK_CARDS.filter(c => c.league === currentSport);
  }

  function renderCurrentDeckCard() {
    const list = filteredDeck();
    const card = list[deckIndex % list.length];
    deckContainer.innerHTML = buildSportCardHtml(card);
    attachDragSwipe(deckContainer.querySelector('.sport-card'), card);
  }

  function updateBalances() {
    wagerValueEl.textContent = wager;
    if (balanceValueEl) balanceValueEl.textContent = balance.toLocaleString();
    if (frameBalanceEl) frameBalanceEl.textContent = balance.toLocaleString();
  }

  function triggerSwipe(direction) {
    const cardEl = deckContainer.querySelector('.sport-card');
    if (!cardEl) return;
    const list = filteredDeck();
    const card = list[deckIndex % list.length];

    playSwooshSound();

    if (direction === 'over' || direction === 'under') {
      const stamp = cardEl.querySelector(`.swipe-stamp.${direction}`);
      if (stamp) stamp.style.opacity = '1';
      const dx = direction === 'over' ? 190 : -190;
      const rot = direction === 'over' ? 9 : -9;
      cardEl.style.transform = `translate3d(${dx}px, -8px, 0) rotate(${rot}deg)`;
      cardEl.style.opacity = '0';

      const singleRet = 2 * wager + 25;
      const sideText = direction === 'over' ? 'Over' : 'Under';
      receiptEl.textContent = `Locked ${card.lastName} ${sideText} ${card.line} · ${wager} coins → ${singleRet} return`;
    } else {
      cardEl.style.transform = 'translate3d(0, 120px, 0) scale(0.94)';
      cardEl.style.opacity = '0';
      receiptEl.textContent = `Sent ${card.fullName} to back of deck`;
    }

    setTimeout(() => {
      deckIndex = (deckIndex + 1) % list.length;
      renderCurrentDeckCard();
    }, 220);
  }

  function attachDragSwipe(cardEl, card) {
    if (!cardEl) return;
    let startX = 0;
    let startY = 0;
    let dragging = false;

    const onDown = (x, y) => {
      startX = x;
      startY = y;
      dragging = true;
      cardEl.style.transition = 'none';
    };

    const onMove = (x, y) => {
      if (!dragging) return;
      const dx = x - startX;
      const dy = y - startY;
      cardEl.style.transform = `translate3d(${dx}px, ${dy * 0.35}px, 0) rotate(${dx * 0.045}deg)`;
      const overStamp = cardEl.querySelector('.swipe-stamp.over');
      const underStamp = cardEl.querySelector('.swipe-stamp.under');
      if (overStamp) overStamp.style.opacity = dx > 35 ? Math.min(1, (dx - 35) / 70) : 0;
      if (underStamp) underStamp.style.opacity = dx < -35 ? Math.min(1, (-dx - 35) / 70) : 0;
    };

    const onUp = (x, y) => {
      if (!dragging) return;
      dragging = false;
      cardEl.style.transition = 'transform 0.26s cubic-bezier(0.22, 1, 0.36, 1), opacity 0.26s ease';
      const dx = x - startX;
      const dy = y - startY;
      if (dx > 75) {
        triggerSwipe('over');
      } else if (dx < -75) {
        triggerSwipe('under');
      } else if (dy > 75) {
        triggerSwipe('skip');
      } else {
        cardEl.style.transform = 'translate3d(0,0,0) rotate(0deg)';
        const overStamp = cardEl.querySelector('.swipe-stamp.over');
        const underStamp = cardEl.querySelector('.swipe-stamp.under');
        if (overStamp) overStamp.style.opacity = '0';
        if (underStamp) underStamp.style.opacity = '0';
      }
    };

    cardEl.addEventListener('mousedown', e => onDown(e.clientX, e.clientY));
    window.addEventListener('mousemove', e => onMove(e.clientX, e.clientY));
    window.addEventListener('mouseup', e => onUp(e.clientX, e.clientY));

    cardEl.addEventListener('touchstart', e => {
      const t = e.touches[0];
      onDown(t.clientX, t.clientY);
    }, { passive: true });
    cardEl.addEventListener('touchmove', e => {
      const t = e.touches[0];
      onMove(t.clientX, t.clientY);
    }, { passive: true });
    cardEl.addEventListener('touchend', e => {
      const t = e.changedTouches[0];
      onUp(t.clientX, t.clientY);
    });
  }

  document.getElementById('btn-swipe-under')?.addEventListener('click', () => triggerSwipe('under'));
  document.getElementById('btn-swipe-skip')?.addEventListener('click', () => triggerSwipe('skip'));
  document.getElementById('btn-swipe-over')?.addEventListener('click', () => triggerSwipe('over'));

  document.getElementById('wager-minus')?.addEventListener('click', () => {
    wager = Math.max(0, wager - 25);
    updateBalances();
  });
  document.getElementById('wager-plus')?.addEventListener('click', () => {
    wager = Math.min(500, wager + 25);
    updateBalances();
  });

  document.querySelectorAll('[data-sport-filter]').forEach(btn => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('[data-sport-filter]').forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      currentSport = btn.getAttribute('data-sport-filter');
      deckIndex = 0;
      renderCurrentDeckCard();
    });
  });

  renderCurrentDeckCard();
  updateBalances();

  // 2. INTERACTIVE PARLAY BUILDER (exact payout.dart rules: 2->3x, 3->5x, 4->8x, 5->12x + 25/leg)
  const parlayLegsState = [
    { card: DECK_CARDS[0], side: 'over', active: true },
    { card: DECK_CARDS[1], side: 'over', active: true },
    { card: DECK_CARDS[2], side: 'under', active: true },
    { card: DECK_CARDS[3], side: 'over', active: true },
    { card: DECK_CARDS[4], side: 'under', active: false }
  ];
  let parlayStake = 100;

  function parlayMultiplier(legs) {
    if (legs === 2) return 3;
    if (legs === 3) return 5;
    if (legs === 4) return 8;
    if (legs === 5) return 12;
    return 0;
  }

  function renderParlayBuilder() {
    const activeCount = parlayLegsState.filter(l => l.active).length;
    const mult = parlayMultiplier(activeCount);
    const totalReturn = mult * parlayStake + 25 * activeCount;

    document.getElementById('parlay-title-count').textContent = `Review ${activeCount}-pick parlay`;
    document.getElementById('parlay-mult-display').textContent = `${mult}×`;
    document.getElementById('parlay-stake-val').textContent = parlayStake;
    document.getElementById('parlay-return-val').textContent = `${totalReturn.toLocaleString()} coins`;

    document.querySelectorAll('[data-mult-legs]').forEach(step => {
      const n = Number(step.getAttribute('data-mult-legs'));
      step.classList.toggle('active', n === activeCount);
    });

    const listEl = document.getElementById('parlay-legs-mount');
    listEl.innerHTML = parlayLegsState.map((item, idx) => {
      const sideLabel = item.side === 'over' ? 'Over' : 'Under';
      const sideClass = item.side === 'over' ? 'side-over' : 'side-under';
      return `
        <div class="parlay-leg-row ${item.active ? '' : 'inactive'}">
          <div class="mini-jersey">${renderJerseySvg(item.card, 34)}</div>
          <div class="leg-info">
            <div class="leg-player">${item.card.fullName}</div>
            <div class="leg-line">
              <span class="${sideClass}">${sideLabel} ${item.card.line}</span>
              <span> · ${item.card.statLabel}</span>
            </div>
          </div>
          <div class="leg-actions">
            <button type="button" class="leg-toggle-btn" data-flip-leg="${idx}">Flip O/U</button>
            <button type="button" class="leg-toggle-btn" data-toggle-leg="${idx}">${item.active ? 'In slip' : '+ Add'}</button>
          </div>
        </div>
      `;
    }).join('');

    listEl.querySelectorAll('[data-flip-leg]').forEach(btn => {
      btn.addEventListener('click', () => {
        const idx = Number(btn.getAttribute('data-flip-leg'));
        parlayLegsState[idx].side = parlayLegsState[idx].side === 'over' ? 'under' : 'over';
        renderParlayBuilder();
      });
    });

    listEl.querySelectorAll('[data-toggle-leg]').forEach(btn => {
      btn.addEventListener('click', () => {
        const idx = Number(btn.getAttribute('data-toggle-leg'));
        const activeCountNow = parlayLegsState.filter(l => l.active).length;
        if (parlayLegsState[idx].active && activeCountNow <= 2) return; // keep at least 2 legs for a parlay
        parlayLegsState[idx].active = !parlayLegsState[idx].active;
        renderParlayBuilder();
      });
    });
  }

  document.querySelectorAll('[data-mult-legs]').forEach(step => {
    step.addEventListener('click', () => {
      const target = Number(step.getAttribute('data-mult-legs'));
      parlayLegsState.forEach((l, i) => { l.active = i < target; });
      renderParlayBuilder();
    });
  });

  document.getElementById('parlay-stake-minus')?.addEventListener('click', () => {
    parlayStake = Math.max(25, parlayStake - 25);
    renderParlayBuilder();
  });
  document.getElementById('parlay-stake-plus')?.addEventListener('click', () => {
    parlayStake = Math.min(500, parlayStake + 25);
    renderParlayBuilder();
  });

  renderParlayBuilder();

  // 3. CARD TIERS MASTERY INSPECTOR
  const tierSpec = {
    base: { left: 'BASE', right: '1/20 · Earn Bronze', calls: '1 correct call', desc: 'Unlocks your player card in Collection after your very first graded free call.' },
    bronze: { left: 'BRONZE', right: '20/80 · Earn Silver', calls: '20 correct calls', desc: 'Warm copper-bronze frame unlocked at 20 graded single calls.' },
    silver: { left: 'SILVER', right: '80/200 · Earn Gold', calls: '80 correct calls', desc: 'Brushed chrome-silver frame unlocked at 80 graded single calls.' },
    gold: { left: 'GOLD', right: '200/400 · Earn Diamond', calls: '200 correct calls', desc: 'Championship gold frame and warm cream face unlocked at 200 calls.' },
    diamond: { left: 'DIAMOND', right: '400/400 · Unlocked', calls: '400 correct calls', desc: 'Prismatic faceted finish. Qualifies for a numbered on-chain Solana Diamond edition.' }
  };

  const tierCardMount = document.getElementById('tier-inspector-mount');
  const tierCaptionEl = document.getElementById('tier-inspector-caption');

  function renderTierCard(tierKey) {
    const info = tierSpec[tierKey] || tierSpec.diamond;
    tierCardMount.innerHTML = buildSportCardHtml(DECK_CARDS[0], tierKey, info.left, info.right);
    if (tierCaptionEl) {
      tierCaptionEl.textContent = `${info.left} (${info.calls}) — ${info.desc}`;
    }
  }

  document.querySelectorAll('[data-tier-select]').forEach(btn => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('[data-tier-select]').forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      renderTierCard(btn.getAttribute('data-tier-select'));
    });
  });

  renderTierCard('diamond');

  // 4. BLOCKCHAIN DIAMOND SALE SIMULATOR
  const diamondMount = document.getElementById('blockchain-card-mount');
  if (diamondMount) {
    const rileyCard = {
      id: 'swift-7',
      firstName: 'Riley',
      lastName: 'Swift',
      fullName: 'Riley Swift',
      team: 'BUF',
      league: 'nfl',
      leagueLabel: 'NFL',
      position: 'DEMO',
      number: '7',
      series: 'DIAMOND #7',
      matchup: 'Season 2026 · 400/400 Free Calls',
      line: 284.5,
      statShort: 'PASSING YARDS',
      statLabel: 'Passing Yards',
      lockText: 'Solana Devnet Asset',
      recent: [275, 290, 304, 268, 318],
      finish: 'diamond',
      footerLeft: 'DIAMOND',
      footerRight: '400/400 · Unlocked',
      colorway: {
        base: '#00338D',
        trim: '#C60C30',
        accent: '#DA6178',
        numberFill: '#FFFFFF',
        numberOutline: '#C60C30'
      }
    };
    diamondMount.innerHTML = buildSportCardHtml(rileyCard);
  }

  const saleBtn = document.getElementById('btn-simulate-sale');
  const resetBtn = document.getElementById('btn-reset-sale');
  const saleTitleEl = document.getElementById('sale-heading');
  const salePhaseEl = document.getElementById('sale-phase');
  const saleOwnerEl = document.getElementById('sale-owner');
  const saleStatusEl = document.getElementById('sale-status');

  saleBtn?.addEventListener('click', () => {
    saleBtn.disabled = true;
    saleBtn.textContent = 'Submitting atomic swap on Solana…';
    setTimeout(() => {
      if (saleTitleEl) saleTitleEl.textContent = 'Sale complete.';
      if (salePhaseEl) salePhaseEl.textContent = 'Confirmed on Solana devnet. Ownership transferred. Your mastery remains 400/400.';
      if (saleOwnerEl) saleOwnerEl.textContent = 'Current owner: Demo Collector Wallet (8x9F…3kPq)';
      if (saleStatusEl) saleStatusEl.textContent = 'Sale status: confirmed · 0.1 devnet SOL';
      saleBtn.style.display = 'none';
      if (resetBtn) resetBtn.style.display = 'inline-flex';
    }, 650);
  });

  resetBtn?.addEventListener('click', () => {
    if (saleTitleEl) saleTitleEl.textContent = 'Sell your Diamond.';
    if (salePhaseEl) salePhaseEl.textContent = 'Ready for atomic settlement: 0.1 SOL payment and card transfer submit together.';
    if (saleOwnerEl) saleOwnerEl.textContent = 'Current owner: You (Original Earner · 400/400)';
    if (saleStatusEl) saleStatusEl.textContent = 'Sale status: listed · 0.1 devnet SOL';
    if (saleBtn) {
      saleBtn.disabled = false;
      saleBtn.style.display = 'inline-flex';
      saleBtn.textContent = 'Simulate atomic sale · 0.1 SOL';
    }
    resetBtn.style.display = 'none';
  });
});
