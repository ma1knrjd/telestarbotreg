'use strict';
const crypto = require('node:crypto');

const b64u = (buf) => Buffer.from(buf).toString('base64url');

function sha256(s) { return crypto.createHash('sha256').update(s).digest('hex'); }

// Хеш одноразового кода: HMAC(pepper, userId|code). Открытый код нигде не хранится.
function hashCode(pepper, userId, code) {
  return crypto.createHmac('sha256', pepper).update(`${userId}|${code}`).digest('hex');
}

function safeEqualHex(a, b) {
  const x = Buffer.from(String(a), 'utf8'), y = Buffer.from(String(b), 'utf8');
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}

function generateCode() { return String(crypto.randomInt(0, 1000000)).padStart(6, '0'); }
function generateToken() { return crypto.randomBytes(32).toString('base64url'); }

// JWT HS256 — формат, который принимает Supabase (PostgREST / Realtime / Storage)
function signJwt(payload, secret) {
  const h = b64u(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const p = b64u(JSON.stringify(payload));
  const sig = crypto.createHmac('sha256', secret).update(`${h}.${p}`).digest('base64url');
  return `${h}.${p}.${sig}`;
}

function verifyJwt(token, secret) {
  if (typeof token !== 'string') return null;
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  const sig = crypto.createHmac('sha256', secret).update(`${parts[0]}.${parts[1]}`).digest('base64url');
  if (!safeEqualHex(sig, parts[2])) return null;
  try {
    const payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
    if (payload.exp && payload.exp < Math.floor(Date.now() / 1000)) return null;
    return payload;
  } catch { return null; }
}

module.exports = { sha256, hashCode, safeEqualHex, generateCode, generateToken, signJwt, verifyJwt };
