'use strict';
// Единый процесс для Render: Telegram-бот (webhook или polling) + API для Android-приложения.
const http = require('node:http');
const crypto = require('node:crypto');
const { loadConfig } = require('../../backend/src/config');
const { createRpc } = require('./database/db');
const { createTelegramSender } = require('../../backend/src/telegram');
const { createApi } = require('../../backend/src/server');
const { buildBot, setupCommands } = require('./bot');

async function main() {
  const config = loadConfig();
  const rpc = createRpc(config);
  const bot = buildBot({ token: config.botToken, ownerId: config.ownerId, rpc });
  const api = createApi({ rpc, sendTelegram: createTelegramSender(config.botToken), config });

  const secret = config.webhookSecret || crypto.createHash('sha256').update('wh:' + config.botToken).digest('hex').slice(0, 48);
  const hookPath = '/telegram/webhook';
  const useWebhook = Boolean(config.publicUrl);
  const hook = useWebhook ? bot.webhookCallback(hookPath) : null;

  const server = http.createServer(async (req, res) => {
    try {
      const path = (req.url || '').split('?')[0];
      if (useWebhook && req.method === 'POST' && path === hookPath) {
        if (req.headers['x-telegram-bot-api-secret-token'] !== secret) { res.writeHead(403); return res.end(); }
        return hook(req, res);
      }
      if (!(await api(req, res))) { res.writeHead(404); res.end(); }
    } catch (e) {
      console.error('Request error:', e.message);
      if (!res.headersSent) res.writeHead(500);
      res.end();
    }
  });
  await new Promise((r) => server.listen(config.port, '0.0.0.0', r));
  console.log(`TeleStar listening on :${config.port}`);

  const me = await bot.telegram.getMe();
  console.log(`Bot: @${me.username}`);
  await setupCommands(bot, config.ownerId).catch((e) => console.error('setMyCommands:', e.message));

  if (useWebhook) {
    await bot.telegram.setWebhook(config.publicUrl.replace(/\/+$/, '') + hookPath, { secret_token: secret, drop_pending_updates: false });
    console.log('Webhook mode:', config.publicUrl);
  } else {
    await bot.telegram.deleteWebhook();
    bot.launch().catch((e) => { console.error('polling failed:', e.message); process.exit(1); });
    console.log('Polling mode');
  }

  const stop = (sig) => { try { bot.stop(sig); } catch {} server.close(() => process.exit(0)); setTimeout(() => process.exit(0), 5000).unref(); };
  process.once('SIGINT', () => stop('SIGINT'));
  process.once('SIGTERM', () => stop('SIGTERM'));
}

main().catch((e) => { console.error('Fatal:', e); process.exit(1); });
