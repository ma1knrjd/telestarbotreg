'use strict';
const { Telegraf } = require('telegraf');
const user = require('./commands/user');
const owner = require('./commands/owner');

function buildBot({ token, ownerId, rpc }) {
  const bot = new Telegraf(token);

  // Каждое обновление: запоминаем контакт, подтягиваем регистрацию из Supabase
  bot.use(async (ctx, next) => {
    if (!ctx.from || ctx.from.is_bot) return;
    if (ctx.chat && ctx.chat.type !== 'private') return; // только личные чаты
    ctx.state.rpc = rpc;
    try {
      ctx.state.user = await rpc('srv_bot_touch', {
        p_tg: ctx.from.id, p_username: ctx.from.username || '',
        p_first: ctx.from.first_name || '', p_last: ctx.from.last_name || '',
      });
    } catch (e) {
      console.error('bot_touch failed:', e.message);
      return ctx.reply(user.TXT.unavailable);
    }
    return next();
  });

  user.register(bot);
  owner.register(bot, { ownerId });

  bot.catch((err, ctx) => {
    console.error('Bot error:', err && err.message);
    ctx.reply(user.TXT.unavailable).catch(() => {});
  });
  return bot;
}

async function setupCommands(bot, ownerId) {
  const base = [
    { command: 'start', description: 'главное меню' },
    { command: 'mynumber', description: 'показать свой номер' },
    { command: 'linkaccount', description: 'привязать аккаунт' },
    { command: 'help', description: 'помощь' },
    { command: 'cancel', description: 'отменить текущее действие' },
  ];
  await bot.telegram.setMyCommands(base);
  await bot.telegram.setMyCommands([
    ...base,
    { command: 'addnumber', description: 'создать номер и привязать к пользователю' },
    { command: 'unlink', description: 'удалить привязку: /unlink @username' },
  ], { scope: { type: 'chat', chat_id: Number(ownerId) } });
}

module.exports = { buildBot, setupCommands };
