'use strict';
// Минимальный клиент PostgREST: вызываем серверные функции srv_* с service_role ключом.

function createRpc({ supabaseUrl, serviceKey }, fetchImpl = fetch) {
  return async function rpc(name, args = {}) {
    const res = await fetchImpl(`${supabaseUrl}/rest/v1/rpc/${name}`, {
      method: 'POST',
      headers: {
        apikey: serviceKey,
        Authorization: `Bearer ${serviceKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(args),
    });
    const text = await res.text();
    if (!res.ok) throw new Error(`Supabase rpc ${name} -> ${res.status}: ${text.slice(0, 300)}`);
    return text ? JSON.parse(text) : null;
  };
}

module.exports = { createRpc };
