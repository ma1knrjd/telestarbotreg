'use strict';
const { Markup } = require('telegraf');
const { formatIdentifier, normalizeIdentifier, esc } = require('../services/format');

const usage = {
  addnumber: '<b>/addnumber</b> @username +НОМЕР\n\nПример: <code>/addnumber @ivan +888 0000</code>\nПользователь должен сначала запустить бота (/start). Если у него уже есть ID — сначала /unlink.',
  unlink: '<b>/unlink</b> @username\n\nУдаляет привязку ID к пользователю, отзывает его сессии и навсегда блокирует старый ID.',
};

function register(bot, { ownerId }) {
  const isOwner = (ctx) => String(ctx.from && ctx.from.id) === String(ownerId);
  const args = (ctx) => (ctx.message.text || '').split(/\s+/).slice(1);
  const deny = (ctx) => ctx.reply('Неизвестная команда. Список команд: /help');

  bot.command('addnumber', async (ctx) => {
    if (!isOwner(ctx)) return deny(ctx);
    const [uname, ...rest] = args(ctx);
    const ident = normalizeIdentifier(rest.join(' '));
    if (!uname || !uname.startsWith('@') || !ident) return ctx.reply(usage.addnumber, { parse_mode: 'HTML' });
    const r = await ctx.state.rpc('srv_admin_add_number', { p_admin: ctx.from.id, p_username: uname, p_identifier: ident });
    const errors = {
      not_started: `Пользователь ${esc(uname)} не найден: он должен сначала запустить бота (/start).`,
      already_has: `У ${esc(uname)} уже есть ID ${esc(formatIdentifier(r.identifier))}. Сначала /unlink.`,
      taken: 'Этот идентификатор уже занят.',
      revoked: 'Этот идентификатор был отозван и не может быть выдан повторно.',
      bad_identifier: 'Неверный формат номера. Нужен вид +888 0000 (3–15 цифр).',
    };
    if (r.error) return ctx.reply(errors[r.error] || 'Ошибка.', { parse_mode: 'HTML' });
    await ctx.reply(`✅ ID <b>${esc(formatIdentifier(r.identifier))}</b> привязан к ${esc(uname)}.`, { parse_mode: 'HTML' });
    await ctx.telegram.sendMessage(r.telegram_id,
      `🔑 Вам выдан идентификатор TeleStar: <b>${esc(formatIdentifier(r.identifier))}</b>\n\nИспользуйте его для входа. Код подтверждения придёт сюда.`,
      { parse_mode: 'HTML' }).catch(() => {});
  });

  bot.command('unlink', async (ctx) => {
    if (!isOwner(ctx)) return deny(ctx);
    const [uname] = args(ctx);
    if (!uname || !uname.startsWith('@')) return ctx.reply(usage.unlink, { parse_mode: 'HTML' });
    const u = await ctx.state.rpc('srv_admin_find', { p_username: uname });
    if (!u) return ctx.reply(`Пользователь ${esc(uname)} с привязанным ID не найден.`);
    return ctx.reply(
      `⚠️ Удалить привязку?\n\nПользователь: <b>${esc(u.display_name)}</b> (@${esc(u.username)})\nID: <b>${esc(formatIdentifier(u.identifier))}</b>\n\nСессии приложения будут отозваны, старый ID заблокирован навсегда.`,
      { parse_mode: 'HTML', ...Markup.inlineKeyboard([[
        Markup.button.callback('✅ Подтвердить', `unlink:yes:${u.user_id}`),
        Markup.button.callback('❌ Отмена', 'unlink:no'),
      ]]) });
  });

  bot.action('unlink:no', async (ctx) => {
    await ctx.answerCbQuery();
    await ctx.editMessageReplyMarkup(undefined).catch(() => {});
    return ctx.reply('Отменено.');
  });

  bot.action(/^unlink:yes:([0-9a-f-]{36})$/, async (ctx) => {
    if (!isOwner(ctx)) return ctx.answerCbQuery('Недоступно', { show_alert: true });
    await ctx.answerCbQuery();
    await ctx.editMessageReplyMarkup(undefined).catch(() => {});
    const r = await ctx.state.rpc('srv_admin_unlink', { p_admin: ctx.from.id, p_user: ctx.match[1] });
    if (r.error) return ctx.reply('Пользователь уже отвязан или не найден.');
    await ctx.reply(`✅ Привязка ${esc(formatIdentifier(r.identifier))} удалена, сессии отозваны.`);
    await ctx.telegram.sendMessage(r.telegram_id,
      'Ваш идентификатор TeleStar был отвязан администратором. Вход по нему больше невозможен.').catch(() => {});
  });
}

module.exports = { register };
