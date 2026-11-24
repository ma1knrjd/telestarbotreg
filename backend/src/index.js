'use strict';
// Автономный запуск только API (без бота). На Render используется telegram-bot/src/index.js,
// который подключает этот же API в один процесс.
const http = require('node:http');
const { loadConfig } = require('./config');
const { createRpc } = require('./supabase');
const { createTelegramSender } = require('./telegram');
const { createApi } = require('./server');

const config = loadConfig();
const api = createApi({ rpc: createRpc(config), sendTelegram: createTelegramSender(config.botToken), config });
http.createServer(async (req, res) => {
  if (!(await api(req, res))) { res.writeHead(404); res.end(); }
}).listen(config.port, () => console.log(`TeleStar backend listening on :${config.port}`));
