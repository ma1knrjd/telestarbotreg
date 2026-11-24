'use strict';

function createTelegramSender(botToken, fetchImpl = fetch) {
  return async function sendTelegram(chatId, text, extra = {}) {
    const res = await fetchImpl(`https://api.telegram.org/bot${botToken}/sendMessage`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id: chatId, text, parse_mode: 'HTML', ...extra }),
    });
    if (!res.ok) throw new Error(`Telegram sendMessage failed: ${res.status}`);
    return res.json();
  };
}

module.exports = { createTelegramSender };
