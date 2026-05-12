/* ──────────────────────────────────────────────────────────────────────────
 * DCS Team Chat Widget
 * --------------------
 * Single shared chat for everyone signed into the portal. Old-school
 * chat-room style: one channel, one flat stream of messages, colored
 * usernames, join/leave notices, online list, unread badge, sound ping,
 * tab title flash.
 *
 * Each portal HTML page just needs:
 *   <script src="https://unpkg.com/@supabase/supabase-js@2"></script>  (already there)
 *   <script src="chat-widget.js"></script>
 *
 * The widget self-injects HTML/CSS into the page on DOMContentLoaded,
 * authenticates via the same shared localStorage session that all four
 * portal pages use, and connects to Supabase Realtime for live messages
 * + presence.
 *
 * Reads display_name / display_color / photo_url from the staff_directory
 * (list_staff() RPC) so messages are tagged with friendly names + colors.
 *
 * Position: bottom-LEFT (the AI Assistant is bottom-right).
 * ────────────────────────────────────────────────────────────────────────── */

(function() {
  "use strict";

  // ── Avoid double-injection if a page accidentally includes the script twice
  if (window.__dcsChatWidgetLoaded) return;
  window.__dcsChatWidgetLoaded = true;

  // ── Config (mirrors other portal pages)
  const SUPABASE_URL = "https://jpemlcuxjvynlbeygukb.supabase.co";
  const SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImpwZW1sY3V4anZ5bmxiZXlndWtiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQ0MDI5OTcsImV4cCI6MjA4OTk3ODk5N30.hNSDcxas0F3gZxNOf8ScHJBcjfV_nHzD0859bTBHkTI";

  // Color palette must match kanban so a user has the same color portal-wide
  const PRESET_COLORS = [
    { hex: "#2463eb", name: "blue"   },
    { hex: "#7c3aed", name: "purple" },
    { hex: "#ef4444", name: "red"    },
    { hex: "#f97316", name: "orange" },
    { hex: "#eab308", name: "yellow" },
    { hex: "#22c55e", name: "green"  },
    { hex: "#92400e", name: "brown"  },
    { hex: "#1e293b", name: "slate"  }
  ];

  // ── State
  let db = null;
  let currentUser = null;
  let staffById = {};                 // {user_id: {email, display_name, display_color, photo_url}}
  let messages = [];                  // local cache
  let onlineUsers = {};               // {user_id: {email, name, ...}}
  let unreadCount = 0;
  let isOpen = false;
  let isInjected = false;
  let realtimeChannel = null;
  let presenceChannel = null;
  let originalTitle = document.title;
  let oldestLoaded = null;            // ISO timestamp of oldest message in cache (for paging)
  let audioCtx = null;                // lazy-init on first user interaction

  // ── Boot when page is ready and Supabase JS is loaded
  function boot() {
    if (typeof supabase === "undefined" || !supabase.createClient) {
      // Wait for the supabase-js script tag to load
      setTimeout(boot, 100);
      return;
    }
    db = supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
      auth: { storage: window.localStorage, persistSession: true, autoRefreshToken: true }
    });
    init();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }

  async function init() {
    // Get session — if not authenticated, don't render the widget
    const { data: sess } = await db.auth.getSession();
    if (!sess || !sess.session || !sess.session.user) {
      // Watch for sign-in via auth state change in case the user isn't authed yet
      db.auth.onAuthStateChange(function(event, session) {
        if (session && session.user && !currentUser) init();
      });
      return;
    }
    currentUser = sess.session.user;

    await loadStaff();
    injectUI();
    await loadInitialMessages();
    setupRealtime();
    setupPresence();
    setupTabVisibility();
  }

  // ── Helpers ────────────────────────────────────────────────────────────
  function escHtml(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function(c) {
      return ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" })[c];
    });
  }
  function shortEmail(email) {
    if (!email) return "";
    const at = email.indexOf("@");
    return at > 0 ? email.substring(0, at) : email;
  }
  function fallbackColorFor(userId) {
    if (!userId) return "#6b7280";
    let hash = 0;
    for (let i = 0; i < userId.length; i++) hash = (hash * 31 + userId.charCodeAt(i)) | 0;
    return PRESET_COLORS[Math.abs(hash) % PRESET_COLORS.length].hex;
  }
  function nameFor(userId) {
    if (!userId) return "anonymous";
    const s = staffById[userId];
    if (!s) return "user";
    if (s.display_name && s.display_name.trim()) return s.display_name.trim();
    return shortEmail(s.email);
  }
  function colorFor(userId) {
    const s = staffById[userId];
    if (s && s.display_color) return s.display_color;
    return fallbackColorFor(userId);
  }
  function fmtTime(iso) {
    const d = new Date(iso);
    let h = d.getHours();
    const m = String(d.getMinutes()).padStart(2, "0");
    const ampm = h >= 12 ? "p" : "a";
    h = h % 12; if (h === 0) h = 12;
    return h + ":" + m + ampm;
  }

  async function loadStaff() {
    const { data, error } = await db.rpc("list_staff");
    if (error) {
      // Fallback: just self
      staffById[currentUser.id] = {
        user_id: currentUser.id,
        email: currentUser.email,
        display_name: null,
        display_color: null,
        photo_url: null
      };
      return;
    }
    staffById = {};
    (data || []).forEach(function(s) { staffById[s.user_id] = s; });
  }

  // ── UI injection ─────────────────────────────────────────────────────────
  function injectUI() {
    if (isInjected) return;
    isInjected = true;

    const css = `
      #dcs-chat-widget {
        position: fixed; bottom: 18px; left: 18px; z-index: 21;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      }
      #dcs-chat-toggle {
        position: relative;
        display: inline-flex; align-items: center; gap: 7px;
        background: linear-gradient(135deg, #2a8855 0%, #1f6f44 100%);
        color: #fff; border: none; border-radius: 999px;
        padding: 9px 16px 9px 12px;
        font-size: 13px; font-weight: 700; cursor: pointer;
        box-shadow: 0 4px 18px rgba(36, 99, 235, 0.28);
        transition: transform 0.15s, box-shadow 0.15s;
      }
      #dcs-chat-toggle:hover { transform: translateY(-1px); box-shadow: 0 6px 22px rgba(0, 0, 0, 0.3); }
      #dcs-chat-toggle .unread-badge {
        background: #ef4444; color: #fff;
        border-radius: 999px; padding: 1px 7px;
        font-size: 11px; font-weight: 800;
        margin-left: 4px;
      }
      #dcs-chat-toggle .unread-badge.hidden { display: none; }
      #dcs-chat-panel {
        position: absolute; bottom: 50px; left: 0;
        width: 380px; max-width: calc(100vw - 36px);
        height: 480px; max-height: calc(100vh - 80px);
        background: #fff;
        border-radius: 12px;
        border: 1px solid #d2dcee;
        box-shadow: 0 8px 40px rgba(12, 22, 50, 0.22);
        display: none;
        flex-direction: column;
        overflow: hidden;
      }
      #dcs-chat-panel.open { display: flex; }
      #dcs-chat-header {
        background: linear-gradient(135deg, #2a8855 0%, #1f6f44 100%);
        color: #fff;
        padding: 9px 12px;
        display: flex; align-items: center; justify-content: space-between;
        flex-shrink: 0;
        gap: 8px;
      }
      #dcs-chat-header .title { font-size: 13px; font-weight: 800; }
      #dcs-chat-header .online-count {
        font-size: 11px; opacity: 0.85; font-weight: 600;
        cursor: help;
      }
      #dcs-chat-header .actions {
        display: flex; gap: 4px;
      }
      #dcs-chat-header button {
        background: rgba(255,255,255,0.15); border: none; color: #fff;
        width: 24px; height: 24px; border-radius: 50%;
        font-size: 12px; cursor: pointer;
        display: flex; align-items: center; justify-content: center;
      }
      #dcs-chat-header button:hover { background: rgba(255,255,255,0.28); }
      #dcs-chat-online-list {
        background: #f6faf7;
        padding: 5px 10px;
        font-size: 10.5px;
        color: #4a5b6b;
        border-bottom: 1px solid #e3eae5;
        display: none;
      }
      #dcs-chat-online-list.show { display: block; }
      #dcs-chat-online-list .online-pill {
        display: inline-flex; align-items: center; gap: 3px;
        margin-right: 6px;
      }
      #dcs-chat-online-list .online-pill .dot {
        display: inline-block;
        width: 7px; height: 7px;
        border-radius: 50%;
        background: #22c55e;
        flex-shrink: 0;
      }
      #dcs-chat-messages {
        flex: 1;
        overflow-y: auto;
        padding: 6px 10px;
        font-size: 12.5px;
        line-height: 1.45;
        background: #fcfcfc;
      }
      #dcs-chat-messages::-webkit-scrollbar { width: 6px; }
      #dcs-chat-messages::-webkit-scrollbar-thumb { background: rgba(0,0,0,0.12); border-radius: 3px; }
      .dcs-msg {
        padding: 1px 0;
        word-break: break-word;
      }
      .dcs-msg .ts {
        color: #94a3b8;
        font-size: 10.5px;
        font-family: ui-monospace, "SF Mono", monospace;
        margin-right: 4px;
      }
      .dcs-msg .user {
        font-weight: 700;
        margin-right: 2px;
      }
      .dcs-msg .user::before { content: "<"; color: #94a3b8; font-weight: 400; }
      .dcs-msg .user::after  { content: ">"; color: #94a3b8; font-weight: 400; }
      .dcs-msg .body {
        color: #1f2937;
        margin-left: 2px;
      }
      .dcs-msg.system {
        color: #64748b;
        font-style: italic;
        font-size: 11px;
        text-align: center;
        margin: 4px 0;
      }
      .dcs-msg.own .body {
        color: #0f172a;
      }
      #dcs-chat-input-row {
        flex-shrink: 0;
        border-top: 1px solid #e3eae5;
        background: #fff;
        padding: 8px 10px;
        display: flex; gap: 6px; align-items: center;
      }
      #dcs-chat-input {
        flex: 1; min-width: 0;
        border: 1px solid #cbd5e1; border-radius: 16px;
        padding: 6px 12px;
        font-size: 12.5px;
        font: inherit;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        outline: none;
        background: #f8fafc;
      }
      #dcs-chat-input:focus { background: #fff; border-color: #2a8855; }
      #dcs-chat-send {
        background: #2a8855; color: #fff; border: none;
        width: 30px; height: 30px; border-radius: 50%;
        cursor: pointer;
        display: flex; align-items: center; justify-content: center;
        flex-shrink: 0;
      }
      #dcs-chat-send:hover { background: #1f6f44; }
      #dcs-chat-send:disabled { opacity: 0.5; cursor: not-allowed; }
      #dcs-chat-load-older {
        text-align: center;
        color: #64748b;
        font-size: 11px;
        padding: 4px 0;
        cursor: pointer;
        text-decoration: underline;
      }
      #dcs-chat-load-older:hover { color: #1f6f44; }
    `;

    const style = document.createElement("style");
    style.id = "dcs-chat-widget-style";
    style.textContent = css;
    document.head.appendChild(style);

    const widget = document.createElement("div");
    widget.id = "dcs-chat-widget";
    widget.innerHTML = `
      <button id="dcs-chat-toggle" title="Team chat">
        💬 Team Chat
        <span class="unread-badge hidden" id="dcs-chat-unread"></span>
      </button>
      <div id="dcs-chat-panel">
        <div id="dcs-chat-header">
          <div>
            <div class="title">DCS Team Chat</div>
            <div class="online-count" id="dcs-chat-online-count" title="Click to see who's online">0 online</div>
          </div>
          <div class="actions">
            <button id="dcs-chat-mute" title="Toggle sound">🔔</button>
            <button id="dcs-chat-close" title="Close">✕</button>
          </div>
        </div>
        <div id="dcs-chat-online-list"></div>
        <div id="dcs-chat-messages">
          <div id="dcs-chat-load-older" style="display:none;">Load older messages</div>
          <div id="dcs-chat-msg-list"></div>
        </div>
        <div id="dcs-chat-input-row">
          <input id="dcs-chat-input" type="text" placeholder="Type a message…" maxlength="2000" />
          <button id="dcs-chat-send" title="Send (Enter)">➤</button>
        </div>
      </div>
    `;
    document.body.appendChild(widget);

    // Wire up
    document.getElementById("dcs-chat-toggle").onclick = togglePanel;
    document.getElementById("dcs-chat-close").onclick = closePanel;
    document.getElementById("dcs-chat-mute").onclick = toggleMute;
    document.getElementById("dcs-chat-online-count").onclick = function() {
      const l = document.getElementById("dcs-chat-online-list");
      l.classList.toggle("show");
    };
    document.getElementById("dcs-chat-send").onclick = sendMessage;
    const inp = document.getElementById("dcs-chat-input");
    inp.addEventListener("keydown", function(e) {
      if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); sendMessage(); }
    });
    document.getElementById("dcs-chat-load-older").onclick = loadOlderMessages;

    // Restore saved mute preference
    if (localStorage.getItem("dcs_chat_muted") === "1") {
      document.getElementById("dcs-chat-mute").textContent = "🔕";
    }
  }

  function togglePanel() { isOpen ? closePanel() : openPanel(); }
  function openPanel() {
    document.getElementById("dcs-chat-panel").classList.add("open");
    isOpen = true;
    clearUnread();
    setTimeout(function() {
      document.getElementById("dcs-chat-input").focus();
      const list = document.getElementById("dcs-chat-messages");
      list.scrollTop = list.scrollHeight;
    }, 50);
  }
  function closePanel() {
    document.getElementById("dcs-chat-panel").classList.remove("open");
    isOpen = false;
  }
  function toggleMute() {
    const muted = localStorage.getItem("dcs_chat_muted") === "1";
    localStorage.setItem("dcs_chat_muted", muted ? "0" : "1");
    document.getElementById("dcs-chat-mute").textContent = muted ? "🔔" : "🔕";
  }
  function isMuted() { return localStorage.getItem("dcs_chat_muted") === "1"; }

  // ── Messages ─────────────────────────────────────────────────────────────
  async function loadInitialMessages() {
    const { data, error } = await db
      .from("chat_messages")
      .select("*")
      .order("created_at", { ascending: false })
      .limit(50);
    if (error) {
      console.warn("[chat] failed to load messages:", error.message);
      messages = [];
    } else {
      // Reverse so oldest first in our render
      messages = (data || []).reverse();
      if (messages.length) oldestLoaded = messages[0].created_at;
    }
    renderMessages();
    document.getElementById("dcs-chat-load-older").style.display = messages.length >= 50 ? "block" : "none";
  }

  async function loadOlderMessages() {
    if (!oldestLoaded) return;
    const btn = document.getElementById("dcs-chat-load-older");
    btn.textContent = "Loading…";
    const { data, error } = await db
      .from("chat_messages")
      .select("*")
      .lt("created_at", oldestLoaded)
      .order("created_at", { ascending: false })
      .limit(50);
    if (error) { btn.textContent = "Failed — try again"; return; }
    const older = (data || []).reverse();
    if (older.length) {
      messages = older.concat(messages);
      oldestLoaded = older[0].created_at;
    }
    btn.textContent = "Load older messages";
    if (older.length < 50) btn.style.display = "none";
    renderMessages(/*preserveScroll*/ true);
  }

  function renderMessages(preserveScroll) {
    const list = document.getElementById("dcs-chat-msg-list");
    if (!list) return;
    const oldScrollTop = list.parentElement.scrollTop;
    const oldScrollHeight = list.parentElement.scrollHeight;
    list.innerHTML = messages.map(buildMsgHtml).join("");
    if (preserveScroll) {
      // Keep view position when prepending older messages
      const newScrollHeight = list.parentElement.scrollHeight;
      list.parentElement.scrollTop = oldScrollTop + (newScrollHeight - oldScrollHeight);
    } else {
      list.parentElement.scrollTop = list.parentElement.scrollHeight;
    }
  }

  function buildMsgHtml(m) {
    if (m._system) {
      return `<div class="dcs-msg system">— ${escHtml(m.content)} —</div>`;
    }
    const own = m.user_id === currentUser.id;
    const color = colorFor(m.user_id);
    const name = nameFor(m.user_id);
    return `<div class="dcs-msg ${own ? 'own' : ''}">` +
             `<span class="ts">[${escHtml(fmtTime(m.created_at))}]</span>` +
             `<span class="user" style="color:${color};">${escHtml(name)}</span>` +
             `<span class="body"> ${escHtml(m.content)}</span>` +
           `</div>`;
  }

  async function sendMessage() {
    const inp = document.getElementById("dcs-chat-input");
    const content = (inp.value || "").trim();
    if (!content || !currentUser) return;
    const sendBtn = document.getElementById("dcs-chat-send");
    sendBtn.disabled = true;
    inp.value = "";
    const { error } = await db.from("chat_messages").insert({
      user_id: currentUser.id,
      content: content
    });
    sendBtn.disabled = false;
    if (error) {
      // Restore the message so the user doesn't lose their text
      inp.value = content;
      console.warn("[chat] send failed:", error.message);
    }
    inp.focus();
  }

  // ── Realtime ─────────────────────────────────────────────────────────────
  function setupRealtime() {
    if (realtimeChannel) { try { db.removeChannel(realtimeChannel); } catch(e){} }
    realtimeChannel = db
      .channel("team-chat-v1")
      .on("postgres_changes",
        { event: "INSERT", schema: "public", table: "chat_messages" },
        function(payload) { handleIncomingMessage(payload.new); })
      .on("postgres_changes",
        { event: "DELETE", schema: "public", table: "chat_messages" },
        function(payload) { handleDeletedMessage(payload.old); })
      .subscribe(function(status) {
        if (status === "CLOSED" || status === "CHANNEL_ERROR") {
          setTimeout(setupRealtime, 5000);
        }
      });
  }

  function handleIncomingMessage(msg) {
    if (!msg) return;
    // Avoid double-add if it's already in the list (own message round-trip)
    if (messages.some(function(m) { return m.id === msg.id; })) return;
    messages.push(msg);
    renderMessages();
    // Notification: only if not from self
    if (msg.user_id !== currentUser.id) {
      if (!isOpen || document.hidden) {
        unreadCount++;
        updateUnreadUI();
        if (!isMuted()) playPing();
      }
    }
  }

  function handleDeletedMessage(old) {
    if (!old) return;
    messages = messages.filter(function(m) { return m.id !== old.id; });
    renderMessages();
  }

  // ── Presence (online users) ──────────────────────────────────────────────
  function setupPresence() {
    if (presenceChannel) { try { db.removeChannel(presenceChannel); } catch(e){} }
    presenceChannel = db.channel("team-chat-presence", {
      config: { presence: { key: currentUser.id } }
    });
    presenceChannel
      .on("presence", { event: "sync" }, function() {
        const state = presenceChannel.presenceState();
        onlineUsers = {};
        Object.keys(state).forEach(function(userId) {
          const arr = state[userId];
          if (arr && arr.length) onlineUsers[userId] = arr[0];
        });
        updateOnlineUI();
      })
      .on("presence", { event: "join" }, function(p) {
        const newUser = (p.newPresences && p.newPresences[0]) || null;
        if (newUser && newUser.user_id && newUser.user_id !== currentUser.id) {
          appendSystemMessage(nameFor(newUser.user_id) + " joined");
        }
      })
      .on("presence", { event: "leave" }, function(p) {
        const goneUser = (p.leftPresences && p.leftPresences[0]) || null;
        if (goneUser && goneUser.user_id && goneUser.user_id !== currentUser.id) {
          appendSystemMessage(nameFor(goneUser.user_id) + " left");
        }
      })
      .subscribe(async function(status) {
        if (status === "SUBSCRIBED") {
          await presenceChannel.track({
            user_id: currentUser.id,
            email: currentUser.email,
            name: nameFor(currentUser.id),
            online_at: new Date().toISOString()
          });
        } else if (status === "CLOSED" || status === "CHANNEL_ERROR") {
          setTimeout(setupPresence, 5000);
        }
      });
  }

  function appendSystemMessage(text) {
    messages.push({ id: "sys-" + Date.now() + "-" + Math.random(), _system: true, content: text, created_at: new Date().toISOString() });
    if (messages.length > 200) messages = messages.slice(-200);
    renderMessages();
  }

  function updateOnlineUI() {
    const ids = Object.keys(onlineUsers);
    const count = ids.length;
    const countEl = document.getElementById("dcs-chat-online-count");
    if (countEl) countEl.textContent = count + (count === 1 ? " online" : " online");

    const list = document.getElementById("dcs-chat-online-list");
    if (list) {
      list.innerHTML = ids.length
        ? ids.map(function(id) {
            const c = colorFor(id);
            const n = nameFor(id);
            return `<span class="online-pill"><span class="dot" style="background:${c};"></span>${escHtml(n)}</span>`;
          }).join("")
        : "<em>No one online</em>";
    }
  }

  // ── Unread badge + tab title flash ───────────────────────────────────────
  function updateUnreadUI() {
    const badge = document.getElementById("dcs-chat-unread");
    if (badge) {
      if (unreadCount > 0) { badge.textContent = unreadCount; badge.classList.remove("hidden"); }
      else                 { badge.classList.add("hidden"); }
    }
    if (document.hidden && unreadCount > 0) {
      document.title = "(" + unreadCount + ") " + originalTitle;
    } else if (unreadCount === 0) {
      document.title = originalTitle;
    }
  }
  function clearUnread() { unreadCount = 0; updateUnreadUI(); }

  function setupTabVisibility() {
    document.addEventListener("visibilitychange", function() {
      if (!document.hidden && isOpen) clearUnread();
      else if (!document.hidden) updateUnreadUI();  // strip the (N) prefix on focus
    });
    // Watch for title changes from outside our control (e.g. SPA-ish updates)
    const interval = setInterval(function() {
      if (!document.title.startsWith("(") && document.title !== originalTitle) {
        originalTitle = document.title;
      }
    }, 5000);
    window.addEventListener("beforeunload", function() { clearInterval(interval); });
  }

  // ── Sound ────────────────────────────────────────────────────────────────
  function playPing() {
    try {
      if (!audioCtx) audioCtx = new (window.AudioContext || window.webkitAudioContext)();
      const ctx = audioCtx;
      // Simple two-tone "blip"
      const t = ctx.currentTime;
      [880, 1320].forEach(function(freq, i) {
        const o = ctx.createOscillator();
        const g = ctx.createGain();
        o.connect(g); g.connect(ctx.destination);
        o.frequency.value = freq;
        o.type = "sine";
        const start = t + i * 0.07;
        g.gain.setValueAtTime(0.0001, start);
        g.gain.exponentialRampToValueAtTime(0.12, start + 0.01);
        g.gain.exponentialRampToValueAtTime(0.0001, start + 0.18);
        o.start(start);
        o.stop(start + 0.20);
      });
    } catch (e) { /* audio context not yet allowed; ignore */ }
  }

})();
