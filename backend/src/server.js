'use strict';
const { normalizeIdentifier } = require('./identifiers');
const C = require('./crypto');

class HttpError extends Error {
  constructor(status, code, extra = {}) { super(code); this.status = status; this.code = code; this.extra = extra; }
}

// Ограничитель по IP (в памяти): не более `max` запросов за `windowMs`
function createLimiter(max, windowMs) {
  const hits = new Map();
  return (key) => {
    const now = Date.now();
    const arr = (hits.get(key) || []).filter((t) => now - t < windowMs);
    arr.push(now);
    hits.set(key, arr);
    if (hits.size > 10000) for (const [k, v] of hits) if (!v.some((t) => now - t < windowMs)) hits.delete(k);
    return arr.length <= max;
  };
}

function createApi({ rpc, sendTelegram, config }) {
  const limitRequest = createLimiter(5, 60_000);   // запросы кода: 5/мин на IP
  const limitVerify = createLimiter(15, 60_000);   // проверки кода: 15/мин на IP
  const limitRefresh = createLimiter(60, 60_000);

  const issueTokens = (userId, sessionId) => {
    const now = Math.floor(Date.now() / 1000);
    return C.signJwt({
      aud: 'authenticated', role: 'authenticated', sub: userId, sid: sessionId,
      iat: now, exp: now + config.accessTtlSeconds,
    }, config.jwtSecret);
  };

  async function requestCode(body, ip) {
    if (!limitRequest(ip)) throw new HttpError(429, 'rate_limited');
    const identifier = normalizeIdentifier(body.identifier);
    // Ответ всегда одинаковый, чтобы нельзя было узнать, существует ли идентификатор
    const generic = { ok: true, retry_after: 60, expires_in: config.codeTtlSeconds };
    if (!identifier) throw new HttpError(400, 'invalid_identifier');
    const user = await rpc('srv_auth_lookup', { p_identifier: identifier });
    if (!user) return generic;
    const code = C.generateCode();
    const created = await rpc('srv_auth_create_code', {
      p_user: user.user_id,
      p_hash: C.hashCode(config.codePepper, user.user_id, code),
      p_ttl_seconds: config.codeTtlSeconds,
    });
    if (!created || !created.ok) return generic; // cooldown / hourly_limit
    try {
      await sendTelegram(user.telegram_id,
        `🔐 <b>Код входа в TeleStar:</b> <code>${code}</code>\n\nДействует 5 минут. Никому его не сообщайте.\nЕсли это не вы — просто проигнорируйте сообщение.`);
    } catch (e) {
      await rpc('srv_auth_fail_code', { p_code: created.code_id }).catch(() => {});
      throw new HttpError(502, 'delivery_failed');
    }
    return generic;
  }

  async function verify(body, ip) {
    if (!limitVerify(ip)) throw new HttpError(429, 'rate_limited');
    const identifier = normalizeIdentifier(body.identifier);
    const code = typeof body.code === 'string' ? body.code.trim() : '';
    if (!identifier || !/^\d{6}$/.test(code)) throw new HttpError(400, 'invalid_code');
    const row = await rpc('srv_auth_get_code', { p_identifier: identifier });
    if (!row) throw new HttpError(400, 'invalid_code');
    if (row.expired) throw new HttpError(400, 'code_expired');
    if (row.attempts >= 5) throw new HttpError(429, 'too_many_attempts');
    const attempts = await rpc('srv_auth_bump_attempt', { p_code: row.code_id });
    const ok = C.safeEqualHex(C.hashCode(config.codePepper, row.user_id, code), row.code_hash);
    if (!ok) {
      throw new HttpError(400, attempts >= 5 ? 'too_many_attempts' : 'invalid_code',
        { attempts_left: Math.max(0, 5 - attempts) });
    }
    if (!(await rpc('srv_auth_consume_code', { p_code: row.code_id }))) throw new HttpError(400, 'invalid_code');
    const refresh = C.generateToken();
    const sessionId = await rpc('srv_auth_create_session', {
      p_user: row.user_id, p_token_hash: C.sha256(refresh),
      p_ttl_seconds: config.refreshTtlSeconds, p_device: String(body.device || '').slice(0, 200),
    });
    if (!sessionId) throw new HttpError(403, 'account_unavailable');
    return {
      access_token: issueTokens(row.user_id, sessionId), refresh_token: refresh,
      expires_in: config.accessTtlSeconds, user_id: row.user_id,
    };
  }

  async function refresh(body, ip) {
    if (!limitRefresh(ip)) throw new HttpError(429, 'rate_limited');
    if (typeof body.refresh_token !== 'string' || body.refresh_token.length < 20) throw new HttpError(401, 'invalid_token');
    const next = C.generateToken();
    const r = await rpc('srv_auth_refresh', {
      p_old_hash: C.sha256(body.refresh_token), p_new_hash: C.sha256(next), p_ttl_seconds: config.refreshTtlSeconds,
    });
    if (!r) throw new HttpError(401, 'invalid_token');
    return {
      access_token: issueTokens(r.user_id, r.session_id), refresh_token: next,
      expires_in: config.accessTtlSeconds, user_id: r.user_id,
    };
  }

  async function logout(req) {
    const m = /^Bearer (.+)$/.exec(req.headers.authorization || '');
    const claims = m && C.verifyJwt(m[1], config.jwtSecret);
    if (!claims || !claims.sid) throw new HttpError(401, 'unauthorized');
    await rpc('srv_auth_revoke_session', { p_session: claims.sid });
    return { ok: true };
  }

  const clientIp = (req) => (req.headers['x-forwarded-for'] || '').split(',')[0].trim() || req.socket.remoteAddress || 'unknown';

  function readBody(req) {
    return new Promise((resolve, reject) => {
      let size = 0; const chunks = [];
      req.on('data', (c) => { size += c.length; if (size > 10_000) { reject(new HttpError(413, 'too_large')); req.destroy(); } else chunks.push(c); });
      req.on('end', () => {
        if (!chunks.length) return resolve({});
        try { const v = JSON.parse(Buffer.concat(chunks).toString('utf8')); resolve(v && typeof v === 'object' ? v : {}); }
        catch { reject(new HttpError(400, 'bad_json')); }
      });
      req.on('error', reject);
    });
  }

  // Возвращает true, если запрос обработан; false — если маршрут не наш
  return async function handle(req, res) {
    const url = new URL(req.url, 'http://x');
    const path = url.pathname;
    const send = (status, obj) => {
      res.writeHead(status, {
        'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff',
      });
      res.end(JSON.stringify(obj));
    };
    try {
      if (req.method === 'GET' && (path === '/health' || path === '/')) { send(200, { ok: true, service: 'telestar' }); return true; }
      if (req.method !== 'POST' || !path.startsWith('/auth/')) return false;
      const ip = clientIp(req);
      if (path === '/auth/logout') { send(200, await logout(req)); return true; }
      const body = await readBody(req);
      if (path === '/auth/request-code') send(200, await requestCode(body, ip));
      else if (path === '/auth/verify') send(200, await verify(body, ip));
      else if (path === '/auth/refresh') send(200, await refresh(body, ip));
      else send(404, { error: 'not_found' });
      return true;
    } catch (e) {
      if (e instanceof HttpError) { send(e.status, { error: e.code, ...e.extra }); return true; }
      console.error('API error:', e && e.message);
      send(500, { error: 'server_error' });
      return true;
    }
  };
}

module.exports = { createApi, HttpError };
