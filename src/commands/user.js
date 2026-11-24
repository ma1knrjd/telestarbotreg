'use strict';
const { Markup } = require('telegraf');
const { formatIdentifier, esc } = require('../services/format');

const mainMenu = () => Markup.inlineKeyboard([
  [Markup.button.callback('📱 Мой номер', 'menu:number')],
  [Markup.button.callback('🔗 Привязать аккаунт', 'menu:link')],
  [Markup.button.callback('❓ Помощь', 'menu:help')],
]);

const chooser = () => Markup.inlineKeyboard([
  [Markup.button.callback('🇺🇸 Получить +1', 'reg:+1'), Markup.button.callback('🇷🇺 Получить +7', 'reg:+7')],
  [Markup.button.callback('❌ Отмена', 'reg:cancel')],
]);

const TXT = {
  welcomeNew: 'Добро пожаловать в TeleStar!\n\nНажмите «📱 Мой номер», чтобы получить личный ID для входа.',
  welcomeBack: (id) => `Добро пожаловать в TeleStar!\n\nВаш номер: <b>${esc(formatIdentifier(id))}</b>\n\nДля входа в приложение введите номер и запросите код — он придёт сюда.`,
  chooser: 'Привет, че! 👋\n\nЭто служебный бот TeleStar. Здесь ты получаешь личный ID для входа, а коды приходят прямо в этот чат.\n\nВыбери, какой ID получить. Один раз и навсегда, второй раз не выдаётся:',
  created: (id) => `🔑 <b>${esc(formatIdentifier(id))}</b> — твой идентификатор для входа\n\n💬 Используй этот ID для входа. Код подтверждения придёт сюда, в этот чат.\n\n⚠️ Этот ID закреплён за тобой навсегда. Не потеряй его.`,
  existing: (id) => `У тебя уже есть идентификатор:\n\n🔑 <b>${esc(formatIdentifier(id))}</b>\n\nНовый ID не выдаётся.`,
  link: (id) => `🔗 Привязка аккаунта\n\n1. Откройте приложение TeleStar.\n2. Введите свой ID: <b>${esc(formatIdentifier(id))}</b>\n3. Нажмите «Получить код» — код придёт в этот чат.\n4. Введите код и нажмите «Войти».`,
  help: 'ℹ️ <b>TeleStar — помощь</b>\n\n/start — главное меню\n/mynumber — показать свой номер\n/linkaccount — как войти в приложение\n/help — эта справка\n/cancel — отменить текущее действие\n\nНомера +1 и +7 — виртуальные идентификаторы TeleStar, а не настоящие телефонные номера: SMS и звонки на них не работают.',
  cancelled: 'Действие отменено.',
  unavailable: 'Сервис временно недоступен. Попробуйте чуть позже.',
};

function register(bot) {
  const showChooser = (ctx) => ctx.reply(TXT.chooser, chooser());
  const user = (ctx) => ctx.state.user;

  const start = (ctx) => user(ctx).registered
    ? ctx.reply(TXT.welcomeBack(user(ctx).identifier), mainMenu())
    : ctx.reply(TXT.welcomeNew, mainMenu());
  const myNumber = (ctx) => user(ctx).registered
    ? ctx.reply(`🔑 <b>${esc(formatIdentifier(user(ctx).identifier))}</b> — твой идентификатор для входа`, { parse_mode: 'HTML' })
    : showChooser(ctx);
  const link = (ctx) => user(ctx).registered
    ? ctx.reply(TXT.link(user(ctx).identifier), { parse_mode: 'HTML' })
    : showChooser(ctx);
  const help = (ctx) => ctx.reply(TXT.help, { parse_mode: 'HTML' });

  bot.start(start);
  bot.command('mynumber', myNumber);
  bot.command('linkaccount', link);
  bot.command('help', help);
  bot.command('cancel', (ctx) => ctx.reply(TXT.cancelled));

  bot.action('menu:number', async (ctx) => { await ctx.answerCbQuery(); return myNumber(ctx); });
  bot.action('menu:link', async (ctx) => { await ctx.answerCbQuery(); return link(ctx); });
  bot.action('menu:help', async (ctx) => { await ctx.answerCbQuery(); return help(ctx); });

  bot.action('reg:cancel', async (ctx) => {
    await ctx.answerCbQuery();
    await ctx.editMessageReplyMarkup(undefined).catch(() => {});
    return ctx.reply(TXT.cancelled);
  });

  bot.action(/^reg:(\+[17])$/, async (ctx) => {
    await ctx.answerCbQuery();
    await ctx.editMessageReplyMarkup(undefined).catch(() => {});
    const res = await ctx.state.rpc('srv_register_user', { p_tg: ctx.from.id, p_prefix: ctx.match[1] });
    return res.status === 'created'
      ? ctx.reply(TXT.created(res.identifier), { parse_mode: 'HTML' })
      : ctx.reply(TXT.existing(res.identifier), { parse_mode: 'HTML' });
  });
}

module.exports = { register, TXT };
