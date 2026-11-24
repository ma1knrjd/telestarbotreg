'use strict';

function loadConfig(env = process.env) {
  const need = (k) => {
    if (!env[k]) throw new Error(`Не задана переменная окружения ${k}`);
    return env[k];
  };
  return {
    port: Number(env.PORT || 3000),
    supabaseUrl: need('SUPABASE_URL').replace(/\/+$/, ''),
    serviceKey: need('SUPABASE_SERVICE_ROLE_KEY'),
    jwtSecret: need('SUPABASE_JWT_SECRET'),
    botToken: need('BOT_TOKEN'),
    ownerId: need('OWNER_TELEGRAM_ID'),
    codePepper: env.CODE_PEPPER || need('SUPABASE_JWT_SECRET'),
    webhookSecret: env.WEBHOOK_SECRET || '',
    publicUrl: env.WEBHOOK_URL || env.RENDER_EXTERNAL_URL || '',
    codeTtlSeconds: 300,
    accessTtlSeconds: 900,
    refreshTtlSeconds: 30 * 24 * 3600,
  };
}

module.exports = { loadConfig };
